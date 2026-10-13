// Real local TCP/TLS/CONNECT regression tests. Policy dependencies are explicitly
// adapted below; these host tests are not a substitute for the real ARM guest run.
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { requestPinned, requestVia } from '../app/WebFetchTransport.bundle/web-fetch-transport.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, 'fixtures/web-transport');
const tlsOptions = { key: fs.readFileSync(path.join(fixture, 'test-key.pem')), cert: fs.readFileSync(path.join(fixture, 'test-cert.pem')) };
const active = new Set();
const servers = [];
const signal = () => AbortSignal.timeout(4000);
const pin = [{ address: '127.0.0.1', family: 4 }];
let passes = 0;
let originHits = [];
let connectHits = [];

async function test(name, run) {
  await run();
  passes++;
  console.log(`PASS ${name}`);
}
async function listen(server) {
  servers.push(server);
  server.on('connection', socket => { active.add(socket); socket.once('close', () => active.delete(socket)); });
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return server.address().port;
}
function serve(req, res) {
  originHits.push({ url: req.url, headers: req.headers, servername: req.socket.servername });
  if (req.url === '/hang') return;
  if (req.url === '/stream-hang') { res.writeHead(200, { 'content-type': 'text/plain' }); res.write('start'); return; }
  if (req.url === '/redirect') { res.writeHead(302, { location: '/ok' }); res.end(); return; }
  if (req.url === '/cross-origin') { res.writeHead(302, { location: 'http://127.0.0.1/private' }); res.end(); return; }
  if (req.url === '/large') { res.writeHead(200, { 'content-type': 'text/plain', 'content-length': 9999 }); res.end('large'); return; }
  if (req.url === '/truncated') { res.writeHead(200, { 'content-type': 'text/plain' }); res.write('abcdefghijklmnop'); res.end(); return; }
  if (req.url === '/binary') { res.writeHead(200, { 'content-type': 'application/octet-stream' }); res.end('binary'); return; }
  if (req.url === '/gzip-invalid') { res.writeHead(200, { 'content-type': 'text/plain', 'content-encoding': 'gzip' }); res.end('invalid gzip'); return; }
  if (req.url === '/abrupt') { res.writeHead(200, { 'content-type': 'text/plain', 'content-length': 100 }); res.write('start'); setTimeout(() => res.destroy(), 5); return; }
  const text = JSON.stringify({ weather: 'fixture-only', temperature: 23 });
  const kind = req.url.slice(1);
  const enc = ['gzip', 'deflate', 'br'].includes(kind) ? kind : undefined;
  const content = enc === 'gzip' ? zlib.gzipSync(text) : enc === 'deflate' ? zlib.deflateSync(text) : enc === 'br' ? zlib.brotliCompressSync(text) : Buffer.from(text);
  res.writeHead(200, { 'content-type': 'application/json', ...(enc ? { 'content-encoding': enc } : {}) });
  res.end(content);
}
const httpPort = await listen(http.createServer(serve));
const tlsPort = await listen(https.createServer(tlsOptions, serve));
function makeProxy(secure) {
  const proxy = secure ? https.createServer(tlsOptions) : http.createServer();
  proxy.on('connect', (req, socket, head) => {
    connectHits.push({ target: req.url, headers: req.headers });
    if (req.url.startsWith('hang.web-transport.test:')) {
      socket.once('end', () => socket.destroy()); socket.resume(); return;
    }
    if (req.headers['proxy-authorization'] !== `Basic ${Buffer.from('fixture:only').toString('base64')}`) {
      socket.end('HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n'); return;
    }
    const port = Number(req.url.split(':').at(-1));
    const upstream = net.connect(port, '127.0.0.1');
    active.add(upstream); upstream.once('close', () => active.delete(upstream));
    upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy());
    socket.once('close', () => upstream.destroy()); upstream.once('close', () => socket.destroy());
    upstream.once('connect', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
  });
  return proxy;
}
const proxyPort = await listen(makeProxy(false));
const secureProxyPort = await listen(makeProxy(true));
const url = (route = '/ok', secure = false) => new URL(`${secure ? 'https' : 'http'}://web-transport.test:${secure ? tlsPort : httpPort}${route}`);
const proxyUrl = (secure = false, auth = true) => `${secure ? 'https' : 'http'}://${auth ? 'fixture:only@' : ''}127.0.0.1:${secure ? secureProxyPort : proxyPort}`;
async function consume(result) { try { return await result.response.text(); } finally { await result.close(); } }

