// Execute the shipped controller source with a controlled HTTP transport.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { lifecycleErrorCode } from '../app/SessionLifecycle.bundle/session-lifecycle-core.mjs';
const original = await readFile(new URL('../app/SessionLifecycle.bundle/session-lifecycle.mjs', import.meta.url), 'utf8');
const source = original.replace(/^import .*;\n/gm, '').replace(/^export \{.*\};\n/gm, '')
  .replaceAll('export function ', 'function ');
const turn = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { resolve, promise }; };
function setup(configured = true, managed = true) {
  const requests = [], timers = new Set(); let actions = [], inTransition = 0, maxTransition = 0;
  const backend = {
    closed: false, released: false, suspendBarrier: undefined, resumeFailure: undefined,
    dshLifecycleBeginQuiesce() { this.closed = true; actions.push('seal'); },
    async dshLifecycleSuspend() {
      inTransition += 1; maxTransition = Math.max(maxTransition, inTransition); actions.push('suspend');
      try { if (this.suspendBarrier) await this.suspendBarrier.promise; this.released = true; }
      finally { inTransition -= 1; }
    },
    async dshLifecycleResume() {
      inTransition += 1; maxTransition = Math.max(maxTransition, inTransition); actions.push('resume');
      try { if (this.resumeFailure) throw this.resumeFailure; this.released = false; }
      finally { inTransition -= 1; }
    },
    dshLifecycleOpen() { this.closed = false; actions.push('open'); },
    dshLifecycleFail() { this.closed = true; actions.push('fail'); },
    dshLifecycleSnapshot() { return { writer_count: 1, released_count: this.released ? 1 : 0, pending_events: 0 }; },
  };
  const context = vm.createContext({
    process: { pid: 22, env: configured ? { ...(managed ? { DSH_SESSION_LIFECYCLE: '1' } : {}), DSH_HOST_BRIDGE_URL: 'http://127.0.0.1:7777', DSH_HOST_BRIDGE_TOKEN: 'test-secret-not-logged' } : {} },
    backend, AbortController, queueMicrotask, lifecycleErrorCode,
    setTimeout(callback, delay) { const timer = setTimeout(() => { timers.delete(timer); callback(); }, delay); timers.add(timer); return timer; },
    clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); },
    fetch(url, options) {
      const result = deferred();
      requests.push({ path: new URL(url).pathname, body: JSON.parse(options.body), options, result, answered: false });
      options.signal.addEventListener('abort', () => result.resolve({ ok: false, status: 499, json: async () => ({}) }), { once: true });
      return result.promise;
    },
  });
  vm.runInContext(source, context);
  function register() { vm.runInContext('registerSessionBackend(backend)', context); }
  function unregister() { vm.runInContext('unregisterSessionBackend(backend)', context); }
  async function next(path, predicate = () => true) {
    for (let index = 0; index < 100; index += 1) {
      const found = requests.find(item => !item.answered && item.path === path && predicate(item.body));
      if (found) return found;
      await turn();
    }
    assert.fail(`missing controlled request ${path}`);
  }
  function answer(request, payload, status = 200) {
    request.answered = true;
    request.result.resolve({ ok: status >= 200 && status < 300, status, json: async () => payload });
  }
  async function desired(generation, state) {
    const poll = await next('/v1/lifecycle/poll');
    answer(poll, { protocol: 1, generation, state }); await turn();
  }
  async function bootstrap() {
    register(); await desired(0, 'running'); const ack = await next('/v1/lifecycle/ack');
    assert.equal(ack.body.state, 'running'); answer(ack, {}); await turn(); actions = [];
  }
  return { backend, requests, register, unregister, next, answer, desired, bootstrap,
    actions: () => actions, maxTransition: () => maxTransition,
    cleanup() { for (const timer of timers) clearTimeout(timer); timers.clear(); } };
}
let passed = 0;
async function test(name, operation) { await operation(); passed += 1; console.log('PASS ' + name); }

