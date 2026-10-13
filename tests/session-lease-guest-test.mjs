// Runs inside the real Linux ARM guest against the complete installed package
// and the shipped native addon. Only this suite asserts native flock behavior.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, open, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { Context } from '/usr/local/lib/node_modules/@deepseek-ai/cordis/lib/index.js';
import SessionStore from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session/lib/index.js';
import JsonlPersistence from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js';
import { SessionPersistenceCorruptionError } from '/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence/lib/index.js';

assert.equal(process.arch, 'arm64'); assert.equal(process.platform, 'linux');
const root = await mkdtemp('/tmp/dsh-session-lease.');
let passed = 0;
const hash = value => createHash('sha256').update(value).digest('hex');
const turn = () => new Promise(resolve => setImmediate(resolve));
async function test(name, operation) { await operation(); passed += 1; console.log('PASS ' + name); }
async function fixture({ malformedTitle = false } = {}) {
  const ctx = new Context(); const sessions = new SessionStore(ctx);
  const backend = new JsonlPersistence(ctx, { root: root + '/sessions', compression: 'none' });
  const session = sessions.prepare('lease-test-' + randomBytes(6).toString('hex'), { meta: { cwd: root + '/workspace' } });
  const handle = await backend.create(session.header);
  // Use a valid current-format manual title. Keeping an explicitly malformed
  // variant lets the real scanner prove that lifecycle validation stays strict.
  const title = { title: 'diagnostic baseline', messageSeqs: [], source: { kind: 'user' } };
  if (malformedTitle) delete title.messageSeqs;
  const event = session.append('session/title', title);
  await handle.append([event]); await handle.flush();
  const log = backend.locate(handle.header).path;
  const lock = log.slice(0, log.lastIndexOf('/')) + '/session.lock';
  if (!malformedTitle) assert.equal((await handle.read()).events.length, 1);
  return { backend, handle, session, log, lock };
}
async function resume(backend) { await backend.dshLifecycleResume(); backend.dshLifecycleOpen(); }
async function contender(lock) {
  const code = `import {open} from 'node:fs/promises';
    import {tryLockExclusive} from '/usr/local/lib/node_modules/@deepseek-ai/node-addon-system/lib/flock.js';
    const handle=await open(${JSON.stringify(lock)},'r+');
    try { await tryLockExclusive(handle.fd); await handle.close(); process.exitCode=0; }
    catch(error) { await handle.close(); if(error.code==='EAGAIN'||error.code==='EWOULDBLOCK') process.exitCode=23; else throw error; }`;
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', code], { stdio: ['ignore', 'pipe', 'pipe'] });
    let bytes = 0, diagnostic = '';
    for (const pipe of [child.stdout, child.stderr]) pipe.on('data', data => {
      bytes += data.length;
      diagnostic = (diagnostic + data.toString('utf8')).slice(0, 4096);
    });
    child.once('error', reject);
    child.once('close', (exitCode, signal) => signal ? reject(new Error('contender terminated by signal')) : resolve({ exitCode, bytes, diagnostic }));
  });
}
function injectLogFault(log, mode) {
  const originalOpen = fs.promises.open;
  const counts = { append: 0, rollback: 0 };
  fs.promises.open = async function (path, flags, ...options) {
    const file = await originalOpen.call(this, path, flags, ...options);
    if (path === log && flags === 'a') {
      counts.append += 1;
      if (mode === 'post-fsync-close') {
        const close = file.close.bind(file);
        file.close = async () => { await close(); throw Object.assign(new Error('injected consumed append close'), { code: 'EIO' }); };
      } else {
        const write = file.writeFile.bind(file);
        file.writeFile = async (...arguments_) => {
          if (mode === 'rollback-failure') await write(...arguments_);
          throw Object.assign(new Error('injected append write error'), { code: 'EIO' });
        };
      }
    }
    if (path === log && flags === 'r+' && mode === 'rollback-failure') {
      counts.rollback += 1;
      file.truncate = async () => { throw Object.assign(new Error('injected rollback truncate error'), { code: 'EIO' }); };
    }
    return file;
  };
  syncBuiltinESMExports();
  return { counts, restore() { fs.promises.open = originalOpen; syncBuiltinESMExports(); } };
}