try {
  // Poison global fetch: the compatibility transport must never silently route
  // through a replacement that lacks validated-address pinning or proxy policy.
  globalThis.fetch = () => { throw new Error('global fetch must not be used'); };
  await test('jitless direct HTTP pins DNS and preserves Host', async () => {
    const result = await requestPinned(url(), pin, { 'user-agent': 'fixture' }, signal());
    assert.equal(result.response.status, 200);
    assert.equal(JSON.parse(await consume(result)).temperature, 23);
    assert.equal(originHits.at(-1).headers.host, `web-transport.test:${httpPort}`);
  });
  await test('direct HTTPS preserves SNI and verifies trusted hostname', async () => {
    assert.equal(JSON.parse(await consume(await requestPinned(url('/ok', true), pin, {}, signal()))).temperature, 23);
    assert.equal(originHits.at(-1).servername, 'web-transport.test');
  });
  await test('direct HTTPS rejects certificate hostname mismatch', async () => {
    const wrong = new URL(`https://wrong.web-transport.test:${tlsPort}/ok`);
    await assert.rejects(requestPinned(wrong, pin, {}, signal()), /not in the cert|Hostname\/IP|does not match/i);
  });
  await test('TLS rejects an untrusted certificate without fixture CA environment', async () => {
    const env = { ...process.env }; delete env.NODE_EXTRA_CA_CERTS;
    // Child has no test CA; the production module uses normal system trust.
    const transportUrl = pathToFileURL(path.join(here, '../app/WebFetchTransport.bundle/web-fetch-transport.mjs')).href;
    const script = `import {requestPinned} from ${JSON.stringify(transportUrl)};\n` +
      `try { const r=await requestPinned(new URL(${JSON.stringify(url('/ok', true).href)}),[{address:'127.0.0.1',family:4}],{},AbortSignal.timeout(4000));await r.close();process.exitCode=1; }\n` +
      `catch(e){if(e.code==='DEPTH_ZERO_SELF_SIGNED_CERT'||e.code==='SELF_SIGNED_CERT_IN_CHAIN'){console.log('EXPECTED_TLS_REJECTION');}else{console.error(e);process.exitCode=1;}}`;
    const child = spawn(process.execPath, ['--jitless', '--input-type=module', '-e', script], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = ''; let err = ''; child.stdout.on('data', chunk => out += chunk); child.stderr.on('data', chunk => err += chunk);
    const [code, childSignal] = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve([code, signal])); });
    assert.equal(childSignal, null); assert.equal(code, 0, err); assert.match(out, /^EXPECTED_TLS_REJECTION\r?\n$/);
  });
  for (const encoding of ['gzip', 'deflate', 'br']) await test(`streaming ${encoding} is decoded`, async () => {
    assert.equal(JSON.parse(await consume(await requestPinned(url(`/${encoding}`), pin, {}, signal()))).temperature, 23);
  });
  await test('malformed gzip rejects body and closes resources', async () => {
    await assert.rejects(consume(await requestPinned(url('/gzip-invalid'), pin, {}, signal())));
  });
  await test('abrupt body termination rejects instead of returning partial success', async () => {
    await assert.rejects(consume(await requestPinned(url('/abrupt'), pin, {}, signal())));
  });
  await test('redirect remains manual for provider policy', async () => {
    const result = await requestPinned(url('/redirect'), pin, {}, signal());
    assert.equal(result.response.status, 302); assert.equal(result.response.headers.get('location'), '/ok');
    await result.close();
  });
  await test('abort before headers destroys pending request', async () => {
    await assert.rejects(requestPinned(url('/hang'), pin, {}, AbortSignal.timeout(30)));
  });
  await test('abort during body rejects web stream', async () => {
    const controller = new AbortController();
    const result = await requestPinned(url('/stream-hang'), pin, {}, AbortSignal.any([controller.signal, signal()]));
    assert.equal(result.response.status, 200);
    controller.abort();
    await assert.rejects(consume(result));
  });
  await test('already aborted request makes no connection', async () => {
    const before = originHits.length; const controller = new AbortController(); controller.abort();
    await assert.rejects(requestPinned(url(), pin, {}, controller.signal));
    assert.equal(originHits.length, before);
  });
  for (const secureProxy of [false, true]) for (const secureOrigin of [false, true]) {
    await test(`${secureProxy ? 'HTTPS' : 'HTTP'} CONNECT proxy to ${secureOrigin ? 'HTTPS' : 'HTTP'} origin`, async () => {
      const result = await requestVia(proxyUrl(secureProxy), url('/ok', secureOrigin), { 'proxy-authorization': 'must-not-leak' }, signal());
      assert.equal(JSON.parse(await consume(result)).temperature, 23);
      assert.equal(connectHits.at(-1).target, `web-transport.test:${secureOrigin ? tlsPort : httpPort}`);
      assert.equal(originHits.at(-1).headers['proxy-authorization'], undefined);
      if (secureOrigin) assert.equal(originHits.at(-1).servername, 'web-transport.test');
    });
  }
  await test('proxy authentication refusal fails without direct fallback', async () => {
    const before = originHits.length;
    await assert.rejects(requestVia(proxyUrl(false, false), url(), {}, signal()), /CONNECT refused \(407\)/);
    assert.equal(originHits.length, before);
  });
  await test('abort while awaiting proxy CONNECT closes its socket', async () => {
    const target = new URL(`http://hang.web-transport.test:${httpPort}/ok`);
    await assert.rejects(requestVia(proxyUrl(), target, {}, AbortSignal.timeout(30)));
  });
  await test('proxy CONNECT retains origin certificate validation', async () => {
    await assert.rejects(requestVia(proxyUrl(), new URL(`https://wrong.web-transport.test:${tlsPort}/ok`), {}, signal()), /not in the cert|Hostname\/IP|does not match/i);
  });
  await test('invalid pin cannot silently fall back to DNS', async () => {
    await assert.rejects(requestPinned(url(), [{ address: '127.0.0.1', family: 6 }], {}, signal()), /pinned/);
    await assert.rejects(requestPinned(new URL(`http://127.0.0.1:${httpPort}/ok`), [{ address: '8.8.8.8', family: 4 }], {}, signal()), /pinned/);
  });
  await test('100 request/close cycles leave no live client/server sockets', async () => {
    for (let i = 0; i < 100; i++) {
      const result = i % 2 ? await requestVia(proxyUrl(), url(), {}, signal()) : await requestPinned(url(), pin, {}, signal());
      await consume(result); await result.close();
    }
    for (let i = 0; active.size && i < 50; i++) await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(active.size, 0, `residual sockets: ${active.size}`);
    assert.equal(process._getActiveHandles().filter(handle => handle instanceof net.Socket && handle.remotePort && !handle.destroyed).length, 0);
  });

  if (process.env.DSH_WEB_GUEST === '1') {
    // This branch imports the complete actual npm packages in the ARM guest,
    // including their real timeout/proxy/schema dependencies. The injected DNS
    // seam only directs the positive fixture to the local controlled server.
    const target = '/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js';
    const production = await import(target);
    const original = await import('/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/dsh-original-test.js');
    const actualLimits = { timeoutMs: 4000, maxResponseBytes: 1000, maxBodyChars: 1000, maxRedirects: 2, userAgent: 'fixture' };
    await test('ARM original packaged provider reproduces incompatible parser failure', async () => {
      const before = originHits.length;
      await assert.rejects(new original.HttpFetchProvider(actualLimits, async () => pin).fetch({ url: url().href }), error => {
        const chain = []; for (let item = error; item; item = item.cause) chain.push(String(item));
        return error.code === 'WEB_PROVIDER_ERROR' && /llhttp_alloc|WebAssembly/.test(chain.join(' '));
      });
      assert.equal(originHits.length, before, 'original parser failed before sending HTTP request');
    });
    await test('ARM complete patched package reads HTTPS and same-origin redirect', async () => {
      const provider = new production.HttpFetchProvider(actualLimits, async () => pin);
      assert.equal(JSON.parse((await provider.fetch({ url: url('/redirect', true).href })).body.content).temperature, 23);
    });
    await test('ARM complete package rejects private destination without fixture resolver', async () => {
      const before = originHits.length;
      await assert.rejects(new production.HttpFetchProvider(actualLimits).fetch({ url: `http://127.0.0.1:${httpPort}/ok` }), error => error.code === 'WEB_BLOCKED_URL');
      assert.equal(originHits.length, before);
    });
    await test('ARM complete package obeys installed proxy policy without origin DNS', async () => {
      const proxy = await import('/usr/local/lib/node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js');
      const restore = await proxy.installProxyFromEnvironment({ get(name) {
        return ['http_proxy', 'https_proxy'].includes(name) ? { value: proxyUrl() } : undefined;
      } }, () => {});
      try {
        const provider = new production.HttpFetchProvider(actualLimits, async () => { throw new Error('unexpected local proxy-origin resolution'); });
        assert.equal((await provider.fetch({ url: url('/ok', true).href })).statusCode, 200);
      } finally { await restore(); }
    });
  }

  const sourcePath = process.env.DSH_WEB_FETCH_SOURCE;
  const ipaddrPath = process.env.DSH_IPADDR_SOURCE;
  assert.ok(sourcePath && ipaddrPath, 'real bundled provider and ipaddr source paths are required');
  const source = fs.readFileSync(sourcePath, 'utf8');
  assert.equal(createHash('sha256').update(source).digest('hex'), '489fef91b0c11c063029ea7aed27b312817570b9c3177aeaa44983b9a25aedcd');
  const manifest = JSON.parse(fs.readFileSync(path.join(here, '../app/WebFetchTransport.bundle/manifest.json'), 'utf8'));
  let patched = source;
  for (const replacement of manifest.patches[0].replacements) {
    assert.equal(patched.split(replacement.find).length - 1, replacement.count);
    patched = patched.replace(replacement.find, replacement.replace);
  }
  assert.equal(createHash('sha256').update(patched).digest('hex'), manifest.patches[0].patched_sha256);
  const resource = fs.readFileSync(path.join(here, '../app/WebFetchTransport.bundle/web-fetch-transport.mjs'));
  assert.equal(createHash('sha256').update(resource).digest('hex'), manifest.files[0].sha256);
  const ipaddr = createRequire(import.meta.url)(path.resolve(ipaddrPath));
  class WebError extends Error { constructor(message, code, options) { super(message, options); this.code = code; } }
  const deadline = (parent, timeoutMs) => {
    const controller = new AbortController(); const expire = setTimeout(() => controller.abort({ fixtureTimeout: true }), timeoutMs);
    const abort = () => controller.abort(parent.reason); parent?.addEventListener('abort', abort, { once: true });
    return { signal: controller.signal, [Symbol.dispose]() { clearTimeout(expire); parent?.removeEventListener('abort', abort); } };
  };
  let route = { proxied: false };
  // Evaluate the actual patched provider implementation. Only its imports and
  // plugin registration/config tail are adapted; transport and policy code are exact.
  const implementation = patched.replace(/^import .*;\r?\n/gm, '').split('const MAX_NODE_TIMER_DELAY_MS =')[0];
  const api = new Function('WebError', 'lookup', 'isIP', 'ipaddr', 'proxyRouteFor', 'deadline', 'timeoutOf', 'dshRequestPinned', 'dshRequestVia',
    `${implementation}\nreturn { HttpFetchProvider, resolvePublicAddresses, validateFetchUrl, isPublicIpAddress };`)
    (WebError, () => { throw new Error('unexpected OS DNS'); }, net.isIP, ipaddr, () => route,
      deadline, signal => signal.reason?.fixtureTimeout ? signal.reason : undefined, requestPinned, requestVia);
  const limits = { timeoutMs: 1000, maxResponseBytes: 1000, maxBodyChars: 1000, maxRedirects: 2, userAgent: 'fixture' };
  const provider = new api.HttpFetchProvider(limits, async () => pin);
  await test('exact production provider reads transport and same-origin redirect', async () => {
    const answer = await provider.fetch({ url: url('/redirect').href });
    assert.equal(answer.statusCode, 200); assert.equal(JSON.parse(answer.body.content).temperature, 23);
  });
  await test('exact production provider rejects cross-origin redirect', async () => {
    await assert.rejects(provider.fetch({ url: url('/cross-origin').href }), error => error.code === 'WEB_REDIRECT_BLOCKED');
  });
  await test('exact production provider rejects unsupported content and declared size', async () => {
    await assert.rejects(provider.fetch({ url: url('/binary').href }), error => error.code === 'WEB_UNSUPPORTED_CONTENT_TYPE');
    await assert.rejects(provider.fetch({ url: url('/large').href }), error => error.code === 'WEB_FETCH_TOO_LARGE');
  });
  await test('decoded response and character caps remain enforced', async () => {
    const capped = new api.HttpFetchProvider({ ...limits, maxResponseBytes: 8, maxBodyChars: 5 }, async () => pin);
    const answer = await capped.fetch({ url: url('/gzip').href });
    assert.equal(answer.truncated, true); assert.equal(answer.body.content.length, 5);
  });
  await test('private literals and mixed public/private DNS answers are blocked', async () => {
    for (const hostname of ['127.0.0.1', '10.0.0.1', '[::1]', '[::ffff:127.0.0.1]']) {
      await assert.rejects(api.resolvePublicAddresses(hostname, signal(), async host => {
        assert.equal(host, 'ipv4only.arpa'); return [];
      }), error => error.code === 'WEB_BLOCKED_URL');
    }
    await assert.rejects(api.resolvePublicAddresses('rebind.test', signal(), async () => [
      { address: '8.8.8.8', family: 4 }, { address: '127.0.0.1', family: 4 },
    ]), error => error.code === 'WEB_BLOCKED_URL');
  });
  await test('NAT64-discovered private IPv4 targets remain blocked', async () => {
    const resolver = async host => host === 'ipv4only.arpa' ? [
      { address: '2001:4860:64::c000:aa', family: 6 },
    ] : [{ address: '2001:4860:64::7f00:1', family: 6 }];
    await assert.rejects(api.resolvePublicAddresses('translated.test', signal(), resolver), error => error.code === 'WEB_BLOCKED_URL');
  });
  await test('credential URL and non-HTTP scheme remain blocked', async () => {
    assert.throws(() => api.validateFetchUrl('http://secret@web-transport.test/'), error => error.code === 'WEB_BLOCKED_URL');
    assert.throws(() => api.validateFetchUrl('file:///root/private'), error => error.code === 'WEB_INVALID_URL');
  });
  await test('provider uses selected proxy without local origin DNS', async () => {
    route = { proxied: true, proxy: proxyUrl(), dispatcher: { invalidForNativeFetch: true } };
    const through = new api.HttpFetchProvider(limits, async () => { throw new Error('proxy origin must not resolve locally'); });
    assert.equal((await through.fetch({ url: url().href })).statusCode, 200);
    route = { proxied: false };
  });
  await test('proxied private literal is still rejected before CONNECT', async () => {
    const before = connectHits.length;
    route = { proxied: true, proxy: proxyUrl(), dispatcher: {} };
    const guarded = new api.HttpFetchProvider(limits);
    await assert.rejects(guarded.fetch({ url: `http://127.0.0.1:${httpPort}/ok` }), error => error.code === 'WEB_BLOCKED_URL');
    assert.equal(connectHits.length, before); route = { proxied: false };
  });
  await test('provider deadline remains a failing timeout, not partial success', async () => {
    const limited = new api.HttpFetchProvider({ ...limits, timeoutMs: 30 }, async () => pin);
    await assert.rejects(limited.fetch({ url: url('/hang').href }), error => error.code === 'WEB_FETCH_TIMEOUT');
  });
  console.log(`web fetch transport: ${passes}/${passes} passed; real sockets/TLS; policy dependency adapters; 100 close cycles`);
  if (process.env.DSH_WEB_GUEST === '1') console.log('WEB_FETCH_ARM_GUEST_COMPLETED=1');
} finally {
  for (const socket of active) socket.destroy();
  await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve))));
}
