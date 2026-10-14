// Every invocation is supervised independently with the existing 90-second
// real-status/EOF/no-residual contract. Uses complete installed ARM packages.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, open, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { syncBuiltinESMExports } from 'node:module';
import { Context } from '/usr/local/lib/node_modules/@deepseek-ai/cordis/lib/index.js';
import SessionStore from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session/lib/index.js';
import JsonlPersistence from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js';
import { tryLockExclusive } from '/usr/local/lib/node_modules/@deepseek-ai/node-addon-system/lib/flock.js';
import { invalidatePreparedCheckpoint, hasPreparedCheckpoint } from '/usr/local/share/dsh/session-checkpoint-core.mjs';

assert.equal(process.arch, 'arm64'); assert.equal(process.platform, 'linux');
const [mode, encoding] = process.argv.slice(2);
assert(['safety', 'large'].includes(mode)); assert(['none', 'zstd'].includes(encoding));
const root = await mkdtemp('/tmp/dsh-prepared-'); let passed = 0, fixtureCount = 0;
const checksum = bytes => createHash('sha256').update(bytes).digest('hex');
const changed = error => error.code === 'DSH_SESSION_CHECKPOINT_CHANGED';
const originalOpen = fs.promises.open;
async function test(name, operation) { await operation(); passed += 1; console.log('PASS ' + name); }
async function makeBackend() {
  const ctx = new Context(), sessions = new SessionStore(ctx);
  const options = { root: join(root, 'case-' + fixtureCount++) };
  if (encoding === 'none') options.compression = 'none';
  const backend = new JsonlPersistence(ctx, options); assert.equal(backend.compression, encoding);
  return { backend, sessions };
}
async function makeWriter(environment, bytes = 64) {
  const { backend, sessions } = environment ?? await makeBackend();
  const session = sessions.prepare('prepared-' + randomBytes(6).toString('hex'), { meta: { cwd: join(root, 'workspace') } });
  const handle = await backend.create(session.header); const events = [];
  for (let row = 0; row < 8; row += 1) events.push(session.append('session/title', {
    title: randomBytes(Math.max(8, bytes / 8)).toString('hex'), messageSeqs: [], source: { kind: 'user' },
  }));
  await handle.append(events); await handle.flush();
  const log = backend.locate(handle.header).path, lock = join(dirname(log), 'session.lock');
  assert.equal((await handle.read()).events.length, events.length); assert(hasPreparedCheckpoint(handle));
  return { backend, sessions, session, handle, log, lock, events };
}
async function held(lock) {
  const file = await open(lock, 'r+');
  try { await tryLockExclusive(file.fd); return false; }
  catch (error) { if (error.code === 'EAGAIN' || error.code === 'EWOULDBLOCK') return true; throw error; }
  finally { await file.close(); }
}
async function resume(backend) { await backend.dshLifecycleResume(); backend.dshLifecycleOpen(); }
async function externallyChangeTitle(item, malformed = false) {
  const events = structuredClone(item.events);
  events[0].data.title = 'changed outside native owner';
  if (malformed) delete events[0].data.messageSeqs;
  await writeFile(item.log, await item.backend.encodeMaterialization(item.handle.header,
    item.handle.state.inheritedEventCount, events));
}

