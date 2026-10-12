// Host algorithm regression. The production class bodies are extracted from
// the manifest-patched package; the lease/storage adapters here are mocks.
// This suite deliberately makes no claim about native flock execution.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { SessionLifecycleAdmission } from '../app/SessionLifecycle.bundle/session-lifecycle-core.mjs';

const manifest = JSON.parse(await readFile(new URL('../app/SessionLifecycle.bundle/manifest.json', import.meta.url)));
const sourceFile = process.argv[2];
assert(sourceFile, 'usage: node tests/session-lease-test.mjs ORIGINAL_PACKAGE_SOURCE');
let source = (await readFile(sourceFile, 'utf8')).replaceAll('\r\n', '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
if (hash(source) !== manifest.patches[0].patched_sha256) {
  assert.equal(hash(source), manifest.patches[0].original_sha256);
  for (const replacement of manifest.patches[0].replacements) {
    assert.equal(source.split(replacement.find).length - 1, replacement.count);
    source = source.replaceAll(replacement.find, replacement.replace);
  }
}
assert.equal(hash(source), manifest.patches[0].patched_sha256);
for (const file of manifest.files) {
  const bytes = await readFile(new URL('../app/SessionLifecycle.bundle/' + file.source, import.meta.url));
  assert.equal(hash(bytes), file.sha256);
}
function classBody(name) {
  const start = source.indexOf('var ' + name + ' = class');
  assert(start >= 0);
  const end = source.indexOf('\n};', start);
  assert(end > start);
  return source.slice(start, end + 3);
}
class SessionHandleClosedError extends Error {
  constructor(id, op) { super(`closed handle: ${op}`); this.name = 'SessionHandleClosedError'; }
}
const { Handle, Backend, Lease } = vm.runInNewContext(
  classBody('JsonlSessionHandle') + '\n' + classBody('JsonlSessionPersistence')
    + '\n' + classBody('SessionWriteLease')
    + '\n({ Handle: JsonlSessionHandle, Backend: JsonlSessionPersistence, Lease: SessionWriteLease });', {
    SessionPersistence: class {}, SessionHandleClosedError, SessionLifecycleAdmission,
    JsonlCompressionSchema: {}, z: { object: () => ({}), string: () => ({ required: () => ({}) }) },
    createHash, structuredClone, clearTimeout, setTimeout, process: { platform: 'linux' },
    materializeAppendBatch: events => structuredClone(events),
    assertContiguous: (_id, batch, cursor) => batch.forEach((event, index) => assert.equal(event.seq, cursor + index)),
    SessionReadOnlyError: class extends Error {},
  });
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { resolve, promise };
};
const turn = () => new Promise(resolve => setImmediate(resolve));
const event = seq => ({ seq, type: 'test/event', data: { value: seq } });
function fixture() {
  const backend = Object.create(Backend.prototype);
  const state = { held: 0, acquired: 0, released: 0, writes: 0, events: [],
    header: { id: 'test-session', createdAt: 1 }, failWrite: false, failClose: false, failAcquire: false };
  backend.dshLifecycleAdmission = new SessionLifecycleAdmission();
  backend.coldLogMemo = new Map();
  backend.ctx = { logger: { warn() {} } };
  backend.tracker = { writers: new Map(), openHandles: new Set(), flushAll: async () => {
    for (const handle of backend.tracker.writers.values()) { await handle.drainLive(); await handle.flush(); }
  } };
  backend.acquireWriteLease = async () => {
    if (state.failAcquire) { const error = new Error('contention'); error.name = 'SessionAlreadyOwnedError'; throw error; }
    state.held += 1; state.acquired += 1;
    return new Lease({ kind: 'posix', handle: { close: async () => {
      if (state.consumeThenFail) { state.held -= 1; throw Object.assign(new Error('close consumed fd'), { code: 'EIO' }); }
      if (state.failClose) throw Object.assign(new Error('close fault'), { code: 'EIO' });
      state.held -= 1; state.released += 1;
    } } });
  };
  backend.persistHeader = async () => { state.writes += 1; };
  backend.persistBatch = async (_header, events) => {
    if (state.writeBarrier) await state.writeBarrier.promise;
    if (state.failWrite) throw Object.assign(new Error('write fault'), { code: 'EIO' });
    state.events.push(...structuredClone(events)); state.writes += 1;
  };
  backend.requireStoredLog = async () => ({ meta: structuredClone(state.header),
    events: structuredClone(state.events), inheritedEventCount: 0 });
  backend.releaseHandle = handle => { backend.tracker.writers.delete(handle.id); backend.tracker.openHandles.delete(handle); };
  const handle = new Handle(backend, 'test-session', structuredClone(state.header), 'write', {
    cursor: 0, materialized: false, inheritedEventCount: 0,
  });
  backend.tracker.writers.set(handle.id, handle);
  backend.tracker.openHandles.add(handle);
  return { backend, handle, state };
}
async function resume(backend) { await backend.dshLifecycleResume(); backend.dshLifecycleOpen(); }
let passed = 0;
async function test(name, callback) {
  await callback(); passed += 1; console.log(`PASS ${name}`);
}

