// Request-scoped transport for the public web-fetch provider on jitless Node.
// The provider still owns URL/DNS/NAT64/redirect policy and decoded-body limits.
// No global fetch replacement and no ambient proxy/cookie/authentication state.
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import { isIP } from 'node:net';
import { Readable } from 'node:stream';
import zlib from 'node:zlib';
import { writeSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

let webRequestSequence = 0;
const webErrors = new Map([
  ['WEB_INVALID_URL', 'invalid_url'], ['WEB_BLOCKED_URL', 'blocked_url'],
  ['WEB_REDIRECT_BLOCKED', 'redirect_blocked'],
  ['WEB_UNSUPPORTED_CONTENT_TYPE', 'unsupported_content'],
  ['WEB_FETCH_TOO_LARGE', 'too_large'], ['WEB_FETCH_TIMEOUT', 'timeout'],
  ['WEB_ABORTED', 'aborted'], ['ENOTFOUND', 'dns'], ['EAI_AGAIN', 'dns'],
  ['ECONNREFUSED', 'connection_refused'], ['DSH_PROXY_CONNECT_FAILED', 'proxy'],
  ['CERT_HAS_EXPIRED', 'tls'], ['CERT_NOT_YET_VALID', 'tls'],
  ['DEPTH_ZERO_SELF_SIGNED_CERT', 'tls'], ['SELF_SIGNED_CERT_IN_CHAIN', 'tls'],
  ['UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'tls'], ['UNABLE_TO_GET_ISSUER_CERT_LOCALLY', 'tls'],
  ['ERR_TLS_CERT_ALTNAME_INVALID', 'tls'], ['ERR_TLS_CERT_SIGNATURE_ALGORITHM_UNSUPPORTED', 'tls'],
]);

function webErrorClass(error) {
  // Never stringify an exception: messages and stacks can contain URLs,
  // proxy credentials, response bodies or model-supplied input.
  try {
    for (let item = error, depth = 0; item && depth < 4; item = item.cause, depth++) {
      if (typeof item.code === 'string' && webErrors.has(item.code)) return webErrors.get(item.code);
    }
  } catch {}
  return 'other';
}

export async function observeWebFetch(operation) {
  const sequence = webRequestSequence = webRequestSequence >= Number.MAX_SAFE_INTEGER ? 1 : webRequestSequence + 1;
  const started = performance.now();
  let result, failure, failed = false;
  try { result = await operation(); return result; }
  catch (error) { failed = true; failure = error; throw error; }
  finally {
    // One fixed metadata line only after the complete provider body/disposal
    // settles. Diagnostic failures must not replace its result or exception.
    try {
      const event = { event: 'webFetchCompleted', guest_pid: process.pid,
        web_request_sequence: sequence,
        web_duration_ms: Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, Math.floor(performance.now() - started))),
        web_result: failed ? 'failure' : 'success', web_error: failed ? webErrorClass(failure) : 'none' };
      if (!failed && Number.isInteger(result?.statusCode) && result.statusCode >= 100 && result.statusCode <= 599)
        event.web_http_status = result.statusCode;
      // Synchronous fd output has no later unhandled stream error; a closed or
      // failed stderr descriptor is caught locally, without touching the body.
      writeSync(2, '[lifecycle] ' + JSON.stringify(event) + '\n');
    } catch {}
  }
}

function hostname(url) {
  return url.hostname.replace(/^\[|\]$/g, '');
}

function aborted(signal) {
  return signal?.reason instanceof Error ? signal.reason :
    Object.assign(new Error('web fetch aborted'), { name: 'AbortError' });
}

