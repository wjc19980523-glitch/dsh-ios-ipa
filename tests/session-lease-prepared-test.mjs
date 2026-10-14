// Real host-file proof tests. Semantic decoding and native flock are exercised
// by the separate ARM guest suite, not claimed by these unit fixtures.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, readFile, writeFile, stat, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { syncBuiltinESMExports } from 'node:module';
import vm from 'node:vm';
import { SessionLifecycleAdmission } from '../app/SessionLifecycle.bundle/session-lifecycle-core.mjs';

const negative = process.argv.includes('--negative-control=no-hash');
let moduleSource = await readFile(new URL('../app/SessionLifecycle.bundle/session-checkpoint-core.mjs', import.meta.url), 'utf8');
if (negative) {
  assert(moduleSource.includes("hash.digest('hex') !== proof.digest"));
  moduleSource = moduleSource.replace("hash.digest('hex') !== proof.digest", 'false');
}
// This count hook exists only in the in-memory test module, never the resource.
moduleSource += '\nexport const __testSlotCount = backend => slots.get(backend)?.size ?? 0;\n';
const core = await import('data:text/javascript;base64,' + Buffer.from(moduleSource).toString('base64'));
const directory = await mkdtemp(join(tmpdir(), 'dsh-checkpoint-proof-'));
const originalOpen = fs.promises.open, originalStat = fs.promises.stat;
const changed = error => error.code === 'DSH_SESSION_CHECKPOINT_CHANGED';
const unstable = error => error.code === 'DSH_SESSION_CHECKPOINT_UNSTABLE';
let passed = 0, serial = 0;
async function test(name, operation) {
  if (negative && name !== 'same-identity valid JSON tampering requires the full raw digest') return;
  try { await operation(); passed += 1; console.log('PASS ' + name); }
  finally { fs.promises.open = originalOpen; fs.promises.stat = originalStat; syncBuiltinESMExports(); }
}
async function fixture() {
  const id = 'unit-' + serial++, path = join(directory, id + '.jsonl');
  const buffer = Buffer.from('{"n":1}\n'); await writeFile(path, buffer);
  const writer = { id, access: 'write', header: { id, createdAt: 1 },
    state: { cursor: 1, inheritedEventCount: 0, materialized: true }, lease: { released: false } };
  const backend = { tracker: { writers: new Map([[id, writer]]) }, locate: () => ({ path }),
    findLog: async () => ({ sourcePath: path, sourceVersion: 4 }) };
  async function decoded({ complete = true, bytes = undefined } = {}) {
    const context = core.beginDecodedSnapshot(backend, id, path);
    const identity = await stat(path, { bigint: true });
    const stored = { meta: structuredClone(writer.header), events: [{ seq: 0 }],
      inheritedEventCount: 0, recoveredTail: [] };
    core.rememberDecodedSnapshot(stored, path, bytes ?? await readFile(path),
      { identity, dshCompleteStable: complete }, context);
    return stored;
  }
  const stored = await decoded(); assert(core.adoptDecodedCheckpoint(backend, writer, stored));
  return { backend, writer, path, buffer, stored, decoded };
}
function hideMetadataChanges(path, originalIdentity) {
  fs.promises.stat = async function (value, options) {
    return value === path ? originalIdentity : originalStat.call(this, value, options);
  };
  fs.promises.open = async function (value, ...options) {
    const file = await originalOpen.call(this, value, ...options);
    if (value === path) file.stat = async () => originalIdentity;
    return file;
  };
  syncBuiltinESMExports();
}

