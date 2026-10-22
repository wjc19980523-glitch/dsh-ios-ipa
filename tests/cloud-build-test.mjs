import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { CloudBuild, CloudCheckpoint, GitHubActions, httpsTransport, credentialResolver, githubFailure, buildState,
  githubProxy, cloudScope, discoverCloudRepository, cloudError } from '../experimental/cloud-build/cloud-build.mjs';
import { zip, fixtureIpa } from './cloud-build-fixture.mjs';
const key = await readFile('tests/fixtures/web-transport/test-key.pem'), cert = await readFile('tests/fixtures/web-transport/test-cert.pem');
const TOKEN = 'synthetic-test-token-no-real-authority';
const HASH = 'a'.repeat(40), REPO = 'owner/project', RUN = 91, ARTIFACT = 123;
const sha = b => createHash('sha256').update(b).digest('hex');
async function fixture(t) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'dsh-cloud-'))), workspace = join(home, 'workspace'), checkpoints = join(home, 'checkpoints');
  await mkdir(workspace); await mkdir(checkpoints);
  const f = { home, workspace, checkpoints, requests: [], posts: 0, approvals: 0, exports: 0,
    archive: zip([{ name: 'build/result.ipa', data: fixtureIpa(), method: 8 }, { name: 'build/README.txt', data: 'fixture' }]),
    exec: { agent: { id: 'session-cloud-test', session: { header: { cwd: workspace } } } },
    run: { id: RUN, run_attempt: 1, head_sha: HASH, workflow_id: 7, head_branch: 'main', repository: { full_name: REPO }, event: 'workflow_dispatch', status: 'completed', conclusion: 'success' } };
  const sockets = new Set();
  const server = https.createServer({ key, cert }, (req, res) => {
    const observed = { path: req.url, method: req.method, auth: req.headers.authorization }; f.requests.push(observed);
    const json = (value, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (f.status && req.url.startsWith('/repos/')) return json({ message: `suppressed ${TOKEN}` }, f.status);
    if (req.method === 'POST') {
      let body = ''; req.on('data', chunk => { body += chunk; }); req.on('end', () => {
        f.posts++; observed.body = JSON.parse(body);
        if (f.postStatus) return json({ message: `suppressed ${TOKEN}` }, f.postStatus);
        if (f.dispatchMode === 'drop') { req.socket.destroy(); return; }
        if (f.dispatchMode === '204') { res.writeHead(204); res.end(); return; }
        json({ workflow_run_id: RUN });
      }); return;
    }
    if (req.url === `/repos/${REPO}/actions/runs/${RUN}`) return json(f.run);
    if (req.url.startsWith(`/repos/${REPO}/actions/runs/${RUN}/artifacts?`)) return json({ total_count: f.artifacts?.length ?? 1,
      artifacts: f.artifacts ?? [{ id: ARTIFACT, name: 'result-ipa', size_in_bytes: f.archive.length, digest: 'sha256:' + sha(f.archive),
        expired: f.expired ?? false, expires_at: '2099-01-01T00:00:00Z', workflow_run: { id: RUN, head_sha: HASH } }] });
    if (req.url === `/repos/${REPO}/actions/artifacts/${ARTIFACT}/zip`) {
      res.writeHead(302, { location: f.redirect ?? 'https://fixture.blob.core.windows.net/archive?signed-secret=suppressed' }); res.end(); return;
    }
    if (req.url.startsWith('/archive')) {
      res.writeHead(200, { 'content-length': f.archive.length });
      if (f.downloadMode === 'drop') { res.write(f.archive.subarray(0, 32)); setImmediate(() => res.destroy()); return; }
      if (f.downloadMode === 'stall') { res.write(f.archive.subarray(0, 16)); return; }
      res.end(f.downloadMode === 'corrupt' ? Buffer.alloc(f.archive.length) : f.archive); return;
    }
    if (req.url === `/repos/${REPO}/actions/workflows/build.yml`) return json({ id: 7, state: f.workflowState ?? 'active' });
    if (req.url === `/repos/${REPO}/actions/workflows?per_page=100`) return json({ total_count: 1, workflows: [{ id: 7, path: '.github/workflows/build.yml', name: 'Build', state: 'active' }] });
    if (req.url.includes('/attempts/1/jobs')) return json({ total_count: 1, jobs: [{ id: 33, name: 'Archive', conclusion: 'failure', steps: [{ number: 4, name: 'Xcode archive', conclusion: 'failure' }] }] });
    if (req.url.endsWith('/actions/jobs/33/logs')) { res.writeHead(302, { location: 'https://fixture.blob.core.windows.net/job-log' }); res.end(); return; }
    if (req.url === '/job-log') { res.end(`ordinary output\n##[error]clang: error: unsupported SDK\nerror: Authorization: Bearer ${TOKEN}\nerror: authorization: Bearer other-opaque-secret-fixture\n`); return; }
    json({ message: 'not found' }, 404);
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const origin = `https://127.0.0.1:${server.address().port}`;
  const transport = (url, options) => httpsTransport(new URL(url.pathname + url.search, origin), { ...options, proxy: undefined });
  f.client = new GitHubActions({ getCredential: async () => TOKEN, transport, environment: {} });
  f.options = { checkpointDirectory: checkpoints, client: f.client,
    authorizeWrite: async args => { f.approvals++; return { approved: true, request_id: args.request_id, fingerprint: args.fingerprint }; },
    exportWorkspace: async args => { f.exports++; const bytes = await readFile(args.path);
      return f.exportResult ?? { state: 'saved', saved: true, bytes: bytes.length, sha256: sha(bytes) }; } };
  f.cloud = new CloudBuild(f.options);
  f.existing = more => f.cloud.existing({ repository: REPO, run_id: RUN, artifact_name: 'result-ipa', ...more }, f.exec);
  f.dispatch = more => f.cloud.dispatch({ repository: REPO, workflow: 'build.yml', ref: 'main', artifact_name: 'result-ipa', request_id: f.requestID, ...more }, f.exec);
  f.requestID = randomUUID();
  t.after(async () => {
    for (const socket of sockets) socket.destroy(); await new Promise(done => server.close(done));
    await rm(home, { recursive: true, force: true });
  });
  return f;
}
test('existing successful run downloads verified artifact over real HTTPS and reports save only after native result', async t => {
  const f = await fixture(t), start = await f.existing();
  const result = await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(result.phase, 'saved'); assert.equal(result.export.saved, true); assert.equal(f.exports, 1); assert.equal(f.posts, 0);
  assert.equal(result.ipa.sha256, sha(fixtureIpa()));
  const archive = f.requests.find(r => r.path.startsWith('/archive'));
  assert.equal(archive.auth, undefined);
  for (const call of f.requests.filter(r => r.path.startsWith('/repos/'))) assert.equal(call.auth, `Bearer ${TOKEN}`);
  const before = f.requests.length; await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(f.requests.length, before); assert.equal(f.exports, 1);
});
test('missing auth fails clearly without any request or shell/gh fallback', async t => {
  const f = await fixture(t); f.client.getCredential = credentialResolver(undefined, {});
  await assert.rejects(f.existing(), /github_authentication_required/); assert.equal(f.requests.length, 0);
});
test('read-only discovery identifies origin/branch/workflows without exposing credential-bearing remote', async t => {
  const f = await fixture(t), probes = [];
  const probe = async (_name, args) => { probes.push(args); return { stdout: args[0] === 'config' ? `https://github.com/${REPO}.git\n` : args[0] === 'rev-parse' ? HASH : 'main' }; };
  const result = await discoverCloudRepository(f.exec, { client: f.client, probe });
  assert.equal(result.repository, REPO); assert.equal(result.branch, 'main'); assert.equal(result.workflows[0].id, 7);
  assert.equal(probes.length, 3); assert.equal(f.posts, 0);
  await assert.rejects(discoverCloudRepository(f.exec, { client: f.client, probe: async (_name, args) =>
    ({ stdout: args[0] === 'config' ? `https://user:${TOKEN}@github.com/${REPO}.git` : args[0] === 'rev-parse' ? HASH : 'main' }) }), /without_embedded_credentials/);
});
test('credential service reuses environment/file seam without returning value to caller', async () => {
  const names = [], resolver = credentialResolver({ resolve: async name => { names.push(name); return name === 'GITHUB_TOKEN' ? { value: TOKEN } : undefined; } }, { GH_TOKEN: 'ignored' });
  assert.equal(await resolver(), TOKEN); assert.deepEqual(names, ['GH_TOKEN','GITHUB_TOKEN']);
});
for (const [status, reason] of [[401,'github_authentication_required'],[403,'github_forbidden_or_rate_limited'],
  [404,'github_not_found_or_no_access'],[429,'github_rate_limited']]) test(`HTTP ${status} is a real failure and never exposes error body/token`, async t => {
  const f = await fixture(t); f.status = status;
  await assert.rejects(f.existing(), error => { assert.equal(error.status, status); assert.equal(error.reason, reason); assert(!String(error).includes(TOKEN)); return true; });
  assert.equal(f.posts, 0);
});
test('rate limit headers yield bounded retry metadata, never busy polling', () => {
  assert.deepEqual(githubFailure(429, { 'retry-after': '60', 'x-ratelimit-reset': '1890000000' }),
    { status: 429, reason: 'github_rate_limited', retry_after_seconds: 60, rate_limit_reset: 1890000000 });
});
test('build states derive from real conclusion; HTTP 200 is not success', async t => {
  const f = await fixture(t); f.run.status = 'in_progress'; f.run.conclusion = null;
  const start = await f.existing(), result = await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(result.build_state, 'running'); assert.equal(result.phase, 'waiting'); assert.equal(f.exports, 0);
  assert.equal(buildState({ status: 'queued' }), 'pending');
  assert.equal(buildState({ status: 'completed', conclusion: 'cancelled' }), 'cancelled');
  assert.equal(buildState({ status: 'completed', conclusion: 'timed_out' }), 'timed_out');
  assert.throws(() => buildState({ status: 'completed', conclusion: null }));
});
test('failed Actions returns failed job/step and masked original error lines without artifact download', async t => {
  const f = await fixture(t); f.run.conclusion = 'failure';
  const start = await f.existing(), result = await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(result.build_state, 'failed'); assert.equal(result.phase, 'failed'); assert.equal(result.failed_jobs[0].job_id, 33);
  assert(result.failed_jobs[0].error_excerpt.some(line => line.includes('unsupported SDK'))); assert(!JSON.stringify(result).includes(TOKEN));
  assert(!JSON.stringify(result).includes('other-opaque-secret-fixture'));
  assert(!f.requests.some(r => r.path.startsWith('/archive'))); assert.equal(f.exports, 0);
});
test('expired artifact fails before network transfer or native export', async t => {
  const f = await fixture(t); f.expired = true; const start = await f.existing();
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /artifact_expired/); assert.equal(f.exports, 0);
});
test('attempt drift fails closed rather than accepting a rerun artifact', async t => {
  const f = await fixture(t), start = await f.existing(); f.run.run_attempt = 2;
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /run_attempt_changed/);
});
test('duplicate artifact name or missing official digest is refused', async t => {
  const f = await fixture(t), start = await f.existing();
  f.artifacts = [{ name: 'result-ipa' }, { name: 'result-ipa' }];
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /ambiguous_artifact_name/);
  f.artifacts = [{ id: ARTIFACT, name: 'result-ipa', size_in_bytes: f.archive.length, expired: false,
    expires_at: '2099-01-01T00:00:00Z', workflow_run: { id: RUN, head_sha: HASH } }];
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /artifact_identity_or_digest_unverified/);
});
test('foreign or insecure artifact redirect never receives GitHub credential', async t => {
  const f = await fixture(t), start = await f.existing(); f.redirect = 'https://attacker.invalid/download';
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /untrusted_artifact_redirect/);
  assert(!f.requests.some(r => r.path.startsWith('/archive')));
});
test('truncated network transfer resumes same run and artifact, never dispatches a build', async t => {
  const f = await fixture(t), start = await f.existing(); f.downloadMode = 'drop';
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec));
  assert.equal((await f.cloud.status(start.request_id, f.exec)).phase, 'downloading');
  f.downloadMode = undefined;
  const resumed = new CloudBuild(f.options), result = await resumed.advance({ request_id: start.request_id }, f.exec);
  assert.equal(result.phase, 'saved'); assert.equal(f.posts, 0);
});
test('checksum failure keeps no incomplete published IPA and supports explicit safe download retry', async t => {
  const f = await fixture(t), start = await f.existing(); f.downloadMode = 'corrupt';
  await assert.rejects(f.cloud.advance({ request_id: start.request_id }, f.exec), /artifact_digest_mismatch/);
  const directory = join(f.workspace, 'dist', `dsh-cloud-${start.request_id}`); assert.deepEqual(await readdir(directory), []);
  f.downloadMode = undefined; assert.equal((await f.cloud.advance({ request_id: start.request_id }, f.exec)).phase, 'saved');
});
test('native cancellation is not saved, preserves verified IPA and resumes export without another download', async t => {
  const f = await fixture(t), start = await f.existing(); f.exportResult = { state: 'cancelled', saved: false };
  const cancelled = await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(cancelled.phase, 'verified'); assert.equal(cancelled.export.saved, false); assert((await readFile(cancelled.ipa.path)).length > 0);
  const downloads = f.requests.filter(r => r.path.startsWith('/archive')).length; f.exportResult = undefined;
  assert.equal((await new CloudBuild(f.options).advance({ request_id: start.request_id }, f.exec)).phase, 'saved');
  assert.equal(f.requests.filter(r => r.path.startsWith('/archive')).length, downloads);
});
test('native saved flag without matching size/SHA never claims a successful IPA save', async t => {
  const f = await fixture(t), start = await f.existing(); f.exportResult = { state: 'saved', saved: true, bytes: 1, sha256: '0'.repeat(64) };
  const result = await f.cloud.advance({ request_id: start.request_id }, f.exec);
  assert.equal(result.phase, 'verified'); assert.equal(result.export.saved, false); assert.equal(result.export.reason, 'native_saved_metadata_mismatch');
});
test('verified IPA modified between interruption and resume is refused and retained for inspection', async t => {
  const f = await fixture(t), start = await f.existing(); f.exportResult = { state: 'interrupted', saved: false };
  const first = await f.cloud.advance({ request_id: start.request_id }, f.exec); await writeFile(first.ipa.path, 'changed');
  await assert.rejects(new CloudBuild(f.options).advance({ request_id: start.request_id }, f.exec), /downloaded_ipa_changed/);
  assert.equal(await readFile(first.ipa.path, 'utf8'), 'changed'); assert.equal(f.exports, 1);
});
test('dispatch refuses missing native authorization and declined user confirmation', async t => {
  const f = await fixture(t); f.cloud = new CloudBuild({ ...f.options, authorizeWrite: undefined });
  await assert.rejects(f.dispatch(), /native_write_confirmation_unavailable/); assert.equal(f.posts, 0);
  f.cloud = new CloudBuild({ ...f.options, authorizeWrite: async args => ({ approved: false, request_id: args.request_id, fingerprint: args.fingerprint }) });
  const result = await f.dispatch(); assert.equal(result.phase, 'cancelled'); assert.equal(f.posts, 0);
});
test('one approved dispatch records official returned run ID and repeated request ID never posts twice', async t => {
  const f = await fixture(t); const first = await f.dispatch({ inputs: { configuration: 'Release' } });
  assert.equal(first.run_id, RUN); assert.equal(first.phase, 'waiting'); assert.equal(f.posts, 1); assert.equal(f.approvals, 1);
  const posted = f.requests.find(r => r.method === 'POST'); assert.equal(posted.body.return_run_details, true);
  await f.dispatch({ inputs: { configuration: 'Release' } }); assert.equal(f.posts, 1); assert.equal(f.approvals, 1);
  await assert.rejects(f.dispatch({ inputs: { configuration: 'Debug' } }), /request_id_reused/);
});
test('GitHub 422 reports unsupported dispatch or input mismatch and does not retry the POST', async t => {
  const f = await fixture(t); f.postStatus = 422;
  const first = await f.dispatch(); assert.equal(first.phase, 'failed'); assert.equal(first.reason, 'workflow_dispatch_unavailable_or_invalid_inputs');
  await f.dispatch(); assert.equal(f.posts, 1);
});
for (const mode of ['drop','204']) test(`dispatch ${mode} checkpoints unknown and interruption never authorizes a duplicate`, async t => {
  const f = await fixture(t); f.dispatchMode = mode;
  const first = await f.dispatch(); assert.equal(first.phase, 'dispatch_unknown'); assert.equal(f.posts, 1);
  await new CloudBuild(f.options).dispatch({ repository: REPO, workflow: 'build.yml', ref: 'main', artifact_name: 'result-ipa', request_id: f.requestID }, f.exec);
  assert.equal(f.posts, 1);
  const recovered = await f.cloud.attachRun({ request_id: f.requestID, run_id: RUN }, f.exec);
  assert.equal(recovered.phase, 'waiting'); assert.equal(f.posts, 1);
});
test('concurrent same request dispatches at most once using atomic checkpoint publication', async t => {
  const f = await fixture(t), results = await Promise.allSettled([f.dispatch(), f.dispatch()]);
  assert(results.some(r => r.status === 'fulfilled')); assert.equal(f.posts, 1); assert.equal(f.approvals, 1);
});
test('checkpoint belongs to owner and contains no credentials, workflow input values or signed redirect', async t => {
  const f = await fixture(t); await f.dispatch({ inputs: { value: 'sensitive-input-fixture' } });
  const store = new CloudCheckpoint(f.checkpoints, cloudScope(f.exec));
  const directory = await store.setup(f.requestID), data = (await Promise.all((await readdir(directory)).map(n => readFile(join(directory, n), 'utf8')))).join();
  assert(!data.includes(TOKEN)); assert(!data.includes('sensitive-input-fixture')); assert(!data.includes('signed-secret'));
  await assert.rejects(f.cloud.status(f.requestID, { agent: { id: 'other-owner' } }), /request_not_found/);
  const history = await new CloudBuild(f.options).history(f.exec); assert.equal(history.records.length, 1); assert.equal(history.records[0].run_id, RUN);
});
test('safe error envelope never serializes raw paths, URL or credential-bearing error body', () => {
  const result = cloudError(Object.assign(new Error(`https://example.invalid/?token=${TOKEN}`), { code: 'ECONNRESET' }));
  assert.deepEqual(result, { state: 'failed', reason: 'cloud_operation_failed' }); assert(!JSON.stringify(result).includes(TOKEN));
});
test('real HTTPS timeout and abort settle promptly and close body sockets', async t => {
  const f = await fixture(t); f.downloadMode = 'stall';
  // Use the same trusted wire adapter to reach fixture; direct API request timeout
  // is tested by an independent server whose response never finishes.
  const sockets = new Set(), server = https.createServer({ key, cert }, (_req, res) => { res.writeHead(200); res.write('x'); });
  server.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  t.after(async () => { for (const s of sockets) s.destroy(); await new Promise(done => server.close(done)); });
  const target = new URL(`https://127.0.0.1:${server.address().port}/stall`);
  await assert.rejects(httpsTransport(target, { timeoutMs: 50 }), /request_timed_out/);
  const controller = new AbortController(), request = httpsTransport(target, { signal: controller.signal });
  setTimeout(() => controller.abort(), 25); await assert.rejects(request, /interrupted/);
});
test('proxy environment uses explicit HTTP CONNECT policy and rejects unsupported SOCKS', () => {
  assert.equal(githubProxy(new URL('https://api.github.com'), { HTTPS_PROXY: 'http://proxy.invalid:8080', NO_PROXY: '.github.com' }), undefined);
  assert.equal(githubProxy(new URL('https://api.github.com'), { HTTPS_PROXY: 'http://proxy.invalid:8080' }), 'http://proxy.invalid:8080');
  assert.throws(() => githubProxy(new URL('https://api.github.com'), { ALL_PROXY: 'socks5://proxy.invalid:1080' }), /unsupported_github_proxy/);
});
test('real HTTP CONNECT sends proxy auth only to proxy and keeps origin authorization on TLS origin', async t => {
  const f = await fixture(t), observed = []; const sockets = new Set();
  const origin = https.createServer({ key, cert }, (req, res) => { observed.push({ place: 'origin', authorization: req.headers.authorization,
    proxy: req.headers['proxy-authorization'] }); res.end('ok'); });
  await new Promise(done => origin.listen(0, '127.0.0.1', done));
  const proxy = http.createServer();
  proxy.on('connect', (req, client, head) => {
    observed.push({ place: 'proxy', authorization: req.headers.authorization, proxy: req.headers['proxy-authorization'] });
    const upstream = net.connect(origin.address().port, '127.0.0.1', () => { client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head); client.pipe(upstream); upstream.pipe(client); });
    for (const socket of [client, upstream]) { sockets.add(socket); socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket)); }
  });
  await new Promise(done => proxy.listen(0, '127.0.0.1', done));
  t.after(async () => { for (const socket of sockets) socket.destroy(); await new Promise(done => proxy.close(done)); await new Promise(done => origin.close(done)); });
  const result = await httpsTransport(new URL('https://web-transport.test/controlled'), { headers: { authorization: `Bearer ${TOKEN}` },
    proxy: `http://proxy-user:proxy-password@127.0.0.1:${proxy.address().port}` });
  assert.equal(result.status, 200); assert.equal(result.body.toString(), 'ok');
  assert.equal(observed[0].place, 'proxy'); assert.equal(observed[0].authorization, undefined);
  assert.equal(observed[0].proxy, 'Basic ' + Buffer.from('proxy-user:proxy-password').toString('base64'));
  assert.equal(observed[1].authorization, `Bearer ${TOKEN}`); assert.equal(observed[1].proxy, undefined);
});