function pinnedLookup(addresses) {
  // Copy the validated answer set: a caller cannot mutate it during connection.
  const pinned = addresses.map(({ address, family }) => ({ address, family }));
  if (pinned.length === 0 || pinned.some(({ address, family }) =>
    (family !== 4 && family !== 6) || isIP(address) !== family)) {
    throw new Error('web fetch has no valid pinned destination');
  }
  return (name, options, callback) => {
    const family = typeof options === 'number' ? options :
      options?.family === 'IPv4' ? 4 : options?.family === 'IPv6' ? 6 : options?.family || 0;
    const eligible = family === 0 ? pinned : pinned.filter(entry => entry.family === family);
    if (eligible.length === 0) {
      callback(Object.assign(new Error('no pinned address for requested family'), { code: 'ENOTFOUND' }));
    } else if (options?.all === true) {
      callback(null, eligible.map(entry => ({ ...entry })));
    } else {
      callback(null, eligible[0].address, eligible[0].family);
    }
  };
}

function headerMap(raw) {
  const headers = new Headers();
  for (let i = 0; i < raw.length; i += 2) headers.append(raw[i], raw[i + 1]);
  return headers;
}

function decode(response, resources) {
  const encodings = String(response.headers['content-encoding'] || '')
    .split(',').map(value => value.trim().toLowerCase()).filter(value => value && value !== 'identity');
  // Match fetch's decoding of advertised encodings; unsupported encodings stay raw.
  if (encodings.some(value => !['gzip', 'x-gzip', 'deflate', 'br'].includes(value))) return response;
  let stream = response;
  for (const encoding of encodings.reverse()) {
    const next = encoding === 'br' ? zlib.createBrotliDecompress() :
      encoding === 'deflate' ? zlib.createInflate() : zlib.createGunzip();
    resources.add(next);
    // pipe() alone does not propagate an upstream error to its consumer.
    stream.on('error', error => next.destroy(error));
    stream = stream.pipe(next);
  }
  return stream;
}

function request(url, headers, signal, agentFactory) {
  if (signal?.aborted) return Promise.reject(aborted(signal));
  return new Promise((resolve, reject) => {
    const resources = new Set();
    let agent;
    let settled = false;
    let closed = false;
    const close = async () => {
      if (closed) return;
      closed = true;
      signal?.removeEventListener('abort', onAbort);
      for (const resource of resources) resource.destroy();
      agent?.destroy();
    };
    const fail = error => {
      if (!settled) { settled = true; reject(signal?.aborted ? aborted(signal) : error); }
      // Keep a body error observable by its web reader before the final disposer.
      for (const resource of resources) resource.destroy(error);
      agent?.destroy();
      signal?.removeEventListener('abort', onAbort);
    };
    const onAbort = () => fail(aborted(signal));
    signal?.addEventListener('abort', onAbort, { once: true });
    const track = resource => {
      resources.add(resource);
      // An aborted CONNECT/TLS attempt can fail after the outer request settles.
      resource.on('error', () => {});
      return resource;
    };
    try {
      agent = agentFactory(track, fail);
      const outgoing = { ...headers, 'accept-encoding': 'gzip, deflate, br' };
      // Origin requests must never inherit credentials for an operator's proxy.
      for (const key of Object.keys(outgoing)) {
        if (['proxy-authorization', 'proxy-connection', 'cookie', 'authorization', 'host']
          .includes(key.toLowerCase())) delete outgoing[key];
      }
      const req = track((url.protocol === 'https:' ? https : http).request({
        protocol: url.protocol,
        hostname: hostname(url),
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: url.pathname + url.search,
        method: 'GET',
        headers: outgoing,
        agent,
      }, response => {
        track(response);
        if (closed || signal?.aborted) { response.destroy(); fail(aborted(signal)); return; }
        try {
          const status = response.statusCode;
          const noBody = status === 204 || status === 205 || status === 304;
          // toWeb's default size is one per chunk. An explicit byte strategy
          // bounds the decoder/web-stream queue while the provider enforces
          // its decoded-body cap; a compressed response cannot queue MB-sized
          // chunks as though they each cost a single byte.
          const body = noBody ? null : Readable.toWeb(decode(response, resources), {
            strategy: { highWaterMark: 64 * 1024, size: chunk => chunk.byteLength },
          });
          const result = new Response(body, {
            status,
            statusText: response.statusMessage || '',
            headers: headerMap(response.rawHeaders),
          });
          Object.defineProperty(result, 'url', { value: url.href });
          Object.defineProperty(result, 'redirected', { value: false });
          if (noBody) response.resume();
          settled = true;
          resolve({ response: result, close });
        } catch (error) { fail(error); }
      }));
      req.on('error', fail);
      req.end();
      // Cover an abort delivered synchronously by an injected/OS connector.
      if (signal?.aborted) onAbort();
    } catch (error) { fail(error); }
  });
}

