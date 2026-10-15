import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { realpath, mkdtemp, mkdir, readFile, writeFile, rm, readdir, symlink, link } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { developmentPreflight, downloadDependency } from '../app/JobTracking.bundle/development-tools.mjs';

const body = Buffer.from('controlled dependency fixture\n');
const sha256 = createHash('sha256').update(body).digest('hex');
const certPath = resolve('tests/fixtures/web-transport/test-cert.pem');
const key = await readFile('tests/fixtures/web-transport/test-key.pem'), cert = await readFile(certPath);
const trusted = { ...process.env, CURL_CA_BUNDLE: certPath, NO_PROXY: '127.0.0.1' };
async function fixture(t) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'dsh-development-')));
  const curlHome = join(home, 'curl-home'), xdg = join(home, 'xdg');
  await mkdir(curlHome); await mkdir(xdg);
  const environment = { ...trusted, HOME: curlHome, CURL_HOME: curlHome, XDG_CONFIG_HOME: xdg, no_proxy: '127.0.0.1' };
  let requests = 0, pending;
  const observations = [];
  const sockets = new Set();
  const server = https.createServer({ key, cert }, (req, res) => {
    requests++;
    const observation = { method: req.method, path: req.url, received_bytes: 0 };
    observations.push(observation);
    req.on('data', bytes => { observation.received_bytes += bytes.length; }); req.resume();
    if (req.url === '/404') { res.writeHead(404); res.end('fixture-not-found'); }
    else if (req.url === '/stall') { res.writeHead(200, { 'Content-Length': 100 }); res.write('x'); }
    else if (req.url === '/hold') { pending = res; }
    else { res.writeHead(200, { 'Content-Length': body.length }); res.end(body); }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const url = path => `https://127.0.0.1:${server.address().port}${path}`;
  const destination = join(home, 'dependency.bin');
  const args = path => ({ url: url(path), destination, sha256, connectSeconds: 1, stallSeconds: 1, totalSeconds: 5 });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(done => server.close(done));
    const names = await readdir(home);
    assert(!names.some(name => name.includes('.dsh-part-') || name.endsWith('.dsh-download-lock')), 'owned transfers and locks must be cleaned up');
    await rm(home, { recursive: true, force: true });
  });
  const waitRequest = async () => {
    const deadline = Date.now() + 5000;
    while (requests === 0 && Date.now() < deadline) await new Promise(done => setTimeout(done, 5));
    assert(requests > 0, 'controlled HTTPS request must reach the server within its bound');
  };
  return { home, destination, url, args, environment, curlHome, observations,
    download: args => downloadDependency(args, { environment }), requests: () => requests, waitRequest,
    release: () => { assert(pending); pending.end(body); } };
}