try {
  if (mode === 'large') {
    await test('four real large writers retain full validation and skip clean background semantic decoding', async () => {
      const environment = await makeBackend(), writers = [];
      for (const bytes of [64 * 1024, 256 * 1024, 1024 * 1024, 4 * 1024 * 1024]) writers.push(await makeWriter(environment, bytes));
      const { backend } = environment, originalDecode = backend.decodeStoredLog;
      let actualDecodes = 0;
      backend.decodeStoredLog = async function (...args) { actualDecodes += 1; return originalDecode.apply(this, args); };
      const physicalBytes = [];
      for (const writer of writers) physicalBytes.push((await readFile(writer.log)).length);
      // A controlled conservative baseline on exactly the same actual files.
      for (const writer of writers) invalidatePreparedCheckpoint(backend, writer.handle.id);
      await backend.dshLifecycleSuspend(); const full = backend.dshLifecycleSnapshot().diagnostics;
      assert.equal(actualDecodes, 4); assert.equal(full.background_full_decode_count, 4);
      for (const writer of writers) assert.equal(await held(writer.lock), false);
      await resume(backend); actualDecodes = 0;
      await backend.dshLifecycleSuspend(); const clean = backend.dshLifecycleSnapshot().diagnostics;
      assert.equal(actualDecodes, 0); assert.equal(clean.prepared_verified_count, 4);
      assert.equal(clean.background_full_decode_count, 0);
      assert.equal(clean.raw_verified_bytes, physicalBytes.reduce((sum, value) => sum + value, 0));
      for (const writer of writers) assert.equal(await held(writer.lock), false);
      await resume(backend);
      const active = writers.at(-1), event = active.session.append('session/title', {
        title: 'last durable foreground batch', messageSeqs: [], source: { kind: 'user' },
      });
      await active.handle.append([event]); assert.equal(hasPreparedCheckpoint(active.handle), false); actualDecodes = 0;
      await backend.dshLifecycleSuspend(); const dirty = backend.dshLifecycleSnapshot().diagnostics;
      assert.equal(actualDecodes, 1); assert.equal(dirty.background_full_decode_count, 1);
      assert.equal(dirty.prepared_verified_count, 3); await resume(backend);
      assert.equal((await active.handle.read()).events.length, 9);
      for (const writer of writers) { assert.equal(backend.tracker.writers.get(writer.handle.id), writer.handle); await writer.handle.close(); }
      console.log('SESSION_PREPARED_TIMING ' + JSON.stringify({ encoding, physical_log_bytes: physicalBytes,
        semantic_title_bytes: 2 * (64 * 1024 + 256 * 1024 + 1024 * 1024 + 4 * 1024 * 1024),
        full, clean, dirty }));
    });
  } else {
    await test('closing an independent read handle preserves the prepared native writer', async () => {
      const item = await makeWriter(); const reader = await item.backend.open(item.handle.id, 'read');
      await reader.read(); await reader.close(); assert(hasPreparedCheckpoint(item.handle));
      await item.backend.dshLifecycleSuspend(); assert.equal(item.backend.dshLifecycleSnapshot().diagnostics.background_full_decode_count, 0);
      assert.equal(await held(item.lock), false); await resume(item.backend); assert.equal(await held(item.lock), true);
      await item.handle.close();
    });
    await test('ordinary read cannot rebaseline foreign bytes and close cannot discard the poison', async () => {
      const item = await makeWriter(); await externallyChangeTitle(item);
      const digest = checksum(await readFile(item.log)); await assert.rejects(item.handle.read(), changed);
      const event = item.session.append('session/title', { title: 'retained event', messageSeqs: [], source: { kind: 'user' } });
      item.handle.enqueueLive(event, () => {});
      await assert.rejects(item.handle.close(), changed); assert.equal(item.handle.buffered.length, 1);
      assert.equal(item.handle.dshClosingAdmitted, false);
      assert.equal(checksum(await readFile(item.log)), digest); assert.equal(await held(item.lock), true);
      await assert.rejects(item.backend.dshLifecycleSuspend()); assert.equal(await held(item.lock), true);
    });
    await test('direct clean checkpoint refuses externally changed valid current rows', async () => {
      const item = await makeWriter(); await externallyChangeTitle(item);
      await assert.rejects(item.backend.dshLifecycleSuspend(), changed); assert.equal(await held(item.lock), true);
    });
    await test('dirty malformed rows still run the complete original semantic decoder', async () => {
      const item = await makeWriter(); invalidatePreparedCheckpoint(item.backend, item.handle.id);
      await externallyChangeTitle(item, true);
      await assert.rejects(item.backend.dshLifecycleSuspend(), error => error.name === 'SessionPersistenceCorruptionError');
      assert.equal(await held(item.lock), true);
    });
    for (const namespace of ['future', 'opposite', 'obsolete', 'duplicate']) {
      await test('unchanged log cannot bypass the original ' + namespace + ' namespace refusal', async () => {
        const item = await makeWriter(), dir = dirname(item.log), name = basename(item.log), data = await readFile(item.log);
        if (namespace === 'future') { assert(name.includes('.v4.')); await writeFile(join(dir, name.replace('.v4.', '.v999.')), data); }
        if (namespace === 'opposite') await writeFile(encoding === 'none' ? item.log + '.zstd' : item.log.slice(0, -5), data);
        if (namespace === 'obsolete') await writeFile(join(dirname(dir), basename(dir) + '.jsonl'), data);
        if (namespace === 'duplicate') {
          const duplicate = join(item.backend.root, 'other-project', basename(dir)); await mkdir(duplicate, { recursive: true });
          await writeFile(join(duplicate, name), data);
        }
        await assert.rejects(item.backend.dshLifecycleSuspend()); assert.equal(await held(item.lock), true);
      });
    }
    await test('append invalidates preparation before open and a write fault retains ownership', async () => {
      const item = await makeWriter(); let reached = false;
      fs.promises.open = async function (path, flags, ...args) {
        if (path === item.log && flags === 'a') {
          reached = true; assert.equal(hasPreparedCheckpoint(item.handle), false);
          throw Object.assign(new Error('injected before append open'), { code: 'EIO' });
        }
        return originalOpen.call(this, path, flags, ...args);
      }; syncBuiltinESMExports();
      const event = item.session.append('session/title', { title: 'pending write', messageSeqs: [], source: { kind: 'user' } });
      item.handle.enqueueLive(event, () => {}); await assert.rejects(item.handle.drainLive(), error => error.code === 'EIO');
      fs.promises.open = originalOpen; syncBuiltinESMExports();
      assert(reached); assert.equal(item.handle.buffered.length, 1); assert.equal(await held(item.lock), true);
    });
    await test('successful own write remains dirty until a complete background decode', async () => {
      const item = await makeWriter(); const event = item.session.append('session/title', {
        title: 'new durable row', messageSeqs: [], source: { kind: 'user' },
      }); await item.handle.append([event]); assert.equal(hasPreparedCheckpoint(item.handle), false);
      await item.backend.dshLifecycleSuspend(); assert.equal(item.backend.dshLifecycleSnapshot().diagnostics.background_full_decode_count, 1);
      assert.equal(item.backend.dshLifecycleSnapshot().diagnostics.prepared_verified_count, 0);
      await resume(item.backend); assert.equal((await item.handle.read()).events.length, 9); await item.handle.close();
    });
    await test('closed writer incarnation cannot prepare a later handle from its old memo', async () => {
      const item = await makeWriter(); await item.handle.close();
      const reopened = await item.backend.open(item.handle.id, 'write');
      assert.equal(hasPreparedCheckpoint(reopened), false);
      await item.backend.dshLifecycleSuspend(); assert.equal(item.backend.dshLifecycleSnapshot().diagnostics.background_full_decode_count, 1);
      await resume(item.backend); await reopened.close();
    });
  }
  const expected = mode === 'safety' ? 11 : 1; assert.equal(passed, expected);
  console.log(`SESSION_PREPARED_GUEST_TESTS ${passed}/${expected}; native_flock_executed=true; mode=${mode}; encoding=${encoding}`);
} finally {
  fs.promises.open = originalOpen; syncBuiltinESMExports();
  // Only this invocation's freshly-created private fixture directory is removed.
  await rm(root, { recursive: true, force: true });
}