export function requestPinned(url, addresses, headers, signal) {
  // Node bypasses lookup for IP literals. A literal must itself be in the
  // validated set, rather than silently bypassing a differently pinned answer.
  const literal = hostname(url);
  if (isIP(literal) !== 0 && !addresses.some(entry => entry.address === literal)) {
    return Promise.reject(new Error('literal destination does not match pinned addresses'));
  }
  return request(url, headers, signal, () => {
    const options = { keepAlive: false, lookup: pinnedLookup(addresses), autoSelectFamily: true };
    return url.protocol === 'https:' ? new https.Agent(options) : new http.Agent(options);
  });
}

export function requestVia(proxyValue, url, headers, signal) {
  // proxyValue comes from the existing installed proxyRouteFor policy, never from
  // a model-supplied fetch URL. Every origin hop re-evaluates that policy.
  const proxy = new URL(proxyValue);
  if (proxy.protocol !== 'http:' && proxy.protocol !== 'https:') {
    return Promise.reject(new Error('unsupported web fetch proxy protocol'));
  }
  return request(url, headers, signal, (track, fail) => {
    const agent = url.protocol === 'https:' ? new https.Agent({ keepAlive: false }) : new http.Agent({ keepAlive: false });
    agent.createConnection = (options, callback) => {
      let completed = false;
      const done = (error, socket) => {
        if (completed) { if (error) socket?.destroy(); return; }
        completed = true;
        callback(error, socket);
      };
      const target = `${url.hostname}:${url.port || (url.protocol === 'https:' ? 443 : 80)}`;
      const connectHeaders = { host: target };
      if (proxy.username || proxy.password) {
        const credential = `${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`;
        connectHeaders['proxy-authorization'] = `Basic ${Buffer.from(credential).toString('base64')}`;
      }
      const proxyAgent = proxy.protocol === 'https:' ? new https.Agent({ keepAlive: false }) : new http.Agent({ keepAlive: false });
      track(proxyAgent);
      const connect = track((proxy.protocol === 'https:' ? https : http).request({
        protocol: proxy.protocol,
        hostname: hostname(proxy),
        port: proxy.port || (proxy.protocol === 'https:' ? 443 : 80),
        method: 'CONNECT', path: target, headers: connectHeaders, agent: proxyAgent,
      }));
      connect.on('error', error => done(error));
      connect.on('connect', (response, socket, head) => {
        track(response);
        track(socket);
        if (closedOrAborted()) { socket.destroy(); done(aborted(signal)); return; }
        if (response.statusCode !== 200) {
          socket.destroy();
          done(Object.assign(new Error(`web fetch proxy CONNECT refused (${response.statusCode})`), { code: 'DSH_PROXY_CONNECT_FAILED' }));
          return;
        }
        if (head.length) socket.unshift(head);
        if (url.protocol === 'http:') { done(null, socket); return; }
        // The original URL host remains the certificate identity and SNI even
        // though the underlying socket is connected to the configured proxy.
        const secure = track(tls.connect({
          socket,
          host: hostname(url),
          servername: isIP(hostname(url)) === 0 ? hostname(url) : undefined,
          rejectUnauthorized: true,
          checkServerIdentity: tls.checkServerIdentity,
          ALPNProtocols: ['http/1.1'],
        }));
        secure.once('secureConnect', () => done(null, secure));
        secure.once('error', error => done(error));
      });
      connect.end();
      function closedOrAborted() { return agent.destroyed === true || signal?.aborted; }
      if (signal?.aborted) { connect.destroy(aborted(signal)); fail(aborted(signal)); }
      return undefined; // Agent waits for exactly one callback, never a second socket.
    };
    return agent;
  });
}
