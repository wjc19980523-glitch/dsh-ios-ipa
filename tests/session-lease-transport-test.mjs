// Actual TCP transport regression for the shipped lifecycle controller and
// the shipped jitless fetch adapter. Storage here is an explicit test adapter;
// native lease exclusion is asserted separately by the real ARM guest suite.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { performance } from 'node:perf_hooks';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

process.env.DSH_FORCE_FETCH_POLYFILL = '1';
createRequire(import.meta.url)('../ish-arm64/app/RootfsPatch.bundle/files/lib/fetch-polyfill.js');
const token = 'test-only-loopback-transport-token';
let pollCount = 0, blackholedAt = 0, blackholeClosed = false;
let resolveRunning, rejectRunning;
const running = new Promise((resolve, reject) => { resolveRunning = resolve; rejectRunning = reject; });
const receipts = [];
let suspendCount = 0, resumeCount = 0;
const backend = {
  sealed: false, released: false,
  dshLifecycleBeginQuiesce() { this.sealed = true; },
  async dshLifecycleSuspend() { suspendCount += 1; this.released = true; },
  async dshLifecycleResume() { resumeCount += 1; this.released = false; },
  dshLifecycleOpen() { this.sealed = false; },
  dshLifecycleFail() { this.sealed = true; },
  dshLifecycleSnapshot() { return { writer_count: 1, released_count: Number(this.released), pending_events: 0 }; },
};
const server = createServer((request, response) => {
  if (request.headers.authorization !== 'Bearer ' + token) { response.writeHead(401); response.end(); return; }
  let input = '';
  request.on('data', chunk => { input += chunk; assert(input.length <= 4096); });
  request.on('end', () => {
    try {
      const body = JSON.parse(input);
      receipts.push({ path: request.url, wait_ms: body.wait_ms, connection: request.headers.connection, generation: body.generation });
      const answer = payload => { response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(payload)); };
      if (request.url.endsWith('/poll')) {
        pollCount += 1;
        if (pollCount === 1) answer({ protocol: 1, generation: 1, state: 'quiescing' });
        else if (pollCount === 2) {
          blackholedAt = performance.now();
          response.on('close', () => { blackholeClosed = true; });
          // Real accepted TCP, deliberately no response headers or bytes.
        } else if (pollCount === 3) answer({ protocol: 1, generation: 2, state: 'running' });
      } else if (request.url.endsWith('/ack')) {
        if (body.generation === 1) { assert.equal(body.state, 'quiesced'); assert.equal(body.released_count, 1); }
        else if (body.generation === 2) { assert.equal(body.state, 'running'); assert.equal(body.released_count, 0); resolveRunning(performance.now()); }
        else assert.fail('unexpected lifecycle generation');
        answer({ accepted: true });
      } else { response.writeHead(404); response.end(); }
    } catch (error) { rejectRunning(error); response.writeHead(500); response.end(); }
  });
});
let controller, timer;
try {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  process.env.DSH_HOST_BRIDGE_URL = 'http://127.0.0.1:' + server.address().port;
  process.env.DSH_HOST_BRIDGE_TOKEN = token; process.env.DSH_SESSION_LIFECYCLE = '1';
  controller = await import(process.argv[2] ? pathToFileURL(resolve(process.argv[2])).href
    : new URL('../app/SessionLifecycle.bundle/session-lifecycle.mjs', import.meta.url).href);
  controller.registerSessionBackend(backend);
  const resumedAt = await Promise.race([running, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('real TCP lifecycle recovery exceeded fifteen seconds')), 15000);
  })]);
  assert(blackholedAt > 0); assert(blackholeClosed); assert(resumedAt - blackholedAt < 15000);
  assert.equal(suspendCount, 1); assert.equal(resumeCount, 1);
  assert.equal(backend.sealed, false); assert.equal(backend.released, false);
  assert(receipts.every(item => item.connection === 'close'));
  assert(receipts.filter(item => item.path.endsWith('/poll')).every(item => item.wait_ms === 3000));
  console.log('PASS actual TCP blackhole cancels and restores a new generation within the existing resume window');
  console.log('SESSION_LEASE_REAL_TCP_TESTS 1/1; fetch=shipped-jitless-adapter; recovery_ms=' + Math.round(resumedAt - blackholedAt));
} finally {
  clearTimeout(timer); controller?.unregisterSessionBackend(backend); server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
