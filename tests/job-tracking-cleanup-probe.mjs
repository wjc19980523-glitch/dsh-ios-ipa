// One isolated test process per scenario; invoked by job-tracking-cleanup-test.py.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { appendFileSync } from 'node:fs';
import { mkdtemp, realpath, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { captureBridgeLedger, cleanupJobTrackingFixture, closeFixtureServer } from './job-tracking-cleanup.mjs';

const [mode, fixturePath, proof] = process.argv.slice(2);
assert(['old-short-circuit', 'clean', 'rm-error', 'multiple-errors', 'early-error'].includes(mode));
const fixtures = resolve(fixturePath);
const record = (event, values = {}) => appendFileSync(proof, `${JSON.stringify({
  event, pid: process.pid, ppid: process.ppid, monotonic_ns: process.hrtime.bigint().toString(), ...values,
})}\n`);
record('bootstrap', { node_version: process.version, platform: process.platform });
const pkg = async name => import(pathToFileURL(join(fixtures, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await pkg('cordis');
const { SystemPrompt } = await pkg('dsh-system-prompt');
const { LocalJobRegistry } = await pkg('dsh-jobs-local');
const { JobLedger } = await import(pathToFileURL(join(fixtures, 'job-ledger.mjs')));

const runFixture = async t => {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'dsh-cleanup-owned-')));
  const ledger = new JobLedger(home); await ledger.flush();
  const ctx = new Context(), owner = { id: 'cleanup-owner', ctx: new Context(), status: 'busy' };
  ctx.provide('agents', { get: id => id === owner.id ? owner : undefined });
  ctx.provide('tools', { register() { return () => {}; } });
  new SystemPrompt(ctx, {}); new LocalJobRegistry(ctx, {});
  const jobs = ctx.get('jobs'); jobs.attachController('controlled-cleanup');
  const server = http.createServer((request, response) => {
    request.resume(); response.setHeader('content-type', 'application/json');
    response.end(request.url === '/proof' ? '{"controlled":true}' : '{"accepted":1}');
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const before = Object.fromEntries(['DSH_HOST_BRIDGE_URL', 'DSH_HOST_BRIDGE_TOKEN', 'DSH_HOME'].map(key => [key, process.env[key]]));
  process.env.DSH_HOST_BRIDGE_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.DSH_HOST_BRIDGE_TOKEN = 'controlled-cleanup-fixture'; process.env.DSH_HOME = home;
  const bridge = await import(pathToFileURL(join(fixtures, 'bridge-patched.mjs')));
  let trackingLedger;
  const originalGet = ctx.get;
  if (mode === 'multiple-errors') Object.defineProperty(ctx, 'get', {
    configurable: true, enumerable: true, writable: false, value: originalGet,
  });
  const descriptor = Object.getOwnPropertyDescriptor(ctx, 'get');
  const apply = () => captureBridgeLedger(ctx, () => {
    bridge.apply(ctx);
    if (mode === 'multiple-errors') throw applyError;
  }, ledger => { trackingLedger = ledger; });
  const applyError = Object.assign(new Error('controlled apply rejection after journal creation'), { code: 'E_CONTROLLED_APPLY' });
  if (mode === 'multiple-errors') assert.throws(apply, error => error === applyError);
  else apply();
  assert.deepEqual(Object.getOwnPropertyDescriptor(ctx, 'get'), descriptor);
  if (descriptor && 'value' in descriptor) assert.equal(ctx.get, descriptor.value);
  else assert.equal(typeof ctx.get, 'function'); // The inherited getter returns fresh bound functions.
  assert(trackingLedger); assert.notEqual(trackingLedger, ledger);
  record('capture:verified', { apply_error_preserved: mode === 'multiple-errors', get_descriptor_restored: true });
  const job = jobs.start({ owner: owner.id, kind: 'bash', label: 'controlled cleanup producer',
    run: () => ({ done: Promise.resolve({ status: 'completed', detail: 'exit code: 0' }), cancel() {} }) });
  await new Promise(setImmediate);
  assert.equal(jobs.get(job, owner.id).status, 'completed');
  await trackingLedger.flush();
  const errors = {
    rm: Object.assign(new Error('controlled rm rejection'), { code: 'E_CONTROLLED_RM' }),
    jobs: Object.assign(new Error('controlled jobs rejection'), { code: 'E_CONTROLLED_JOBS' }),
    close: Object.assign(new Error('controlled close rejection'), { code: 'E_CONTROLLED_CLOSE' }),
    env: Object.assign(new Error('controlled environment rejection'), { code: 'E_CONTROLLED_ENV' }),
  };
  let environmentRestored = false, bridgeFlushed = false, removedRecordSaved = false;
  const restore = () => {
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    environmentRestored = true;
  };
  const observe = () => record('post-hooks', { server_listening: server.listening,
    environment_restored: environmentRestored, bridge_flushed: bridgeFlushed,
    removed_record_saved: removedRecordSaved });
  const reportFailure = error => {
    const expected = mode === 'early-error' ? errors.jobs : errors.rm;
    record('cleanup:error', { same_error: error === expected, code: error?.code });
    setImmediate(observe); throw error;
  };
  if (mode === 'old-short-circuit') {
    // Original ordering: the fixture's first after hook fails before later owners.
    t.after(async () => {
      try { await jobs.disposeAll(); await ledger.flush(); throw errors.rm; }
      catch (error) { return reportFailure(error); }
    });
    t.after(async () => { record('old:server-close'); await closeFixtureServer(server); });
    t.after(() => { record('old:env-restore'); restore(); });
  } else {
    t.after(async () => {
      const capturedLedger = trackingLedger;
      assert.equal(capturedLedger, trackingLedger);
      const ownedJobs = mode === 'early-error' ? { async disposeAll() { await jobs.disposeAll(); throw errors.jobs; } } : jobs;
      try {
        await cleanupJobTrackingFixture({ jobs: ownedJobs, ctx, ledger, trackingLedger: capturedLedger,
          remove: async () => {
            const view = await capturedLedger.list(owner.id);
            record('ledger:state', { persistence: view.persistence, records: view.records.length });
            assert.equal(view.pending_writes, false); bridgeFlushed = true;
            const saved = JSON.parse(await readFile(join(home, '.job-history/v1.json'), 'utf8'));
            removedRecordSaved = saved.records.some(row => row.job_id === job && row.removed === true);
            assert(removedRecordSaved, 'disposeAll removal must reach the actual bridge journal before rm');
            if (mode !== 'clean') throw errors.rm;
            await rm(home, { recursive: true, force: true });
          },
          closeServer: async () => { await closeFixtureServer(server); if (['multiple-errors', 'early-error'].includes(mode)) throw errors.close; },
          restoreEnvironment: () => { restore(); if (['multiple-errors', 'early-error'].includes(mode)) throw errors.env; },
          step: async (stage, operation) => {
            record(`${stage}:start`);
            try { const value = await operation(); record(`${stage}:done`); return value; }
            catch (error) { record(`${stage}:error`, { code: error?.code }); throw error; }
          },
        });
        record('cleanup:done'); setImmediate(observe);
      } catch (error) { return reportFailure(error); }
    });
  }
  record('body:done', { port: server.address().port, distinct_bridge_ledger: trackingLedger !== ledger });
};
test(`controlled cleanup ${mode}`, async t => {
  try { await runFixture(t); }
  catch (error) { record('body:error', { code: error?.code, message: error?.message }); throw error; }
});