test('native iOS preflight on Linux starts no compiler, installer, download or remote build', async () => {
  let probes = 0;
  const result = await developmentPreflight('native-ios', { platform: 'linux', arch: 'arm64', probe: () => { probes++; throw new Error('must not run'); } });
  assert.equal(result.state, 'requires_mac'); assert.equal(result.can_build_here, false); assert.equal(probes, 0);
});
test('Mac preflight requires both real Xcode and iPhoneOS SDK responses; does not claim project compiled', async () => {
  const calls = [];
  const result = await developmentPreflight('native-ios', { platform: 'darwin', probe: async (name, args) => {
    calls.push([name, args]); return { stdout: name === 'xcodebuild' ? 'Xcode 26.6\nBuild version fixture' : '/fixture/iPhoneOS.sdk\n' };
  } });
  assert.equal(result.state, 'environment_ready'); assert.equal(result.project_build_verified, false);
  assert.deepEqual(calls, [['xcodebuild', ['-version']], ['xcrun', ['--sdk', 'iphoneos', '--show-sdk-path']]]);
});
test('missing or failed Mac SDK stays unverified', async () => {
  const result = await developmentPreflight('native-ios', { platform: 'darwin', probe: async () => { throw new Error('controlled failure'); } });
  assert.equal(result.can_build_here, false); assert.equal(result.state, 'xcode_or_ios_sdk_unverified');
});
test('verified HTTPS dependency is published once and a repeat uses checksum cache with zero new requests', async t => {
  const f = await fixture(t);
  assert.equal((await f.download(f.args('/ok'))).state, 'completed'); assert.equal(f.requests(), 1);
  const cached = await f.download(f.args('/ok')); assert.equal(cached.state, 'cached'); assert.equal(cached.transfers_started, 0);
  assert.equal(f.requests(), 1); assert.deepEqual(await readFile(f.destination), body);
});
test('HTTP 404 is a real failure and never becomes a dependency file', async t => {
  const f = await fixture(t), result = await f.download(f.args('/404'));
  assert.equal(result.state, 'failed'); assert.equal(result.http_status, 404); assert.equal(result.curl_exit_code, 22);
  await assert.rejects(readFile(f.destination), { code: 'ENOENT' }); assert.equal(f.requests(), 1);
});
test('a genuinely stalled local transfer exits on its declared stall bound, without publishing or retrying', async t => {
  const f = await fixture(t), before = Date.now(), result = await f.download(f.args('/stall'));
  assert.equal(result.state, 'failed'); assert.equal(result.reason, 'transfer_timeout_or_stall'); assert.equal(result.curl_exit_code, 28);
  assert(Date.now() - before < 12000); assert.equal(f.requests(), 1); assert.equal(result.retries_started, 0);
  await assert.rejects(readFile(f.destination), { code: 'ENOENT' });
});
test('checksum mismatch never publishes an untrusted artifact', async t => {
  const f = await fixture(t), result = await f.download({ ...f.args('/ok'), sha256: '0'.repeat(64) });
  assert.equal(result.reason, 'checksum_mismatch'); await assert.rejects(readFile(f.destination), { code: 'ENOENT' });
});
test('an existing different file is preserved and starts no network request', async t => {
  const f = await fixture(t); await writeFile(f.destination, 'USER_WORK_SENTINEL');
  const result = await f.download(f.args('/ok')); assert.equal(result.state, 'refused'); assert.equal(f.requests(), 0);
  assert.equal(await readFile(f.destination, 'utf8'), 'USER_WORK_SENTINEL');
});
test('concurrent transfer to the same destination is blocked without cancelling the first', async t => {
  const f = await fixture(t), first = f.download(f.args('/hold'));
  await f.waitRequest();
  const second = await f.download(f.args('/ok')); assert.equal(second.state, 'blocked'); assert.equal(f.requests(), 1);
  f.release(); assert.equal((await first).state, 'completed'); assert.deepEqual(await readFile(f.destination), body);
});
test('a user file created during transfer is never overwritten at publication', async t => {
  const f = await fixture(t), first = f.download(f.args('/hold'));
  await f.waitRequest();
  await writeFile(f.destination, 'NEW_USER_WORK'); f.release();
  const result = await first; assert.equal(result.state, 'failed'); assert.equal(result.reason, 'local_publish_failed');
  assert.equal(await readFile(f.destination, 'utf8'), 'NEW_USER_WORK');
});
test('symlink and hardlink destinations are refused without reading as cached or changing targets', async t => {
  const f = await fixture(t), sentinel = join(f.home, 'sentinel'); await writeFile(sentinel, body);
  await symlink(sentinel, f.destination); assert.equal((await f.download(f.args('/ok'))).state, 'failed'); await rm(f.destination);
  await link(sentinel, f.destination); assert.equal((await f.download(f.args('/ok'))).state, 'failed');
  assert.deepEqual(await readFile(sentinel), body); assert.equal(f.requests(), 0);
});
test('HTTPS certificates remain mandatory; untrusted fixture CA fails instead of disabling verification', async t => {
  const f = await fixture(t), environment = { ...f.environment };
  delete environment.CURL_CA_BUNDLE; delete environment.SSL_CERT_FILE;
  const result = await downloadDependency(f.args('/ok'), { environment });
  assert.equal(result.state, 'failed'); assert.equal(result.curl_exit_code, 60); assert.equal(f.requests(), 0);
});
test('HTTP, embedded credentials and missing checksum are refused before transfer', async t => {
  const f = await fixture(t);
  for (const args of [{ ...f.args('/ok'), url: f.url('/ok').replace('https:', 'http:') },
    { ...f.args('/ok'), url: f.url('/ok').replace('https://', 'https://user:SECRET@') }, { ...f.args('/ok'), sha256: '' }]) {
    const result = await f.download(args); assert.equal(result.state, 'refused'); assert(!JSON.stringify(result).includes('SECRET'));
  }
  assert.equal(f.requests(), 0);
});
test('missing curl yields a definite failure, no publication and no residual transfer', async t => {
  const f = await fixture(t), result = await downloadDependency(f.args('/ok'), { environment: { ...f.environment, PATH: '' } });
  assert.equal(result.state, 'failed'); assert.equal(result.reason, 'curl_unavailable'); assert.equal(f.requests(), 0);
});
test('explicit cancellation stops only the owned transfer and leaves no publication or transfer lock', async t => {
  const f = await fixture(t), controller = new AbortController();
  const result = downloadDependency(f.args('/stall'), { environment: f.environment, signal: controller.signal });
  await f.waitRequest(); controller.abort();
  assert.equal((await result).state, 'interrupted');
  await assert.rejects(readFile(f.destination), { code: 'ENOENT' });
});
test('CLI SIGTERM is propagated to its curl child and returns a genuine nonzero status after cleanup', async t => {
  const f = await fixture(t);
  const child = spawn(process.execPath, ['app/JobTracking.bundle/development-tools.mjs', 'download', f.url('/stall'), f.destination, sha256],
    { env: f.environment, stdio: ['ignore','pipe','pipe'] });
  let output = ''; child.stdout.on('data', bytes => { output += bytes; }); child.stderr.resume();
  const finished = new Promise(done => child.once('close', (code, signal) => done({ code, signal })));
  try {
    await f.waitRequest(); child.kill('SIGTERM');
    const status = await finished; assert.equal(status.code, 1); assert.equal(status.signal, null);
    assert.equal(JSON.parse(output.trim().split('\n').at(-1)).state, 'interrupted');
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await finished;
  }
});
test('oversized response fails under its declared bound', async t => {
  const f = await fixture(t), result = await f.download({ ...f.args('/ok'), maxBytes: 2 });
  assert.equal(result.state, 'failed'); await assert.rejects(readFile(f.destination), { code: 'ENOENT' });
});
test('CLI returns a genuine nonzero exit for unsupported native build and invalid download', async () => {
  for (const args of [['preflight', 'native-ios'], ['download', 'https://fixture.invalid', '/tmp/unused', 'invalid']]) {
    const child = spawn(process.execPath, ['app/JobTracking.bundle/development-tools.mjs', ...args], { stdio: ['ignore','pipe','pipe'] });
    let output = ''; child.stdout.on('data', bytes => { output += bytes; }); child.stderr.resume();
    const code = await new Promise(done => child.once('close', done));
    if (process.platform !== 'darwin' || args[0] === 'download') assert.equal(code, 1);
    assert.equal(typeof JSON.parse(output).state, 'string');
  }
});