try {
  await mkdir(root + '/workspace');
  const sentinels = ['config.yml', 'api-key.txt', 'workspace.txt', 'session-user.txt'];
  for (const name of sentinels) await writeFile(root + '/' + name, randomBytes(64));
  const initial = await Promise.all(sentinels.map(async name => hash(await readFile(root + '/' + name))));
  await test('native cross-process flock excludes a contender while the session writer is running', async () => {
    const { handle, lock } = await fixture(); const held = await contender(lock);
    assert.equal(held.exitCode, 23, JSON.stringify(held)); await handle.close();
    assert.equal((await contender(lock)).exitCode, 0);
    // This test-owned corrupt fixture must fail before releasing its lease.
    // Never weaken the production checkpoint validator to make test data pass.
    const invalid = await fixture({ malformedTitle: true });
    await assert.rejects(invalid.backend.dshLifecycleSuspend(), error =>
      error instanceof SessionPersistenceCorruptionError &&
      error.cause?.message === 'title messageSeqs requires an array');
    assert.equal(invalid.handle.dshCheckpoint, undefined);
    assert.equal((await contender(invalid.lock)).exitCode, 23);
    await invalid.handle.lease.release(); // Only this test's temporary fixture.
  });
  await test('normal lease suspension releases native flock, preserves the inode and reclaims exclusion on resume', async () => {
    const { backend, handle, lock } = await fixture();
    // Close the read-only probe too; it never holds a flock.
    const probe = await open(lock, 'r'); const identity = await probe.stat({ bigint: true }); await probe.close();
    await backend.dshLifecycleSuspend(); assert.equal((await contender(lock)).exitCode, 0);
    const after = await open(lock, 'r'); const current = await after.stat({ bigint: true }); await after.close();
    assert.equal(current.ino, identity.ino); assert.equal(current.dev, identity.dev);
    assert.equal(backend.tracker.writers.get(handle.id), handle);
    await resume(backend); assert.equal((await contender(lock)).exitCode, 23); await handle.close();
  });
  await test('paused appends and live events perform no writes and remain contiguous after resume', async () => {
    const { backend, handle, session, log } = await fixture(); await backend.dshLifecycleSuspend();
    const before = await readFile(log); const event = session.append('session/title', { title: 'retained after pause', messageSeqs: [], source: { kind: 'user' } });
    handle.enqueueLive(event, error => { throw error; });
    let flushed = false; const flush = backend.flush().then(() => { flushed = true; });
    await turn(); assert.equal(flushed, false); assert.equal(hash(await readFile(log)), hash(before));
    assert.equal(handle.dshPausedEvents.length, 1); assert.equal(handle.batchTimer, undefined);
    await resume(backend); await flush;
    const stored = await handle.read(); assert.deepEqual(stored.events.map(event => event.seq), [0, 1]); await handle.close();
  });
  await test('a continuing live producer cannot extend the sealed native-lease drain', async () => {
    const { backend, handle, session } = await fixture();
    handle.enqueueLive(session.append('session/title', { title: 'before seal', messageSeqs: [], source: { kind: 'user' } }), () => {});
    const persist = backend.persistBatch; let offered = 0;
    backend.persistBatch = async function (...arguments_) {
      if (offered < 100) {
        offered += 1;
        handle.enqueueLive(session.append('session/title', { title: 'while sealed', messageSeqs: [], source: { kind: 'user' } }), () => {});
      }
      return persist.apply(this, arguments_);
    };
    await backend.dshLifecycleSuspend();
    assert.equal(offered, 1); assert.equal(handle.lease, undefined);
    assert.equal(handle.dshPausedEvents.length, 1); assert.equal((await handle.read()).events.length, 2);
    for (let index = 0; index < 29; index += 1)
      handle.enqueueLive(session.append('session/title', { title: 'still paused', messageSeqs: [], source: { kind: 'user' } }), () => {});
    backend.persistBatch = persist; await resume(backend); await backend.flush();
    assert.deepEqual((await handle.read()).events.map(event => event.seq), Array.from({ length: 32 }, (_, index) => index));
    await handle.close();
  });
  await test('100 real lease suspend/resume cycles retain stable guest fd and handle counts', async () => {
    const { backend, handle } = await fixture(); await backend.dshLifecycleSuspend(); await resume(backend);
    const baseline = (await readdir('/proc/self/fd')).length;
    for (let cycle = 0; cycle < 100; cycle += 1) {
      await backend.dshLifecycleSuspend(); await backend.dshLifecycleSuspend();
      assert.equal(backend.dshLifecycleSnapshot().released_count, 1);
      await resume(backend); assert.equal(backend.tracker.openHandles.size, 1);
      assert.equal(backend.tracker.writers.size, 1);
    }
    assert.equal((await readdir('/proc/self/fd')).length, baseline); await handle.close();
  });
  for (const mutation of ['foreign-append', 'foreign-truncate', 'foreign-replace']) {
    await test(`resume rejects ${mutation} without overwriting the changed log or dropping retained events`, async () => {
      const { backend, handle, session, log } = await fixture(); const original = await readFile(log);
      await backend.dshLifecycleSuspend();
      if (mutation === 'foreign-append') {
        const other = new JsonlPersistence(new Context(), { root: root + '/sessions', compression: 'none' });
        const writer = await other.open(handle.id, 'write');
        const foreignEvent = structuredClone((await writer.read()).events[0]);
        foreignEvent.seq = 1; foreignEvent.data.title = 'foreign append';
        await writer.append([foreignEvent]); await writer.close();
      } else if (mutation === 'foreign-truncate') {
        await writeFile(log, original.toString('utf8').split('\n')[0] + '\n');
      } else await writeFile(log, original.toString('utf8').replace('diagnostic baseline', 'diagnostic altered!'));
      const retained = session.append('session/title', { title: 'retained pending', messageSeqs: [], source: { kind: 'user' } });
      handle.enqueueLive(retained, () => {}); const foreign = await readFile(log);
      await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_CHECKPOINT_CHANGED');
      assert.equal(hash(await readFile(log)), hash(foreign)); assert.equal(handle.dshPausedEvents.length, 1);
      await backend.dshLifecycleSuspend(); assert.equal(hash(await readFile(log)), hash(foreign));
      // Restore only this test-owned temporary artifact for orderly cleanup.
      await writeFile(log, original); await resume(backend); await backend.flush(); await handle.close();
    });
  }
  await test('an uncheckpointed real-storage drain error retains its batch and native exclusion without replay', async () => {
    const { backend, handle, session, lock } = await fixture();
    handle.enqueueLive(session.append('session/title', { title: 'retry retained batch', messageSeqs: [], source: { kind: 'user' } }), () => {});
    const persist = backend.persistBatch;
    backend.persistBatch = async () => { throw Object.assign(new Error('injected storage fault'), { code: 'EIO' }); };
    await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'EIO');
    assert.equal(handle.buffered.length, 1); assert.equal((await contender(lock)).exitCode, 23);
    backend.persistBatch = persist;
    await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
    assert.equal((await handle.read()).events.length, 1); assert.equal(handle.buffered.length, 1);
    // Test cleanup: normally close only this fixture's known held descriptor.
    await handle.lease.release();
  });
  for (const fault of ['post-fsync-close', 'rollback-failure']) {
    await test(`real append ${fault} cannot replay retained rows after an uncheckpointed failure`, async () => {
      const { backend, handle, session, log } = await fixture();
      handle.enqueueLive(session.append('session/title', { title: 'uncertain append', messageSeqs: [], source: { kind: 'user' } }), () => {});
      const injection = injectLogFault(log, fault);
      try { await assert.rejects(backend.dshLifecycleSuspend()); }
      finally { injection.restore(); }
      assert.equal(injection.counts.append, 1);
      assert.equal(injection.counts.rollback, fault === 'rollback-failure' ? 1 : 0);
      assert.equal(handle.state.cursor, 1); assert.equal(handle.buffered.length, 1); assert.equal(handle.dshCheckpoint, undefined);
      const changed = await readFile(log);
      assert.deepEqual((await handle.read()).events.map(event => event.seq), [0, 1]);
      await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
      await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'DSH_SESSION_STORAGE_UNCERTAIN');
      await assert.rejects(backend.flush(), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
      assert.equal(hash(await readFile(log)), hash(changed)); assert.equal(handle.buffered.length, 1);
      assert.equal(backend.tracker.writers.get(handle.id), handle);
      await handle.lease.release();
    });
  }
  await test('a verified checkpoint permits recovery after an append fault whose rollback completed', async () => {
    const { backend, handle, session, log } = await fixture(); await backend.dshLifecycleSuspend();
    const before = await readFile(log);
    handle.enqueueLive(session.append('session/title', { title: 'verified retry', messageSeqs: [], source: { kind: 'user' } }), () => {});
    const injection = injectLogFault(log, 'pre-write');
    try { await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'EIO'); }
    finally { injection.restore(); }
    assert.equal(injection.counts.append, 1); assert.equal(hash(await readFile(log)), hash(before));
    assert.equal(handle.buffered.length, 1); assert(handle.dshCheckpoint);
    await resume(backend); await backend.flush();
    assert.deepEqual((await handle.read()).events.map(event => event.seq), [0, 1]); await handle.close();
  });
  await test('native close consuming its fd before an error remains fail-closed on direct foreground', async () => {
    const { backend, handle, session, lock, log } = await fixture();
    const file = handle.lease.held.handle;
    handle.lease.held.handle = { close: async () => {
      await file.close(); throw Object.assign(new Error('injected post-close fault'), { code: 'EIO' });
    } };
    await assert.rejects(backend.dshLifecycleSuspend(), error => error.code === 'EIO');
    assert.equal((await contender(lock)).exitCode, 0);
    const bytes = await readFile(log);
    handle.enqueueLive(session.append('session/title', { title: 'retained after uncertain close', messageSeqs: [], source: { kind: 'user' } }), () => {});
    await assert.rejects(backend.dshLifecycleResume(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
    assert.throws(() => backend.dshLifecycleOpen(), error => error.code === 'DSH_SESSION_LEASE_UNCERTAIN');
    await assert.rejects(backend.flush(), error => error.code === 'DSH_SESSION_LIFECYCLE_FAILED');
    assert.equal(hash(await readFile(log)), hash(bytes)); assert.equal(handle.dshPausedEvents.length, 1);
    assert.equal(backend.tracker.writers.get(handle.id), handle); assert.equal(backend.dshLifecycleAdmission.state, 'failed');
  });
  await test('configuration, credential, workspace and prior-session sentinels remain byte-identical', async () => {
    const final = await Promise.all(sentinels.map(async name => hash(await readFile(root + '/' + name)))); assert.deepEqual(final, initial);
  });
  console.log(`SESSION_LEASE_GUEST_TESTS ${passed}/${passed}; native_flock_executed=true; cycles=100`);
} finally {
  // Only our mkdtemp tree is eligible for cleanup, never an app data path.
  assert(root.startsWith('/tmp/dsh-session-lease.'));
  await rm(root, { recursive: true, force: true });
}