await test('module load has no I/O before backend registration; absent bridge stays inactive', async () => {
  const test = setup(false);
  try { await turn(); assert.equal(test.requests.length, 0); test.register(); await turn(); assert.equal(test.requests.length, 0); }
  finally { test.cleanup(); }
});
await test('a configured tool bridge without the managed lifecycle flag cannot start control polling', async () => {
  const test = setup(true, false);
  try { test.register(); await turn(); assert.equal(test.requests.length, 0); }
  finally { test.cleanup(); }
});
await test('first registration and every control request use the supervised pid and bearer authentication', async () => {
  const test = setup();
  try {
    test.register(); const poll = await test.next('/v1/lifecycle/poll');
    assert.equal(poll.body.pid, 22); assert.equal(poll.body.after_generation, -1);
    assert.equal(poll.options.method, 'POST'); assert.equal(poll.options.headers.authorization, 'Bearer test-secret-not-logged');
    test.answer(poll, { protocol: 1, generation: 0, state: 'running' });
    const ack = await test.next('/v1/lifecycle/ack'); assert.equal(ack.body.pid, 22); assert.equal(ack.body.generation, 0);
    assert.equal(ack.body.state, 'running'); assert.equal(ack.options.headers.authorization, 'Bearer test-secret-not-logged');
    assert.equal(JSON.stringify(ack.body).includes('test-secret'), false);
  } finally { test.cleanup(); }
});
await test('quiescing seals admission before asynchronous drain and only acknowledges after release', async () => {
  const test = setup();
  try {
    await test.bootstrap(); test.backend.suspendBarrier = deferred(); await test.desired(1, 'quiescing');
    assert.equal(test.backend.closed, true); assert.equal(test.backend.released, false);
    assert.equal(test.requests.some(item => item.path.endsWith('/ack') && item.body.generation === 1), false);
    test.backend.suspendBarrier.resolve(); const ack = await test.next('/v1/lifecycle/ack', body => body.generation === 1);
    assert.equal(ack.body.state, 'quiesced'); assert.equal(ack.body.released_count, 1); assert.equal(test.backend.closed, true);
  } finally { test.cleanup(); }
});
await test('fast foreground cancels the stale quiesce acknowledgement and serially resumes once', async () => {
  const test = setup();
  try {
    await test.bootstrap(); test.backend.suspendBarrier = deferred(); await test.desired(1, 'quiescing');
    await test.desired(2, 'running'); assert.equal(test.backend.closed, true);
    test.backend.suspendBarrier.resolve(); const ack = await test.next('/v1/lifecycle/ack', body => body.generation === 2);
    assert.equal(ack.body.state, 'running'); assert.equal(test.backend.closed, false); assert.equal(test.maxTransition(), 1);
    assert.equal(test.requests.some(item => item.path.endsWith('/ack') && item.body.generation === 1), false);
    assert.equal(test.actions().filter(action => action === 'resume').length, 1);
  } finally { test.cleanup(); }
});
await test('late rejected old ack cannot strand a newer resume behind a long poll', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    const stale = await test.next('/v1/lifecycle/ack', body => body.generation === 1);
    await test.desired(2, 'running'); test.answer(stale, {}, 409);
    const current = await test.next('/v1/lifecycle/ack', body => body.generation === 2);
    assert.equal(current.body.state, 'running'); assert.equal(test.backend.closed, false);
  } finally { test.cleanup(); }
});
await test('a never-responding old ACK is aborted when a newer foreground generation arrives', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    const stalled = await test.next('/v1/lifecycle/ack', body => body.generation === 1);
    await test.desired(2, 'running');
    assert.equal(stalled.options.signal.aborted, true);
    const current = await test.next('/v1/lifecycle/ack', body => body.generation === 2);
    assert.equal(current.body.state, 'running'); assert.equal(test.backend.closed, false);
    test.answer(current, {}); await turn();
    // The cancelled request may still deliver a late host response, but it
    // cannot complete or mutate the already running newer generation.
    test.answer(stalled, {}); await turn();
    assert.equal(test.backend.closed, false);
    assert.equal(test.actions().filter(action => action === 'resume').length, 1);
    assert.equal(test.maxTransition(), 1);
  } finally { test.cleanup(); }
});
await test('resume validation failure keeps admission closed and exposes only a finite error code', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    test.answer(await test.next('/v1/lifecycle/ack', body => body.generation === 1), {});
    test.backend.resumeFailure = Object.assign(new Error('private session content API Key must never escape'), { code: 'DSH_SESSION_CHECKPOINT_CHANGED' });
    await test.desired(2, 'running'); const failed = await test.next('/v1/lifecycle/ack', body => body.generation === 2);
    assert.equal(failed.body.state, 'failed'); assert.equal(failed.body.error_code, 'checkpoint_changed'); assert.equal(test.backend.closed, true);
    assert.equal(test.actions().filter(action => action === 'fail').length, 1);
    assert.equal(JSON.stringify(failed.body).includes('private'), false); assert.equal(JSON.stringify(failed.body).includes('API Key'), false);
  } finally { test.cleanup(); }
});
await test('duplicate desired generation does not start another transition after success', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    test.answer(await test.next('/v1/lifecycle/ack', body => body.generation === 1), {}); await turn();
    await test.desired(1, 'quiescing'); await turn();
    assert.equal(test.actions().filter(action => action === 'suspend').length, 1);
  } finally { test.cleanup(); }
});
await test('a terminal failed acknowledgement cannot be retried until a new generation', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    test.answer(await test.next('/v1/lifecycle/ack', body => body.generation === 1), {}); await turn();
    test.backend.resumeFailure = Object.assign(new Error('validation failed'), { code: 'DSH_SESSION_CHECKPOINT_CHANGED' });
    await test.desired(2, 'running');
    test.answer(await test.next('/v1/lifecycle/ack', body => body.generation === 2), {}); await turn();
    const count = test.actions().filter(action => action === 'resume').length;
    test.backend.resumeFailure = undefined;
    await test.desired(2, 'running'); await turn();
    assert.equal(test.actions().filter(action => action === 'resume').length, count);
    assert.equal(test.backend.closed, true);
    await test.desired(3, 'running');
    const fresh = await test.next('/v1/lifecycle/ack', body => body.generation === 3);
    assert.equal(fresh.body.state, 'running'); assert.equal(test.backend.closed, false);
  } finally { test.cleanup(); }
});
await test('a lost ACK response retries its identical payload without repeating storage transitions', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    const first = await test.next('/v1/lifecycle/ack', body => body.generation === 1);
    const originalBody = JSON.stringify(first.body);
    test.answer(first, {}, 503); await turn();
    test.backend.dshLifecycleSnapshot = () => ({ writer_count: 7, released_count: 7, pending_events: 9 });
    await test.desired(1, 'quiescing');
    const retry = await test.next('/v1/lifecycle/ack', body => body.generation === 1);
    assert.equal(JSON.stringify(retry.body), originalBody);
    assert.equal(test.actions().filter(action => action === 'suspend').length, 1);
    test.answer(retry, {}); await turn();
  } finally { test.cleanup(); }
});
await test('duplicate backend registration cannot change a generation already acknowledged', async () => {
  const test = setup();
  try {
    await test.bootstrap(); await test.desired(1, 'quiescing');
    test.answer(await test.next('/v1/lifecycle/ack', body => body.generation === 1), {}); await turn();
    test.register(); await test.desired(1, 'quiescing'); await turn();
    assert.equal(test.actions().filter(action => action === 'suspend').length, 1);
    assert.equal(test.requests.filter(item => item.path.endsWith('/ack') && item.body.generation === 1).length, 1);
    assert.equal(test.backend.closed, true);
  } finally { test.cleanup(); }
});
await test('last backend disposal aborts pending control requests and ends that poll epoch', async () => {
  const test = setup();
  try {
    await test.bootstrap(); const pending = await test.next('/v1/lifecycle/poll');
    test.unregister(); await turn(); assert.equal(pending.options.signal.aborted, true);
    const count = test.requests.length; await turn(); assert.equal(test.requests.length, count);
    test.register(); await turn();
    const fresh = test.requests.find((item, index) => index >= count && item.path.endsWith('/poll'));
    assert(fresh); assert.equal(fresh.body.after_generation, -1);
  } finally { test.cleanup(); }
});
console.log(`SESSION_LEASE_CONTROLLER_TESTS ${passed}/${passed}; transport=controlled`);