test('synthetic default curlrc cannot disable certificate validation', async t => {
  const f = await fixture(t); await writeFile(join(f.curlHome, '.curlrc'), 'insecure\n');
  const environment = { ...f.environment };
  delete environment.CURL_CA_BUNDLE; delete environment.SSL_CERT_FILE; delete environment.SSL_CERT_DIR;
  const result = await downloadDependency(f.args('/ok'), { environment });
  assert.equal(result.state, 'failed'); assert.equal(result.curl_exit_code, 60); assert.equal(f.requests(), 0);
});
test('synthetic default curlrc cannot turn the download into an empty POST', async t => {
  const f = await fixture(t); await writeFile(join(f.curlHome, '.curlrc'), 'data = ""\n');
  assert.equal((await f.download(f.args('/ok'))).state, 'completed');
  assert.deepEqual(f.observations, [{ method: 'GET', path: '/ok', received_bytes: 0 }]);
});
test('synthetic default curlrc cannot turn the download into an empty file upload', async t => {
  const f = await fixture(t), empty = join(f.home, 'empty-upload-fixture'); await writeFile(empty, '');
  await writeFile(join(f.curlHome, '.curlrc'), `upload-file = "${empty}"\n`);
  assert.equal((await f.download(f.args('/ok'))).state, 'completed');
  assert.deepEqual(f.observations, [{ method: 'GET', path: '/ok', received_bytes: 0 }]);
});
test('synthetic default curlrc cannot add a second URL; trusted cache still starts no request', async t => {
  const f = await fixture(t); await writeFile(join(f.curlHome, '.curlrc'), `url = "${f.url('/extra')}"\n`);
  assert.equal((await f.download(f.args('/ok'))).state, 'completed');
  assert.deepEqual(f.observations, [{ method: 'GET', path: '/ok', received_bytes: 0 }]);
  assert.equal((await f.download(f.args('/ok'))).state, 'cached'); assert.equal(f.requests(), 1);
});
test('literal braces in one URL do not expand into multiple requests', async t => {
  const f = await fixture(t);
  assert.equal((await f.download(f.args('/glob{a,b}'))).state, 'completed');
  assert.deepEqual(f.observations, [{ method: 'GET', path: '/glob{a,b}', received_bytes: 0 }]);
});
test('literal brackets in one URL do not expand into multiple requests', async t => {
  const f = await fixture(t);
  assert.equal((await f.download(f.args('/range[1-2]'))).state, 'completed');
  assert.deepEqual(f.observations, [{ method: 'GET', path: '/range[1-2]', received_bytes: 0 }]);
});
test('the actual delegated curl process receives disable first and globoff second', async t => {
  const f = await fixture(t), bin = join(f.home, 'bin'), argv = join(f.home, 'actual-argv'); await mkdir(bin);
  await writeFile(join(bin, 'curl'), '#!/bin/sh\nprintf \'%s\\n\' "$@" > "$DSH_TEST_CURL_ARGV"\nexec /usr/bin/curl "$@"\n', { mode: 0o700 });
  f.environment.PATH = `${bin}:${process.env.PATH}`; f.environment.DSH_TEST_CURL_ARGV = argv;
  assert.equal((await f.download(f.args('/ok'))).state, 'completed');
  const actual = (await readFile(argv, 'utf8')).trim().split('\n');
  assert.deepEqual(actual.slice(0,2), ['--disable', '--globoff']); assert(!actual.includes('--insecure'));
  assert.equal(f.requests(), 1);
});
test('disabling default curlrc still honors an explicitly inherited HTTPS proxy environment', async t => {
  const f = await fixture(t); let connects = 0;
  const proxy = http.createServer();
  proxy.on('connect', (request, socket) => { connects++; assert(request.url.startsWith('127.0.0.1:'));
    socket.end('HTTP/1.1 502 Controlled fixture\r\nContent-Length: 0\r\n\r\n'); });
  await new Promise(done => proxy.listen(0, '127.0.0.1', done));
  t.after(() => new Promise(done => proxy.close(done)));
  const proxyURL = `http://127.0.0.1:${proxy.address().port}`;
  const environment = { ...f.environment, HTTPS_PROXY: proxyURL, https_proxy: proxyURL, NO_PROXY: '', no_proxy: '' };
  const result = await downloadDependency(f.args('/ok'), { environment });
  assert.equal(result.state, 'failed'); assert.equal(connects, 1); assert.equal(f.requests(), 0);
});