try {
  await test('complete stable decoded bytes verify through the real descriptor', async () => {
    const { backend, writer, buffer } = await fixture();
    const proof = await core.verifyPreparedCheckpoint(backend, writer);
    assert.equal(proof.bytes, buffer.length); assert.equal(proof.digest.length, 64);
    assert.equal(writer.lease.released, false);
  });
  await test('logical header ordering and the persisted delegation default preserve the proof', async () => {
    const { backend, writer, path, buffer } = await fixture();
    const context = core.beginDecodedSnapshot(backend, writer.id, path), identity = await stat(path, { bigint: true });
    const stored = { meta: { delegationDepth: 0, createdAt: 1, id: writer.id }, events: [{}],
      inheritedEventCount: 0, recoveredTail: [] };
    core.rememberDecodedSnapshot(stored, path, buffer, { identity, dshCompleteStable: true }, context);
    assert(core.adoptDecodedCheckpoint(backend, writer, stored)); assert(await core.verifyPreparedCheckpoint(backend, writer));
  });
  await test('stat-only memo data cannot mint a proof', async () => {
    const { backend, writer, stored } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    const fakeMemo = { ...stored }; assert.equal(core.adoptDecodedCheckpoint(backend, writer, fakeMemo), false);
    assert.throws(() => core.checkpointFromDecoded(backend, writer, fakeMemo), unstable);
  });
  await test('bounded-prefix fallback cannot mint a complete proof', async () => {
    const { backend, writer, decoded } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    const stored = await decoded({ complete: false });
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
    assert.throws(() => core.checkpointFromDecoded(backend, writer, stored), unstable);
  });
  await test('short bytes with a stable marker cannot mint a complete proof', async () => {
    const { backend, writer, decoded } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    const stored = await decoded({ bytes: Buffer.from('{}') });
    assert.throws(() => core.checkpointFromDecoded(backend, writer, stored), unstable);
  });
  await test('pre-mutation epoch invalidates an old decoded memo', async () => {
    const { backend, writer, stored } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    assert.equal(core.hasPreparedCheckpoint(writer), false);
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
  });
  await test('a decode finishing after mutation cannot publish', async () => {
    const { backend, writer, path, buffer, stored } = await fixture();
    const context = core.beginDecodedSnapshot(backend, writer.id, path), identity = await stat(path, { bigint: true });
    core.invalidatePreparedCheckpoint(backend, writer.id);
    core.rememberDecodedSnapshot(stored, path, buffer, { identity, dshCompleteStable: true }, context);
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
  });
  await test('close retires proof and rejects late publication', async () => {
    const { backend, writer, stored } = await fixture(); core.retirePreparedCheckpoint(backend, writer);
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
  });
  await test('a replacement handle cannot inherit the prior incarnation proof', async () => {
    const { backend, writer, stored } = await fixture();
    const replacement = { ...writer, lease: { released: false } }; backend.tracker.writers.set(writer.id, replacement);
    assert.equal(core.adoptDecodedCheckpoint(backend, replacement, stored), false);
  });
  await test('uncertain or released leases cannot authorize preparation', async () => {
    const { backend, writer, stored } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    writer.lease.dshUncertain = true; assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
    writer.lease.dshUncertain = false; writer.lease.released = true;
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
  });
  await test('same-identity valid JSON tampering requires the full raw digest', async () => {
    const { backend, writer, path } = await fixture(); const identity = await stat(path, { bigint: true });
    await writeFile(path, '{"n":2}\n'); hideMetadataChanges(path, identity);
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
    assert.equal(writer.lease.released, false);
  });
  await test('ordinary full read cannot rebaseline externally changed valid JSON', async () => {
    const { backend, writer, path, decoded } = await fixture(); await writeFile(path, '{"n":2}\n');
    const replacement = await decoded();
    assert.throws(() => core.adoptDecodedCheckpoint(backend, writer, replacement), changed);
    assert.throws(() => core.invalidatePreparedCheckpoint(backend, writer.id), changed);
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
  });
  await test('explicit own mutation permits only a later complete decode to prepare', async () => {
    const { backend, writer, path, decoded } = await fixture(); core.invalidatePreparedCheckpoint(backend, writer.id);
    await writeFile(path, '{"n":2}\n'); assert.equal(await core.verifyPreparedCheckpoint(backend, writer), undefined);
    assert(core.adoptDecodedCheckpoint(backend, writer, await decoded()));
    assert(await core.verifyPreparedCheckpoint(backend, writer));
  });
  for (const condition of ['future-generation', 'opposite-encoding', 'obsolete-flat', 'duplicate-project']) {
    await test('authoritative namespace refusal is preserved for ' + condition, async () => {
      const { backend, writer } = await fixture(); backend.findLog = async () => { throw Object.assign(new Error('namespace refusal'), { code: 'E_NAMESPACE' }); };
      await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), error => error.code === 'E_NAMESPACE');
      assert.equal(writer.lease.released, false);
    });
  }
  await test('authoritative path or version changes refuse unchanged known bytes', async () => {
    const { backend, writer, path } = await fixture(); backend.findLog = async () => ({ sourcePath: path, sourceVersion: 5 });
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
  });
  await test('file replacement is refused even with identical contents', async () => {
    const { backend, writer, path, buffer } = await fixture(); const replacement = path + '.replacement';
    await writeFile(replacement, buffer); await rename(replacement, path);
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
  });
  await test('logical cursor and own JSON prototype-key changes cannot silently reuse a proof', async () => {
    const { backend, writer } = await fixture(); writer.state.cursor += 1;
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
    const item = await fixture(); core.invalidatePreparedCheckpoint(item.backend, item.writer.id);
    item.writer.header.origin = JSON.parse('{"__proto__":{"value":1}}');
    assert(core.adoptDecodedCheckpoint(item.backend, item.writer, await item.decoded()));
    item.writer.header.origin.__proto__.value = 2;
    await assert.rejects(core.verifyPreparedCheckpoint(item.backend, item.writer), changed);
  });
  await test('retained-tail witness changes cannot silently reuse a proof', async () => {
    const { backend, writer } = await fixture(); writer.state.recoveredTail = [{ seq: 0 }];
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
  });
  await test('fresh decoded checkpoint must match before foreground writes', async () => {
    const { backend, writer, stored, path, decoded, buffer } = await fixture();
    const checkpoint = core.checkpointFromDecoded(backend, writer, stored);
    core.invalidatePreparedCheckpoint(backend, writer.id);
    await writeFile(path, buffer); // Actual host metadata changes despite restored bytes.
    core.verifyDecodedCheckpoint(backend, writer, await decoded(), checkpoint);
    const restored = core.checkpointFromDecoded(backend, writer, await decoded());
    core.invalidatePreparedCheckpoint(backend, writer.id);
    await writeFile(path, '{"n":2}\n');
    const fresh = await decoded();
    assert.throws(() => core.verifyDecodedCheckpoint(backend, writer, fresh, restored), changed);
    assert.throws(() => core.assertCheckpointNotPoisoned(writer), changed);
    assert.throws(() => core.invalidatePreparedCheckpoint(backend, writer.id), changed);
  });
  await test('closing a read handle preserves the live writer proof', async () => {
    const { backend, writer } = await fixture();
    core.retirePreparedCheckpoint(backend, { id: writer.id, access: 'read' });
    assert(await core.verifyPreparedCheckpoint(backend, writer));
  });
  await test('ordinary close cannot erase a sticky mismatch before draining', async () => {
    const { backend, writer, path, decoded } = await fixture(); await writeFile(path, '{"n":2}\n');
    const fresh = await decoded(); assert.throws(() => core.adoptDecodedCheckpoint(backend, writer, fresh), changed);
    assert.throws(() => core.retirePreparedCheckpoint(backend, writer), changed);
    assert.throws(() => core.invalidatePreparedCheckpoint(backend, writer.id), changed);
    assert.equal(writer.lease.released, false);
  });
  await test('the actual patched close resets admission flags after a poisoned proof', async () => {
    const item = await fixture();
    const manifest = JSON.parse(await readFile(new URL('../app/SessionLifecycle.bundle/manifest.json', import.meta.url)));
    let source = await readFile(new URL('../app/SessionLifecycle.bundle/session-backend-original.js', import.meta.url), 'utf8');
    for (const replacement of manifest.patches[0].replacements) source = source.replaceAll(replacement.find, replacement.replace);
    const start = source.indexOf('var JsonlSessionHandle = class'), end = source.indexOf('\n};', start);
    const Handle = vm.runInNewContext(source.slice(start, end + 3) + '\nJsonlSessionHandle', {
      ...core, SessionHandleClosedError: Error, SessionReadOnlyError: Error, structuredClone, setTimeout, clearTimeout,
    });
    item.backend.dshLifecycleAdmission = new SessionLifecycleAdmission();
    const actual = new Handle(item.backend, item.writer.id, item.writer.header, 'write', item.writer.state, item.writer.lease);
    item.backend.tracker.writers.set(actual.id, actual);
    core.invalidatePreparedCheckpoint(item.backend, actual.id);
    assert(core.adoptDecodedCheckpoint(item.backend, actual, await item.decoded()));
    await writeFile(item.path, '{"n":2}\n');
    const freshStored = await item.decoded();
    assert.throws(() => core.adoptDecodedCheckpoint(item.backend, actual, freshStored), changed);
    actual.buffered.push({ seq: 1 });
    await assert.rejects(actual.close(), changed);
    assert.equal(actual.dshClosingAdmitted, false); assert.equal(actual.buffered.length, 1);
    assert.equal(actual.lease.released, false); assert.equal(item.backend.dshLifecycleAdmission.state, 'failed');
  });
  await test('retired IDs do not accumulate and old null-owner contexts cannot attach', async () => {
    const { backend, writer } = await fixture(); core.retirePreparedCheckpoint(backend, writer);
    backend.tracker.writers.delete(writer.id);
    for (let index = 0; index < 1000; index += 1) {
      const handle = { id: 'retire-' + index, access: 'write' };
      backend.tracker.writers.set(handle.id, handle); core.beginDecodedSnapshot(backend, handle.id, 'private-fixture');
      core.retirePreparedCheckpoint(backend, handle); backend.tracker.writers.delete(handle.id);
    }
    assert.equal(core.__testSlotCount(backend), 0);
    backend.tracker.writers.set(writer.id, null);
    const context = core.beginDecodedSnapshot(backend, writer.id, 'private-fixture');
    core.retireUnadoptedCheckpoint(backend, writer.id);
    backend.tracker.writers.set(writer.id, writer);
    const stored = { meta: writer.header, events: [{}], inheritedEventCount: 0, recoveredTail: [] };
    core.rememberDecodedSnapshot(stored, 'private-fixture', Buffer.from('{}'),
      { dshCompleteStable: true, identity: { size: 2n } }, context);
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored, true), false);
  });
  await test('unmapped low-level mutation conservatively invalidates current proofs', async () => {
    const { backend, writer, stored } = await fixture(); core.invalidatePreparedPath(backend, join(directory, 'different-namespace.jsonl'));
    assert.equal(core.adoptDecodedCheckpoint(backend, writer, stored), false);
  });
  await test('100 raw checks close every temporary read descriptor', async () => {
    const { backend, writer, path } = await fixture(); let opened = 0, closed = 0;
    fs.promises.open = async function (value, ...options) {
      const file = await originalOpen.call(this, value, ...options);
      if (value === path) { opened += 1; const close = file.close.bind(file); file.close = async () => { closed += 1; return close(); }; }
      return file;
    }; syncBuiltinESMExports();
    for (let count = 0; count < 100; count += 1) await core.verifyPreparedCheckpoint(backend, writer);
    assert.equal(opened, 100); assert.equal(closed, 100);
  });
  await test('temporary read close failure is observable and never releases the writer', async () => {
    const { backend, writer, path } = await fixture(); let closed = 0;
    fs.promises.open = async function (value, ...options) {
      const file = await originalOpen.call(this, value, ...options);
      if (value === path) { const close = file.close.bind(file); file.close = async () => { closed += 1; await close(); throw Object.assign(new Error('read close fault'), { code: 'EIO' }); }; }
      return file;
    }; syncBuiltinESMExports();
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), error => error.code === 'EIO');
    assert.equal(closed, 1); assert.equal(writer.lease.released, false);
  });
  await test('own mutation during raw read cannot publish stale proof', async () => {
    const { backend, writer, path } = await fixture(); let invalidated = false;
    fs.promises.open = async function (value, ...options) {
      const file = await originalOpen.call(this, value, ...options);
      if (value === path) { const read = file.read.bind(file); file.read = async (...arguments_) => {
        if (!invalidated) { invalidated = true; core.invalidatePreparedCheckpoint(backend, writer.id); }
        return read(...arguments_);
      }; }
      return file;
    }; syncBuiltinESMExports();
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed);
  });
  await test('a namespace change during complete raw reading is refused at the final selection', async () => {
    const { backend, writer, path } = await fixture(); let future = false, calls = 0;
    backend.findLog = async () => { calls += 1; return { sourcePath: path, sourceVersion: future ? 5 : 4 }; };
    fs.promises.open = async function (value, ...options) {
      const file = await originalOpen.call(this, value, ...options);
      if (value === path) { const read = file.read.bind(file); file.read = async (...args) => { future = true; return read(...args); }; }
      return file;
    }; syncBuiltinESMExports();
    await assert.rejects(core.verifyPreparedCheckpoint(backend, writer), changed); assert.equal(calls, 2);
  });
  await test('the shipped stable reader marks only its complete stable branch', async () => {
    const manifest = JSON.parse(await readFile(new URL('../app/SessionLifecycle.bundle/manifest.json', import.meta.url)));
    let source = await readFile(new URL('../app/SessionLifecycle.bundle/session-backend-original.js', import.meta.url), 'utf8');
    for (const replacement of manifest.patches[0].replacements) source = source.replaceAll(replacement.find, replacement.replace);
    const start = source.indexOf('async function readStableSnapshot('), end = source.indexOf('\n/** Parse the version', start);
    const identity = value => [value.dev, value.ino, value.size, value.mtimeNs, value.ctimeNs].join(':');
    const readStable = vm.runInNewContext(source.slice(start, end) + '\nreadStableSnapshot', { identity });
    const sample = value => ({ dev: 1n, ino: 1n, size: BigInt(value), mtimeNs: BigInt(value), ctimeNs: BigInt(value) });
    const stable = await readStable('fixture', undefined, { stat: async () => sample(8), readFile: async () => Buffer.alloc(8) });
    assert.equal(stable.dshCompleteStable, true);
    let probe = 1; const partial = await readStable('fixture', undefined,
      { stat: async () => sample(probe++), readFile: async () => Buffer.alloc(8) });
    assert.equal(partial.dshCompleteStable, undefined); assert.equal(partial.bytes.length, 2);
  });
  console.log(`SESSION_PREPARED_HOST_TESTS ${passed}/${passed}; native_flock_executed=false`);
} finally {
  fs.promises.open = originalOpen; fs.promises.stat = originalStat; syncBuiltinESMExports();
  await rm(directory, { recursive: true, force: true });
}
