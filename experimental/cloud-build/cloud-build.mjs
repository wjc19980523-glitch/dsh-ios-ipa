// Explicit GitHub Actions operations. No git push, source edit, gh, automatic
// POST retry, signing or install. Credentials stay in this trusted module.
import https from 'node:https';
import http from 'node:http';
import tls from 'node:tls';
import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { mkdir, open, lstat, readdir, unlink, link } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { secureParents, hashVerifiedFile, extractVerifiedArtifact } from './cloud-artifact.mjs';

const API = 'https://api.github.com';
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA = /^[a-f0-9]{40}$/;
const MAX = 512 * 1024 * 1024;
const execFileAsync = promisify(execFile);
const phases = new Set(['created','authorizing','dispatching','dispatch_unknown','waiting','download_pending',
  'downloading','downloaded','verified','exporting','saved','cancelled','failed']);
const fail = (code, detail = {}) => { throw Object.assign(new Error(code), { cloudCode: code, ...detail }); };
const sha = value => createHash('sha256').update(value).digest('hex');
const integer = value => Number.isSafeInteger(value) && value > 0;
const stopped = signal => { if (signal?.aborted) fail('interrupted'); };
export const cloudScope = exec => {
  const owner = exec?.agent?.id;
  if (typeof owner !== 'string' || !owner || owner.length > 1024) fail('missing_session_identity');
  return sha(owner).slice(0, 24);
};
export async function discoverCloudRepository(exec, { client = new GitHubActions(), probe = execFileAsync } = {}) {
  const cwd = exec?.agent?.session?.header?.cwd;
  if (typeof cwd !== 'string' || resolve(cwd) !== cwd) fail('missing_workspace');
  await secureParents(cwd);
  let remote, head, branch;
  try {
    const options = { cwd, timeout: 10000, maxBuffer: 16384, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } };
    remote = (await probe('git', ['config','--get','remote.origin.url'], options)).stdout.trim();
    head = (await probe('git', ['rev-parse','--verify','HEAD'], options)).stdout.trim();
    try { branch = (await probe('git', ['symbolic-ref','--quiet','--short','HEAD'], options)).stdout.trim(); } catch { branch = null; }
  } catch { fail('git_repository_unavailable'); }
  let repository;
  const ssh = /^git@github\.com:([^\s]+?)(?:\.git)?$/.exec(remote);
  if (ssh) repository = ssh[1];
  else {
    let url; try { url = new URL(remote); } catch { fail('github_origin_required'); }
    if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.port || url.search || url.hash || url.username || url.password) fail('github_origin_without_embedded_credentials_required');
    repository = url.pathname.replace(/^\//, '').replace(/\.git$/, '');
  }
  repo(repository); if (!SHA.test(head)) fail('git_head_unverified');
  if (branch !== null) ref(branch);
  const data = await client.json(`/repos/${repository}/actions/workflows?per_page=100`, { signal: exec?.signal });
  if (!Array.isArray(data.workflows) || data.workflows.length > 100 || !Number.isSafeInteger(data.total_count) || data.total_count > 100) fail('workflow_list_limit');
  return { repository, head_sha: head, branch, workflows: data.workflows.map(w => ({ id: w.id,
    name: String(w.name ?? '').slice(0, 150), path: String(w.path ?? '').slice(0, 200), state: w.state })),
    notice: 'Read-only discovery. Source changes, git push and workflow dispatch require separate explicit authorization.' };
}
function repo(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/.test(value) ||
      value.endsWith('/.') || value.endsWith('/..')) fail('invalid_repository');
  return value;
}
function workflow(value) {
  if (!(integer(value) || typeof value === 'string' && /^[A-Za-z0-9_.-]{1,150}\.ya?ml$/.test(value))) fail('invalid_workflow');
  return String(value);
}
function ref(value) {
  if (typeof value !== 'string' || value.length > 256 || !value || /[\s\x00-\x1f\x7f~^:?*\[\\]/.test(value) ||
      value.includes('..') || value.startsWith('-') || value.startsWith('/') || value.endsWith('/')) fail('invalid_ref');
  return value;
}
function artifactName(value) {
  if (typeof value !== 'string' || !value || value.length > 200 || /[\x00-\x1f\x7f]/.test(value)) fail('invalid_artifact_name');
  return value;
}
export function buildState(run) {
  if (!run || typeof run.status !== 'string') fail('invalid_run');
  if (['queued','waiting','pending','requested'].includes(run.status)) return 'pending';
  if (run.status === 'in_progress') return 'running';
  if (run.status !== 'completed') fail('unknown_run_status');
  if (run.conclusion === 'success') return 'success';
  if (run.conclusion === 'cancelled') return 'cancelled';
  if (run.conclusion === 'timed_out') return 'timed_out';
  if (['failure','action_required','neutral','skipped','stale','startup_failure'].includes(run.conclusion)) return 'failed';
  fail('unknown_run_conclusion');
}
export function githubFailure(status, headers = {}) {
  const value = { status, reason: status === 401 ? 'github_authentication_required' : status === 403 ?
    'github_forbidden_or_rate_limited' : status === 404 ? 'github_not_found_or_no_access' : status === 410 ?
    'artifact_expired' : status === 429 ? 'github_rate_limited' : status === 422 ?
    'workflow_dispatch_unavailable_or_invalid_inputs' : 'github_request_failed' };
  const retry = String(headers['retry-after'] ?? '');
  const reset = String(headers['x-ratelimit-reset'] ?? '');
  if (/^\d{1,8}$/.test(retry)) value.retry_after_seconds = Number(retry);
  if (/^\d{1,12}$/.test(reset)) value.rate_limit_reset = Number(reset);
  return value;
}
export function cloudError(error) {
  const code = error?.cloudCode ?? error?.code;
  const reason = typeof code === 'string' && /^[a-z_]{1,100}$/.test(code) ? code : 'cloud_operation_failed';
  return { state: reason === 'interrupted' ? 'interrupted' : 'failed', reason,
    ...(Number.isInteger(error?.status) && error.status >= 100 && error.status <= 599 ? { http_status: error.status } : {}),
    ...(typeof error?.reason === 'string' && /^[a-z_]{1,100}$/.test(error.reason) ? { detail: error.reason } : {}) };
}
// No redirects here: a GitHub credential must reach only api.github.com. The
// single artifact redirect is handled separately with authorization removed.
export function httpsTransport(url, { method = 'GET', headers = {}, body, signal,
  timeoutMs = 30000, maxBytes = 2 * 1024 * 1024, sink, proxy } = {}) {
  return new Promise((resolveDone, reject) => {
    let req, response, settled = false, timer, bytes = 0, agent;
    const resources = new Set();
    const track = value => { resources.add(value); value.on('error', () => {}); return value; };
    const chunks = [];
    const finish = (error, value) => {
      if (settled) return; settled = true;
      clearTimeout(timer); signal?.removeEventListener('abort', abort);
      for (const value of resources) value.destroy();
      agent?.destroy();
      if (error) { req?.destroy(); response?.destroy(); reject(error); } else resolveDone(value);
    };
    const abort = () => finish(Object.assign(new Error('interrupted'), { cloudCode: 'interrupted' }));
    if (signal?.aborted) return abort();
    signal?.addEventListener('abort', abort, { once: true });
    try {
      if (proxy) {
        const endpoint = new URL(proxy);
        if (!['http:','https:'].includes(endpoint.protocol)) fail('unsupported_github_proxy');
        agent = new https.Agent({ keepAlive: false });
        agent.createConnection = (_options, callback) => {
          let called = false;
          const done = (error, socket) => { if (called) { if (error) socket?.destroy(); return; } called = true; callback(error, socket); };
          const target = `${url.hostname}:443`, connectHeaders = { host: target };
          if (endpoint.username || endpoint.password) connectHeaders['proxy-authorization'] =
            `Basic ${Buffer.from(`${decodeURIComponent(endpoint.username)}:${decodeURIComponent(endpoint.password)}`).toString('base64')}`;
          const connector = track((endpoint.protocol === 'https:' ? https : http).request({
            protocol: endpoint.protocol, hostname: endpoint.hostname, port: endpoint.port ||
              (endpoint.protocol === 'https:' ? 443 : 80), method: 'CONNECT', path: target,
            headers: connectHeaders, agent: false }));
          connector.on('error', () => done(Object.assign(new Error('proxy_connect_failed'), { cloudCode: 'proxy_connect_failed' })));
          connector.on('connect', (incoming, socket, head) => {
            track(socket);
            if (settled || signal?.aborted || incoming.statusCode !== 200) {
              socket.destroy(); done(Object.assign(new Error('proxy_connect_failed'), { cloudCode: 'proxy_connect_failed' })); return;
            }
            if (head.length) socket.unshift(head);
            const secure = track(tls.connect({ socket, servername: url.hostname, rejectUnauthorized: true,
              checkServerIdentity: tls.checkServerIdentity, ALPNProtocols: ['http/1.1'] }));
            secure.once('secureConnect', () => done(null, secure));
            secure.once('error', () => done(Object.assign(new Error('proxy_tls_failed'), { cloudCode: 'proxy_tls_failed' })));
          });
          connector.end(); return undefined;
        };
      }
      req = https.request(url, { method, headers, agent: agent ?? false }, incoming => {
        response = incoming;
        (async () => {
          for await (const chunk of incoming) {
            bytes += chunk.length;
            if (bytes > maxBytes) fail('response_size_limit');
            if (sink && incoming.statusCode === 200) await sink(chunk);
            else chunks.push(chunk);
          }
          finish(null, { status: incoming.statusCode, headers: incoming.headers, bytes, body: Buffer.concat(chunks) });
        })().catch(error => finish(error));
      });
      req.on('error', () => finish(Object.assign(new Error('network_interrupted'), { cloudCode: 'network_interrupted' })));
      timer = setTimeout(() => finish(Object.assign(new Error('request_timed_out'), { cloudCode: 'request_timed_out' })), timeoutMs);
      req.end(body);
    } catch { finish(Object.assign(new Error('transport_failed'), { cloudCode: 'transport_failed' })); }
  });
}
export function githubProxy(url, environment) {
  const bypass = environment.NO_PROXY ?? environment.no_proxy ?? '';
  for (const value of bypass.split(',').map(v => v.trim().toLowerCase()).filter(Boolean)) {
    if (value === '*') return undefined;
    const host = value.replace(/:443$/, '').replace(/^\./, '');
    if (url.hostname.toLowerCase() === host || value.startsWith('.') && url.hostname.toLowerCase().endsWith(`.${host}`)) return undefined;
  }
  const value = environment.HTTPS_PROXY ?? environment.https_proxy ?? environment.ALL_PROXY ?? environment.all_proxy;
  if (!value) return undefined;
  try {
    const endpoint = new URL(value);
    if (!['http:','https:'].includes(endpoint.protocol) || endpoint.pathname !== '/' || endpoint.search || endpoint.hash) fail('unsupported_github_proxy');
    return value;
  } catch { fail('unsupported_github_proxy'); }
}
export function credentialResolver(service, environment = process.env) {
  return async () => {
    for (const name of ['GH_TOKEN','GITHUB_TOKEN']) {
      let value;
      try { value = service?.resolve ? (await service.resolve(name))?.value : environment[name]; }
      catch { fail('github_credentials_unavailable'); }
      if (value === undefined || value === '') continue;
      if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x20\x7f]/.test(value)) fail('invalid_github_credential');
      return value;
    }
    fail('github_authentication_required');
  };
}
export class GitHubActions {
  constructor({ getCredential = credentialResolver(), transport = httpsTransport, environment = process.env } = {}) {
    this.getCredential = getCredential; this.transport = transport; this.environment = environment;
  }
  async request(path, { method = 'GET', body, signal, statuses = [200] } = {}) {
    if (!/^\/repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(actions|contents)\//.test(path) || /[\r\n#]/.test(path)) fail('invalid_api_path');
    const token = await this.getCredential();
    if (typeof token !== 'string' || !token || token.length > 4096 || /[\x00-\x20\x7f]/.test(token)) fail('github_authentication_required');
    const url = new URL(path, API);
    const result = await this.transport(url, { method, signal, proxy: githubProxy(url, this.environment), body: body ? Buffer.from(JSON.stringify(body)) : undefined,
      headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`,
        'x-github-api-version': '2026-03-10', 'user-agent': 'DSHIOS-cloud-build/1',
        ...(body ? { 'content-type': 'application/json' } : {}) } });
    if (!statuses.includes(result.status)) fail('github_http_error', githubFailure(result.status, result.headers));
    return result;
  }
  async json(path, options) {
    const result = await this.request(path, options);
    try { return JSON.parse(result.body.toString('utf8')); } catch { fail('invalid_github_response'); }
  }
  async run(repository, id, signal) {
    repo(repository); if (!integer(id)) fail('invalid_run_id');
    const run = await this.json(`/repos/${repository}/actions/runs/${id}`, { signal });
    if (run.id !== id || run.repository?.full_name?.toLowerCase() !== repository.toLowerCase() ||
        !SHA.test(run.head_sha ?? '') || !integer(run.run_attempt) || !integer(run.workflow_id)) fail('run_identity_mismatch');
    buildState(run); return run;
  }
  async artifacts(repository, run, name, signal) {
    const matches = [];
    for (let page = 1; page <= 10; page++) {
      const data = await this.json(`/repos/${repo(repository)}/actions/runs/${run.id}/artifacts?per_page=100&page=${page}`, { signal });
      if (!Array.isArray(data.artifacts) || data.artifacts.length > 100 || !Number.isSafeInteger(data.total_count) || data.total_count > 1000) fail('invalid_artifact_list');
      matches.push(...data.artifacts.filter(a => a.name === name));
      if (page * 100 >= data.total_count) break;
      if (page === 10) fail('artifact_list_limit');
    }
    if (matches.length !== 1) fail(matches.length ? 'ambiguous_artifact_name' : 'artifact_not_found');
    const value = matches[0];
    if (value.expired === true || Date.parse(value.expires_at) <= Date.now()) fail('artifact_expired');
    if (!integer(value.id) || !Number.isSafeInteger(value.size_in_bytes) || value.size_in_bytes < 22 || value.size_in_bytes > MAX ||
        value.expired !== false || !Number.isFinite(Date.parse(value.expires_at)) ||
        !/^sha256:[a-f0-9]{64}$/.test(value.digest ?? '') || value.workflow_run?.id !== run.id || value.workflow_run.head_sha !== run.head_sha)
      fail('artifact_identity_or_digest_unverified');
    return value;
  }
  async failures(repository, run, signal) {
    const data = await this.json(`/repos/${repo(repository)}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`, { signal });
    if (!Array.isArray(data.jobs)) fail('invalid_jobs_response');
    const failed = data.jobs.filter(j => j.conclusion && j.conclusion !== 'success' && j.conclusion !== 'skipped').slice(0, 10)
      .map(j => ({ job_id: j.id, name: String(j.name ?? '').slice(0, 150), conclusion: j.conclusion,
        steps: (j.steps ?? []).filter(s => s.conclusion && !['success','skipped'].includes(s.conclusion)).slice(0, 10)
          .map(s => ({ number: s.number, name: String(s.name ?? '').slice(0, 150), conclusion: s.conclusion })) }));
    for (const job of failed.slice(0, 3)) {
      try {
        const initial = await this.request(`/repos/${repository}/actions/jobs/${job.job_id}/logs`, { signal, statuses: [302] });
        const url = artifactRedirect(initial.headers.location);
        const result = await this.transport(url, { signal, proxy: githubProxy(url, this.environment), maxBytes: 2 * 1024 * 1024, timeoutMs: 30000 });
        if (result.status !== 200) fail('job_log_unavailable');
        const token = await this.getCredential();
        // No raw log persistence. Return a bounded error excerpt, masking the
        // active credential, standard token shapes and common secret headers.
        const text = result.body.toString('utf8').split(token).join('[redacted]')
          .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b/g, '[redacted]')
          .replace(/authorization\s*[:=]\s*(?:(?:Bearer|Basic)\s+)?[^\s,;]+/gi, 'authorization: [redacted]')
          .replace(/((?:token|password|secret|api[_-]?key)\s*[:=]\s*)[^\s,;]+/gi, '$1[redacted]');
        job.error_excerpt = text.split(/\r?\n/).filter(line => /(?:##\[error\]|\berror:|\bfatal:|BUILD FAILED|ARCHIVE FAILED|exit code [1-9])/i.test(line))
          .slice(0, 15).map(line => line.slice(0, 400));
        job.logs = job.error_excerpt.length ? 'original job error lines; credentials masked' : 'no matching error lines; open original job log';
      } catch { job.logs = 'original log unavailable or exceeds safe excerpt limit; open the named job'; }
    }
    return failed;
  }
  async download(repository, artifact, directory, { signal, progress = () => {} } = {}) {
    await secureParents(directory);
    const destination = join(directory, `artifact-${artifact.id}.zip`);
    try {
      const existing = await hashVerifiedFile(destination, MAX, signal);
      if (existing.bytes === artifact.size_in_bytes && existing.sha256 === artifact.digest.slice(7)) return destination;
      fail('existing_artifact_preserved');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const response = await this.request(`/repos/${repo(repository)}/actions/artifacts/${artifact.id}/zip`, { signal, statuses: [302] });
    const url = artifactRedirect(response.headers.location);
    const temporary = join(directory, `.download-${randomUUID()}`);
    const file = await open(temporary, 'wx', 0o600); let bytes = 0;
    try {
      const result = await this.transport(url, { signal, proxy: githubProxy(url, this.environment), timeoutMs: 900000, maxBytes: artifact.size_in_bytes,
        headers: { accept: 'application/octet-stream', 'user-agent': 'DSHIOS-cloud-build/1' }, sink: async chunk => {
          bytes += chunk.length;
          let at = 0; while (at < chunk.length) { const written = await file.write(chunk, at, chunk.length - at); at += written.bytesWritten; }
          try { progress({ stage: 'downloading', bytes, total_bytes: artifact.size_in_bytes }); } catch {}
        } });
      if (result.status !== 200) fail('artifact_download_http_error', githubFailure(result.status, result.headers));
      await file.sync(); await file.close();
      const checked = await hashVerifiedFile(temporary, MAX, signal);
      if (checked.bytes !== artifact.size_in_bytes || checked.sha256 !== artifact.digest.slice(7)) fail('artifact_digest_mismatch');
      stopped(signal);
      await secureParents(directory); await link(temporary, destination);
      const parent = await open(directory, 'r'); try { await parent.sync(); } finally { await parent.close(); }
      return destination;
    } finally { await file.close().catch(() => {}); await unlink(temporary).catch(() => {}); }
  }
}
function artifactRedirect(location) {
  let url;
  try { url = new URL(location); } catch { fail('invalid_artifact_redirect'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.port ||
      !/(^|\.)(blob\.core\.windows\.net|actions\.githubusercontent\.com|githubusercontent\.com)$/.test(url.hostname)) fail('untrusted_artifact_redirect');
  return url;
}

// Immutable sequence files are atomic compare-and-set checkpoints. A second
// caller cannot publish the same next revision, including before a POST. No
// stale PID lock needs to be deleted after a killed/paused Agent.
export class CloudCheckpoint {
  constructor(directory, scope) {
    if (resolve(directory) !== directory || !/^[a-f0-9]{24}$/.test(scope ?? '')) fail('invalid_checkpoint_scope');
    this.directory = join(directory, scope); this.scope = scope;
  }
  async setup(id) {
    if (!UUID.test(id ?? '')) fail('invalid_request_id');
    await secureParents(dirname(this.directory));
    for (const path of [this.directory, join(this.directory, id)]) {
      try { await mkdir(path, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
      await secureParents(path);
    }
    return join(this.directory, id);
  }
  async read(id) {
    const directory = await this.setup(id), names = (await readdir(directory)).filter(n => /^\d{6}\.json$/.test(n)).sort();
    if (!names.length) return null;
    if (names.length > 1000) fail('checkpoint_limit');
    const path = join(directory, names.at(-1)), stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 32768) fail('unsafe_checkpoint');
    const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK | (constants.O_NOFOLLOW ?? 0));
    let value;
    try {
      const opened = await file.stat();
      if (!opened.isFile() || opened.ino !== stat.ino || opened.dev !== stat.dev) fail('unsafe_checkpoint');
      value = JSON.parse(await file.readFile('utf8'));
    } finally { await file.close(); }
    if (value.schema !== 1 || value.scope !== this.scope || value.request_id !== id || !phases.has(value.phase) || value.record?.phase !== value.phase ||
        `${String(value.revision).padStart(6, '0')}.json` !== names.at(-1) || value.checksum !== sha(JSON.stringify(value.record))) fail('invalid_checkpoint');
    return { ...value.record, request_id: id, revision: value.revision, phase: value.phase };
  }
  async list() {
    await secureParents(dirname(this.directory));
    try { await mkdir(this.directory, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    await secureParents(this.directory);
    const ids = (await readdir(this.directory)).filter(id => UUID.test(id));
    if (ids.length > 256) fail('checkpoint_history_limit');
    const records = [];
    for (const id of ids) { const value = await this.read(id); if (value) records.push(value); }
    return records;
  }
  async write(previous, patch) {
    const id = patch.request_id ?? previous?.request_id, directory = await this.setup(id), revision = (previous?.revision ?? 0) + 1;
    if (revision > 1000) fail('checkpoint_limit');
    const record = { ...previous, ...patch }; delete record.revision; delete record.request_id;
    if (!phases.has(record.phase)) fail('invalid_checkpoint_phase');
    // Deliberate fixed safe schema: no token, URL query, input values, commands,
    // full logs, native session identifier or binary data can be journalled.
    const keys = ['repository','artifact_name','workflow','ref','fingerprint','run_id','run_attempt','head_sha',
      'artifact_id','artifact_size','artifact_sha256','archive','ipa','export','phase','build_state','reason'];
    if (Object.keys(record).some(k => !keys.includes(k))) fail('unsafe_checkpoint_fields');
    const value = { schema: 1, scope: this.scope, request_id: id, revision, phase: record.phase, record, checksum: sha(JSON.stringify(record)) };
    const temporary = join(directory, `.checkpoint-${randomUUID()}`), target = join(directory, `${String(revision).padStart(6, '0')}.json`);
    const file = await open(temporary, 'wx', 0o600);
    try {
      await file.writeFile(JSON.stringify(value) + '\n'); await file.sync(); await file.close();
      try { await link(temporary, target); } catch (e) { if (e.code === 'EEXIST') fail('concurrent_operation_use_status'); throw e; }
      await unlink(temporary);
      const parent = await open(directory, 'r'); try { await parent.sync(); } finally { await parent.close(); }
    } finally { await file.close().catch(() => {}); await unlink(temporary).catch(() => {}); }
    return { ...record, request_id: id, revision };
  }
}
const publicStatus = record => ({ request_id: record.request_id, repository: record.repository, phase: record.phase,
  ...(record.run_id ? { run_id: record.run_id } : {}), ...(record.artifact_id ? { artifact_id: record.artifact_id } : {}),
  ...(record.build_state ? { build_state: record.build_state } : {}), ...(record.reason ? { reason: record.reason } : {}),
  ...(record.ipa ? { ipa: record.ipa } : {}), ...(record.export ? { export: record.export } : {}) });

export class CloudBuild {
  constructor({ checkpointDirectory, client = new GitHubActions(), authorizeWrite, exportWorkspace,
    artifactDirectory, progress = () => {} } = {}) {
    this.checkpointDirectory = checkpointDirectory; this.artifactDirectory = artifactDirectory;
    this.client = client; this.authorizeWrite = authorizeWrite; this.exportWorkspace = exportWorkspace; this.progress = progress;
  }
  store(exec) { return new CloudCheckpoint(this.checkpointDirectory, cloudScope(exec)); }
  async status(id, exec) {
    const value = await this.store(exec).read(id);
    if (!value) fail('request_not_found');
    return publicStatus(value);
  }
  async history(exec) {
    const records = await this.store(exec).list();
    return { records: records.slice(-20).map(publicStatus), truncated: records.length > 20,
      notice: 'Checkpoints retain exact run/artifact phases. They never restart or duplicate a cloud build.' };
  }
  async existing({ repository, run_id, artifact_name, request_id = randomUUID() }, exec) {
    repo(repository); artifactName(artifact_name); if (!integer(run_id)) fail('invalid_run_id');
    const store = this.store(exec), old = await store.read(request_id);
    if (old) {
      if (old.repository !== repository || old.run_id !== run_id || old.artifact_name !== artifact_name) fail('request_id_reused');
      return publicStatus(old);
    }
    const run = await this.client.run(repository, run_id, exec?.signal);
    return publicStatus(await store.write(null, { request_id, repository, run_id, artifact_name,
      run_attempt: run.run_attempt, head_sha: run.head_sha, phase: 'waiting', build_state: buildState(run) }));
  }
  async dispatch({ repository, workflow: workflowID, ref: branch, artifact_name, inputs = {}, request_id }, exec) {
    repo(repository); workflow(workflowID); ref(branch); artifactName(artifact_name);
    if (!UUID.test(request_id ?? '')) fail('explicit_request_id_required_before_remote_write');
    if (!inputs || typeof inputs !== 'object' || Array.isArray(inputs) || Object.keys(inputs).length > 25 ||
        Object.entries(inputs).some(([k, v]) => !/^[A-Za-z_][A-Za-z0-9_-]{0,99}$/.test(k) ||
          !['string','boolean','number'].includes(typeof v) || typeof v === 'number' && !Number.isFinite(v)) ||
        Buffer.byteLength(JSON.stringify(inputs)) > 16384) fail('invalid_workflow_inputs');
    const fingerprint = sha(JSON.stringify({ repository, workflow: String(workflowID), ref: branch, inputs, artifact_name }));
    const store = this.store(exec); let record = await store.read(request_id);
    if (record) {
      if (record.fingerprint !== fingerprint) fail('request_id_reused');
      // Includes dispatching/unknown, denial, and success: resumption never
      // triggers a second POST. A new request needs a fresh native confirmation.
      return publicStatus(record);
    }
    if (typeof this.authorizeWrite !== 'function') fail('native_write_confirmation_unavailable');
    await this.client.getCredential();
    const metadata = await this.client.json(`/repos/${repository}/actions/workflows/${encodeURIComponent(workflow(workflowID))}`, { signal: exec?.signal });
    if (metadata.state !== 'active' || !integer(metadata.id)) fail('workflow_not_active');
    record = await store.write(null, { request_id, repository, workflow: String(workflowID), ref: branch,
      artifact_name, fingerprint, phase: 'authorizing' });
    stopped(exec?.signal);
    const approval = await this.authorizeWrite({ operation: 'github.workflow_dispatch', request_id, fingerprint,
      repository, workflow: String(workflowID), ref: branch, input_names: Object.keys(inputs).sort() }, exec);
    if (approval?.approved !== true || approval.request_id !== request_id || approval.fingerprint !== fingerprint) {
      return publicStatus(await store.write(record, { phase: 'cancelled', reason: 'native_confirmation_declined' }));
    }
    stopped(exec?.signal);
    record = await store.write(record, { phase: 'dispatching' });
    try {
      const result = await this.client.request(`/repos/${repository}/actions/workflows/${encodeURIComponent(workflow(workflowID))}/dispatches`,
        { method: 'POST', body: { ref: branch, inputs, return_run_details: true }, signal: exec?.signal, statuses: [200, 204] });
      if (result.status !== 200) return publicStatus(await store.write(record, { phase: 'dispatch_unknown', reason: 'run_id_not_returned_do_not_repeat' }));
      let details;
      try { details = JSON.parse(result.body.toString()); } catch { fail('dispatch_response_unconfirmed'); }
      if (!integer(details.workflow_run_id)) fail('dispatch_response_unconfirmed');
      const run = await this.client.run(repository, details.workflow_run_id, exec?.signal);
      if (run.workflow_id !== metadata.id || run.event !== 'workflow_dispatch') fail('dispatch_run_identity_mismatch');
      return publicStatus(await store.write(record, { phase: 'waiting', run_id: run.id, run_attempt: run.run_attempt,
        head_sha: run.head_sha, build_state: buildState(run) }));
    } catch (error) {
      const definitive = error.cloudCode === 'github_http_error' && [401,403,404,410,422,429].includes(error.status);
      return publicStatus(await store.write(record, { phase: definitive ? 'failed' : 'dispatch_unknown',
        reason: definitive ? error.reason : 'dispatch_outcome_unknown_do_not_repeat' }));
    }
  }
  async attachRun({ request_id, run_id }, exec) {
    const store = this.store(exec), record = await store.read(request_id);
    if (!record || !['dispatch_unknown','dispatching'].includes(record.phase)) fail('request_does_not_need_run_recovery');
    const run = await this.client.run(record.repository, run_id, exec?.signal);
    const metadata = await this.client.json(`/repos/${record.repository}/actions/workflows/${encodeURIComponent(record.workflow)}`, { signal: exec?.signal });
    if (run.workflow_id !== metadata.id || run.event !== 'workflow_dispatch' || run.head_branch !== record.ref) fail('recovery_run_identity_mismatch');
    return publicStatus(await store.write(record, { phase: 'waiting', run_id, run_attempt: run.run_attempt,
      head_sha: run.head_sha, build_state: buildState(run), reason: 'user_selected_existing_run_no_dispatch_repeated' }));
  }
  async advance({ request_id, ipa_member }, exec) {
    const store = this.store(exec); let record = await store.read(request_id);
    if (!record) fail('request_not_found');
    if (['dispatching','dispatch_unknown','authorizing','created','saved','cancelled','failed'].includes(record.phase)) return publicStatus(record);
    stopped(exec?.signal);
    const run = await this.client.run(record.repository, record.run_id, exec?.signal);
    if (run.run_attempt !== record.run_attempt || run.head_sha !== record.head_sha) fail('run_attempt_changed_explicit_reselection_required');
    const state = buildState(run);
    if (state !== 'success') {
      record = await store.write(record, { phase: ['pending','running'].includes(state) ? 'waiting' : 'failed', build_state: state });
      return { ...publicStatus(record), ...(!['pending','running'].includes(state) ?
        { failed_jobs: await this.client.failures(record.repository, run, exec?.signal) } : {}) };
    }
    let artifact;
    if (!record.artifact_id) {
      artifact = await this.client.artifacts(record.repository, run, record.artifact_name, exec?.signal);
      record = await store.write(record, { phase: 'download_pending', build_state: 'success', artifact_id: artifact.id,
        artifact_size: artifact.size_in_bytes, artifact_sha256: artifact.digest.slice(7) });
    } else {
      artifact = await this.client.artifacts(record.repository, run, record.artifact_name, exec?.signal);
      if (artifact.id !== record.artifact_id || artifact.digest !== `sha256:${record.artifact_sha256}` ||
          artifact.size_in_bytes !== record.artifact_size) fail('artifact_changed_explicit_reselection_required');
    }
    const workspace = exec?.agent?.session?.header?.cwd;
    if (typeof workspace !== 'string' || resolve(workspace) !== workspace) fail('missing_workspace');
    if (!this.artifactDirectory) {
      await secureParents(workspace);
      try { await mkdir(join(workspace, 'dist'), { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
      await secureParents(join(workspace, 'dist'));
    }
    const directory = this.artifactDirectory ? await this.artifactDirectory(record, exec) : join(workspace, 'dist', `dsh-cloud-${request_id}`);
    await secureParents(dirname(directory));
    try { await mkdir(directory, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    await secureParents(directory);
    if (!record.ipa) {
      record = await store.write(record, { phase: 'downloading' });
      const archive = await this.client.download(record.repository, artifact, directory, { signal: exec?.signal, progress: this.progress });
      record = await store.write(record, { phase: 'downloaded', archive });
      const ipa = await extractVerifiedArtifact({ archive, directory, expectedSize: record.artifact_size,
        expectedSha256: record.artifact_sha256, ipaMember: ipa_member, signal: exec?.signal });
      record = await store.write(record, { phase: 'verified', ipa });
    } else {
      const checked = await hashVerifiedFile(record.ipa.path, MAX, exec?.signal);
      if (checked.bytes !== record.ipa.bytes || checked.sha256 !== record.ipa.sha256) fail('downloaded_ipa_changed');
    }
    if (typeof this.exportWorkspace !== 'function') return { ...publicStatus(record), reason: 'native_export_integration_unavailable' };
    record = await store.write(record, { phase: 'exporting' });
    const exported = await this.exportWorkspace({ path: record.ipa.path, name: record.ipa.name }, exec);
    // Native callback owns the real save lifecycle. Transfer success and dialog
    // presentation are deliberately insufficient to claim Files saved the IPA.
    const nativeSaved = exported?.state === 'saved' && exported?.saved === true;
    const saved = nativeSaved && exported.bytes === record.ipa.bytes && exported.sha256 === record.ipa.sha256;
    const summary = { state: String(exported?.state ?? 'unknown').slice(0, 50), saved,
      ...(nativeSaved && !saved ? { reason: 'native_saved_metadata_mismatch' } :
        typeof exported?.reason === 'string' ? { reason: exported.reason.slice(0, 100) } : {}) };
    record = await store.write(record, { phase: saved ? 'saved' : 'verified', export: summary });
    return publicStatus(record);
  }
}