await test('admitted work drains; fresh work remains blocked through Quiesced', async () => {
  const gate = new SessionLifecycleAdmission();
  const barrier = deferred(); let existing = false, fresh = false, drained = false;
  const old = gate.run(async () => { await barrier.promise; existing = true; });
  gate.close(); const newer = gate.run(() => { fresh = true; });
  const drain = gate.drain(() => { drained = true; });
  await turn(); assert.equal(fresh, false); assert.equal(drained, false);
  barrier.resolve(); await old; await drain; gate.markQuiesced();
  assert(existing); assert.equal(fresh, false); gate.open(); await newer; assert(fresh);
});
await test('an inherited async ticket expires when its original operation completes', async () => {
  const gate = new SessionLifecycleAdmission();
  const fired = deferred(); let entered = false; let child;
  await gate.run(() => { setImmediate(() => { child = gate.run(() => { entered = true; }); fired.resolve(); }); });
  gate.close(); await fired.promise; await turn(); assert.equal(entered, false);
  gate.open(); await child; assert(entered);
});
await test('a nested admitted operation that outlives its parent still blocks the drain', async () => {
  const gate = new SessionLifecycleAdmission(); const barrier = deferred(); let child, drained = false;
  await gate.run(() => { child = gate.run(() => barrier.promise); });
  gate.close(); const drain = gate.drain(() => { drained = true; });
  await turn(); assert.equal(drained, false); assert.equal(gate.active, 1);
  barrier.resolve(); await child; await drain; assert.equal(drained, true); assert.equal(gate.active, 0);
});
await test('confirmed lifecycle failure rejects waiters and new work but permits internal recovery', async () => {
  const gate = new SessionLifecycleAdmission(); gate.close(); let executed = false;
  const queued = gate.run(() => { executed = true; }); const refused = assert.rejects(queued, error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
  gate.fail(new Error('secret must not escape')); await refused;
  await assert.rejects(gate.run(() => { executed = true; }), error => error.message === 'session persistence lifecycle failed');
  assert.equal(executed, false);
  gate.beginResume(); await gate.drain(() => gate.run(() => { executed = true; }));
  assert.equal(executed, true); assert(gate.failure); gate.open(); assert.equal(gate.failure, undefined);
});
await test('suspension releases the lease and preserves original logical handle and claim', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  await backend.dshLifecycleSuspend(); assert.equal(state.held, 0);
  assert.equal(backend.tracker.writers.get(handle.id), handle);
  assert.equal(handle.closing, undefined); assert.equal(backend.dshLifecycleSnapshot().released_count, 1);
  await resume(backend); assert.equal(state.held, 1); await handle.close(); assert.equal(state.held, 0);
});
await test('paused live events remain ordered and drain on the same handle after resume', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
  handle.enqueueLive(event(1), error => { throw error; }); handle.enqueueLive(event(2), error => { throw error; });
  const writes = state.writes; await turn(); assert.equal(state.writes, writes); assert.equal(state.held, 0);
  assert.equal(handle.batchTimer, undefined); assert.equal(handle.dshPausedEvents.length, 2);
  await resume(backend); await backend.flush(); assert.deepEqual(state.events.map(x => x.seq), [0, 1, 2]);
  await handle.close();
});
await test('a continuing producer cannot extend the sealed drain and retains every original sequence', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  handle.enqueueLive(event(1), () => {});
  const persist = backend.persistBatch; let next = 2, producedWhileSealed = 0;
  backend.persistBatch = async (...arguments_) => {
    // A bounded test producer offers a new event at every storage yield. A
    // moving-boundary drain would consume all 100 instead of the sealed prefix.
    if (next < 102) { handle.enqueueLive(event(next++), () => {}); producedWhileSealed += 1; }
    return persist(...arguments_);
  };
  await backend.dshLifecycleSuspend();
  assert.equal(producedWhileSealed, 1); assert.equal(state.held, 0);
  assert.deepEqual(state.events.map(item => item.seq), [0, 1]);
  assert.deepEqual(Array.from(handle.dshPausedEvents, item => item.seq), [2]);
  for (; next < 102; next += 1) handle.enqueueLive(event(next), () => {});
  backend.persistBatch = persist; await resume(backend); await backend.flush();
  assert.deepEqual(state.events.map(item => item.seq), Array.from({ length: 102 }, (_, index) => index));
  await handle.close();
});
await test('append and ensureLease cannot reacquire while paused', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
  let done = false; const append = handle.append([event(1)]).then(() => { done = true; });
  const lease = handle.ensureLease(); await turn(); assert.equal(done, false); assert.equal(state.held, 0);
  await resume(backend); await append; await lease; assert.equal(state.events.length, 2); await handle.close();
});
await test('create and write-open wait without any host side effect', async () => {
  const { backend } = fixture(); let calls = 0;
  backend.dshCreateAdmitted = async () => ++calls;
  backend.dshOpenAdmitted = async () => ++calls;
  backend.dshLifecycleBeginQuiesce(); const create = backend.create({}); const open = backend.open('id', 'write');
  await turn(); assert.equal(calls, 0); backend.dshLifecycleOpen(); await create; await open; assert.equal(calls, 2);
});
await test('a background request during an existing append waits for its commit', async () => {
  const { backend, handle, state } = fixture(); state.writeBarrier = deferred();
  const append = handle.append([event(0)]); await turn();
  const pause = backend.dshLifecycleSuspend(); await turn(); assert.equal(state.released, 0);
  state.writeBarrier.resolve(); await append; await pause;
  assert.equal(state.events.length, 1); assert.equal(state.held, 0); await resume(backend); await handle.close();
});
await test('an uncheckpointed drain failure retains its batch and refuses an unverified retry', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  handle.enqueueLive(event(1), () => {}); state.failWrite = true;
  await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'EIO');
  assert.equal(handle.buffered.length, 1); assert.equal(state.held, 1); assert.equal(backend.tracker.writers.get(handle.id), handle);
  state.failWrite = false;
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
  await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
  assert.equal(state.events.length, 1); assert.equal(handle.buffered.length, 1); assert.equal(state.held, 1);
});
await test('an uncheckpointed close drain failure retains ownership and refuses blind replay', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  handle.enqueueLive(event(1), () => {}); state.failWrite = true;
  await assert.rejects(handle.close(), error => error.code === 'EIO');
  assert.equal(handle.buffered.length, 1); assert.equal(state.held, 1); assert.equal(handle.closing, undefined);
  assert.equal(backend.tracker.writers.get(handle.id), handle);
  state.failWrite = false;
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
  assert.equal(state.events.length, 1); assert.equal(state.held, 1);
});
for (const fault of ['append-fsynced-then-close-error', 'append-rollback-failed']) {
  await test(`${fault} cannot replay an uncheckpointed batch on foreground or another background`, async () => {
    const { backend, handle, state } = fixture(); await handle.append([event(0)]);
    handle.enqueueLive(event(1), () => {}); const persist = backend.persistBatch;
    backend.persistBatch = async (...arguments_) => {
      await persist(...arguments_);
      const error = Object.assign(new Error('injected post-write fault'), { code: 'EIO' });
      if (fault === 'append-rollback-failed') throw new AggregateError([error, error], 'injected rollback fault');
      throw error;
    };
    await assert.rejects(backend.dshLifecycleSuspend()); backend.persistBatch = persist;
    const bytes = JSON.stringify(state.events); const writes = state.writes;
    assert.equal(handle.state.cursor, 1); assert.equal(handle.buffered.length, 1);
    assert.equal(handle.dshCheckpoint, undefined); assert.equal(handle.lease.dshUncertain, undefined);
    await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
    await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
    await assert.rejects(backend.flush(), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
    assert.equal(JSON.stringify(state.events), bytes); assert.equal(state.writes, writes);
    assert.deepEqual(state.events.map(item => item.seq), [0, 1]); assert.equal(handle.buffered.length, 1);
    assert.equal(backend.tracker.writers.get(handle.id), handle);
  });
}
await test('close failure never reports a released lease or retries an uncertain descriptor', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); state.failClose = true;
  await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'EIO');
  assert.equal(state.held, 1); assert.equal(backend.dshLifecycleSnapshot().released_count, 0);
  state.failClose = false;
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  assert.equal(backend.dshLifecycleAdmission.state, 'failed');
  await assert.rejects(handle.append([event(1)]), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
  assert.equal(state.acquired, 1); assert.equal(state.events.length, 1);
});
await test('production lease release marks failed close uncertain and never retries its descriptor', async () => {
  let fail = true, closes = 0;
  const lease = new Lease({ kind: 'posix', handle: { close: async () => {
    closes += 1; if (fail) throw Object.assign(new Error('close failed'), { code: 'EIO' });
  } } });
  await assert.rejects(lease.release(), error => error.code === 'EIO'); assert.equal(lease.released, false);
  assert.equal(lease.dshUncertain, true); fail = false;
  await assert.rejects(lease.release(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  assert.equal(closes, 1); assert.equal(lease.released, false);
});
await test('a consumed descriptor plus close error cannot directly resume or write without a lock', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); state.consumeThenFail = true;
  await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'EIO');
  assert.equal(state.held, 0); assert(handle.dshCheckpoint); assert.equal(handle.lease.dshUncertain, true);
  handle.enqueueLive(event(1), () => {});
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  assert.throws(() => backend.dshLifecycleOpen(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  await assert.rejects(handle.append([event(2)]), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
  await assert.rejects(handle.ensureLease(), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
  assert.equal(state.acquired, 1); assert.equal(state.writes, 1); assert.equal(handle.dshPausedEvents.length, 1);
  assert.equal(backend.tracker.writers.get(handle.id), handle); assert.equal(backend.dshLifecycleAdmission.state, 'failed');
});
await test('an uncertain ordinary close cannot be skipped merely because no suspend checkpoint exists', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); state.consumeThenFail = true;
  await assert.rejects(handle.close(), error => error.code === 'EIO');
  assert.equal(handle.dshCheckpoint, undefined); assert.equal(handle.lease.dshUncertain, true);
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  assert.throws(() => backend.dshLifecycleOpen(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
  assert.equal(state.acquired, 1); assert.equal(state.held, 0); assert.equal(state.events.length, 1);
  assert.equal(backend.tracker.writers.get(handle.id), handle);
});
for (const mutation of ['append', 'truncate', 'replace-prefix', 'change-header']) {
  await test(`resume refuses external ${mutation} and retains pending events`, async () => {
    const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
    handle.enqueueLive(event(1), () => {});
    if (mutation === 'append') state.events.push(event(1));
    if (mutation === 'truncate') state.events.length = 0;
    if (mutation === 'replace-prefix') state.events[0].data.value = 99;
    if (mutation === 'change-header') state.header.createdAt = 99;
    await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_CHECKPOINT_CHANGED');
    assert.equal(backend.dshLifecycleAdmission.state, 'failed'); assert.equal(handle.dshPausedEvents.length, 1);
    const foreignBytes = JSON.stringify(state.events), writes = state.writes;
    await backend.dshLifecycleSuspend();
    assert.equal(state.held, 0); assert.equal(state.writes, writes);
    assert.equal(JSON.stringify(state.events), foreignBytes); assert.equal(handle.dshPausedEvents.length, 1);
    // Test cleanup only: restore the original mock storage, then resume normally.
    state.events = [event(0)]; state.header.createdAt = 1; await resume(backend); await handle.close();
  });
}
await test('reacquire contention keeps admission closed and preserves the original handle', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
  state.failAcquire = true; await assert.rejects(backend.dshLifecycleResume(), error => error.name === 'SessionAlreadyOwnedError');
  assert.equal(state.held, 0); assert.equal(backend.dshLifecycleAdmission.state, 'failed');
  state.failAcquire = false; await resume(backend); await handle.close();
});
await test('close requested while paused joins the original logical handle after resume', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
  let closed = false; const close = handle.close().then(() => { closed = true; }); await turn(); assert.equal(closed, false);
  handle.enqueueLive(event(1), () => {}); assert.equal(handle.dshPausedEvents.length, 1);
  await resume(backend); await close; assert.equal(state.held, 0); assert.equal(backend.tracker.writers.size, 0);
  assert.deepEqual(state.events.map(item => item.seq), [0, 1]);
});
await test('a close admitted before sealing drains its finite final producer batch before releasing the claim', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  handle.enqueueLive(event(1), () => {}); state.writeBarrier = deferred();
  const close = handle.close(); await turn(); assert.equal(handle.dshClosingAdmitted, true);
  const pause = backend.dshLifecycleSuspend();
  handle.enqueueLive(event(2), () => {}); assert.equal(handle.dshPausedEvents.length, 0);
  state.writeBarrier.resolve(); await close; await pause;
  assert.deepEqual(state.events.map(item => item.seq), [0, 1, 2]);
  assert.equal(state.held, 0); assert.equal(backend.tracker.writers.size, 0);
});
await test('resume propagates a retained-batch drain failure and keeps write admission closed', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]); await backend.dshLifecycleSuspend();
  handle.enqueueLive(event(1), () => {}); state.failWrite = true;
  await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'EIO');
  assert.equal(backend.dshLifecycleAdmission.state, 'failed'); assert.equal(handle.buffered.length, 1);
  assert.equal(state.events.length, 1); assert.equal(state.held, 1);
  state.failWrite = false; await resume(backend); assert.equal(state.events.length, 2); await handle.close();
});
await test('100 suspend/resume cycles leave no accumulating leases or writer claims', async () => {
  const { backend, handle, state } = fixture(); await handle.append([event(0)]);
  for (let index = 0; index < 100; index += 1) {
    await backend.dshLifecycleSuspend(); await backend.dshLifecycleSuspend(); assert.equal(state.held, 0);
    await resume(backend); await resume(backend); assert.equal(state.held, 1);
    assert.equal(backend.tracker.writers.size, 1); assert.equal(backend.tracker.openHandles.size, 1);
  }
  await handle.close(); assert.equal(state.held, 0); assert.equal(state.acquired, state.released);
});
console.log(`SESSION_LEASE_ALGORITHM_TESTS ${passed}/${passed}; native_flock_executed=false`);
