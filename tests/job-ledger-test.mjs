import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, symlink, link, stat, lstat, mkdir, open, rename, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobLedger, jobOutcome, toolOutcome } from '../app/JobTracking.bundle/job-ledger.mjs';
import { installJobTracking, installTaskActivity } from '../app/JobTracking.bundle/job-tracking.mjs';

const RUN1 = '11111111-1111-4111-8111-111111111111';
const RUN2 = '22222222-2222-4222-8222-222222222222';
const event = (status = 'running', detail, owner = 'session-A', id = 'bash-1', type = 'settled', cause) =>
  ({ type, cause, job: { id, owner, kind: 'bash', status, detail, label: 'SECRET_TOKEN=must-not-be-saved',
    result: 'sensitive output', output: { spillPaths: ['/private/secret'] } } });
async function fixture(t, options = {}) {
  const home = await mkdtemp(join(tmpdir(), 'dsh-job-ledger-'));
  const ledger = new JobLedger(home, { runID: RUN1, ...options }); await ledger.ready;
  t.after(async () => { await ledger.flush(); await rm(home, { recursive: true, force: true }); });
  return { home, ledger };
}

test('only an explicit exit zero establishes success; completed alone does not', () => {
  assert.deepEqual(jobOutcome(event('completed', 'exit code: 0').job), { state: 'succeeded', exit_code: 0 });
  assert.deepEqual(jobOutcome(event('completed', 'exit code: 7').job), { state: 'failed', exit_code: 7 });
  assert.equal(jobOutcome(event('completed', 'unauthorized; all done').job).state, 'unknown');
  assert.equal(jobOutcome(event('completed').job).state, 'unknown');
  assert.equal(jobOutcome(event('completed', 'exit code: 0; sandbox runner failed').job).state, 'unknown');
});
test('teardown cancel failure stays unknown; confirmed signal is interrupted', () => {
  assert.equal(jobOutcome(event('failed', 'cancel threw').job, 'teardown').state, 'unknown');
  assert.deepEqual(jobOutcome(event('killed', 'signal: SIGTERM').job), { state: 'interrupted', signal: 'SIGTERM' });
  assert.equal(jobOutcome(event('killed', 'killed before exit').job).state, 'unknown');
});
test('activity uses structured command evidence, including promotion and unknown exits', () => {
  assert.equal(toolOutcome('bash', { value: { kind: 'promoted', jobId: 'bash-1' } }).outcome, 'started');
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: 2 } }).outcome, 'error');
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: 0, timedOut: true } }).outcome, 'timed out');
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: null } }).outcome, 'unknown');
  assert.equal(toolOutcome('job_kill', {}).outcome, 'unknown');
});
test('a running job_output wait return is never reported successful', () => {
  assert.equal(toolOutcome('job_output', { value: { job: event().job } }).outcome, 'started');
  assert.equal(toolOutcome('job_output', { value: { job: event('completed', 'exit code: 6').job } }).outcome, 'error');
});
test('metadata persists actual terminal status and strips every command/output/path', async t => {
  const { ledger } = await fixture(t);
  ledger.observe(event()); ledger.observe(event('completed', 'exit code: 0'));
  await ledger.flush();
  const bytes = await readFile(ledger.path, 'utf8');
  assert(!bytes.includes('SECRET')); assert(!bytes.includes('sensitive')); assert(!bytes.includes('/private'));
  const list = await ledger.list('session-A'); assert.equal(list.records[0].state, 'succeeded');
  if (process.platform !== 'win32') assert.equal((await stat(ledger.path)).mode & 0o777, 0o600);
});
test('finished tasks remain queryable; reading never consumes status or re-executes', async t => {
  const { ledger } = await fixture(t); ledger.observe(event('completed', 'exit code: 3'));
  const id = `${RUN1}:bash-1`;
  for (let i = 0; i < 100; i++) assert.equal((await ledger.status(id, 'session-A')).record.exit_code, 3);
  ledger.observe(event('completed', 'exit code: 3', 'session-A', 'bash-1', 'removed'));
  assert.equal((await ledger.status(id, 'session-A')).record.state, 'failed'); await ledger.flush();
});
test('cross-session queries cannot expose another session even with known execution ID', async t => {
  const { ledger } = await fixture(t); ledger.observe(event());
  assert.deepEqual((await ledger.list('session-B')).records, []);
  assert.equal((await ledger.status(`${RUN1}:bash-1`, 'session-B')).record, null);
  assert.deepEqual((await ledger.list(undefined)).records, []);
  await ledger.flush();
});
test('new run marks old running work unknown; reused bash ID cannot overwrite it', async t => {
  const { home, ledger } = await fixture(t); ledger.observe(event()); await ledger.flush();
  const restart = new JobLedger(home, { runID: RUN2 }); await restart.ready;
  assert.equal((await restart.status(`${RUN1}:bash-1`, 'session-A')).record.state, 'unknown');
  restart.observe(event('completed', 'exit code: 0')); await restart.flush();
  assert.equal((await restart.status(`${RUN2}:bash-1`, 'session-A')).record.state, 'succeeded');
  assert.equal((await restart.status(`${RUN1}:bash-1`, 'session-A')).record.state, 'unknown');
});
test('restart preserves confirmed failures and interrupted work', async t => {
  const { home, ledger } = await fixture(t);
  ledger.observe(event('completed', 'exit code: 4')); ledger.observe(event('killed', 'signal: SIGTERM', 'session-A', 'bash-2'));
  await ledger.flush(); const restart = new JobLedger(home, { runID: RUN2 }); await restart.ready;
  assert.deepEqual((await restart.list('session-A')).records.map(r => r.state), ['failed', 'interrupted']); await restart.flush();
});
test('late running events cannot revive a terminal failure', async t => {
  const { ledger } = await fixture(t); ledger.observe(event('completed', 'exit code: 2')); ledger.observe(event());
  assert.equal((await ledger.list('session-A')).records[0].state, 'failed'); await ledger.flush();
});
test('corrupt journal is preserved; available live metadata explicitly reports unavailable persistence', async t => {
  const { home, ledger } = await fixture(t); await ledger.flush();
  await writeFile(ledger.path, 'corrupt-user-sentinel');
  const restart = new JobLedger(home, { runID: RUN2 }); await restart.ready;
  restart.observe(event()); await restart.flush();
  assert.equal((await restart.list('session-A')).persistence, 'unavailable');
  assert.equal(await readFile(ledger.path, 'utf8'), 'corrupt-user-sentinel');
});
test('journal symlink never overwrites its target', async t => {
  const { home, ledger } = await fixture(t); await ledger.flush();
  const sentinel = join(home, 'sentinel'); await writeFile(sentinel, 'keep'); await rm(ledger.path);
  await symlink(sentinel, ledger.path);
  const restart = new JobLedger(home, { runID: RUN2 }); await restart.ready;
  restart.observe(event()); await restart.flush();
  assert.equal(restart.storage, 'unavailable'); assert.equal(await readFile(sentinel, 'utf8'), 'keep');
});
test('journal hardlink is refused without altering its other name', async t => {
  const { home, ledger } = await fixture(t); await ledger.flush();
  await link(ledger.path, join(home, 'sentinel')); const before = await readFile(ledger.path);
  const restart = new JobLedger(home, { runID: RUN2 }); await restart.ready;
  restart.observe(event()); await restart.flush(); assert.equal(restart.storage, 'unavailable');
  assert.deepEqual(await readFile(join(home, 'sentinel')), before);
});
test('bounded burst retention and filesystem content sentinels', async t => {
  const { home, ledger } = await fixture(t);
  const sentinel = join(home, 'user-config'); await writeFile(sentinel, 'API_KEY_SENTINEL');
  for (let i = 1; i <= 500; i++) ledger.observe(event('completed', 'exit code: 0', 'session-A', `bash-${i}`));
  await ledger.flush(); assert.equal((await ledger.list('session-A')).records.length, 256);
  assert((await stat(ledger.path)).size < 256 * 1024); assert.equal(await readFile(sentinel, 'utf8'), 'API_KEY_SENTINEL');
});
test('active long task is retained while many short commands finish', async t => {
  const { ledger } = await fixture(t); ledger.observe(event());
  for (let i = 2; i <= 400; i++) ledger.observe(event('completed', 'exit code: 0', 'session-A', `bash-${i}`));
  assert.equal((await ledger.status(`${RUN1}:bash-1`, 'session-A')).record.state, 'running'); await ledger.flush();
});
test('write failure preserves old journal and exposes persistence failure without throwing into work', async t => {
  const { home, ledger } = await fixture(t); ledger.observe(event('completed', 'exit code: 5')); await ledger.flush();
  const before = await readFile(ledger.path);
  const fs = { lstat, mkdir, open: async (path, ...args) => {
    if (path.endsWith('.tmp')) throw Object.assign(new Error('controlled EIO'), { code: 'EIO' });
    return open(path, ...args);
  }, rename, unlink };
  const restart = new JobLedger(home, { runID: RUN2, fs }); await restart.ready;
  restart.observe(event()); await restart.flush();
  assert.equal((await restart.list('session-A')).persistence, 'unavailable');
  assert.deepEqual(await readFile(ledger.path), before);
});
test('confirmed nonzero or denied execution cannot be announced successful', () => {
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: 0, sandbox: { runnerFailed: true } } }).outcome, 'unknown');
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: 0, sandbox: { denied: true } } }).outcome, 'refused');
  assert.equal(toolOutcome('bash', { value: { kind: 'foreground', exitCode: 0, stopped: 'cancelled' } }).outcome, 'interrupted');
});
test('actual activity middleware distinguishes success, promotion, failure, and missing evidence', async () => {
  const hooks = {}, rows = [];
  const ctx = { on: (name, fn) => { hooks[name] = fn; }, get: () => undefined };
  installTaskActivity(ctx, row => rows.push(row));
  for (const value of [{ kind: 'foreground', exitCode: 0 }, { kind: 'promoted' },
    { kind: 'foreground', exitCode: 9 }, { kind: 'foreground', exitCode: null }]) {
    const exec = { name: 'bash', agent: { id: 'session-A' }, args: { command: 'TOKEN=PRIVATE' } };
    await hooks['tools/pre-execute'](exec, () => Promise.resolve());
    await hooks['tools/post-execute'](exec, { value }, () => Promise.resolve({ kind: 'accept' }));
  }
  assert.deepEqual(rows.filter(r => r.outcome !== 'started').map(r => r.outcome), ['ok', 'error', 'unknown']);
  assert.equal(rows.filter(r => r.outcome === 'started').length, 5); assert(!JSON.stringify(rows).includes('PRIVATE'));
});
test('tracking tools and middleware never execute or cancel work, and do not override policy', async t => {
  const home = await mkdtemp(join(tmpdir(), 'dsh-job-plugin-')); t.after(() => rm(home, { recursive: true, force: true }));
  const tools = new Map(), hooks = {}, listeners = []; let starts = 0;
  const jobs = { events: { subscribe: (_filter, fn) => listeners.push(fn) },
    get: id => ({ ...event().job, id }), start: () => { starts++; throw new Error('must not execute'); } };
  const ctx = { get: key => key === 'jobs' ? jobs : undefined,
    tools: { register: tool => tools.set(tool.name, tool) }, on: (name, fn) => { hooks[name] = fn; } };
  const ledger = installJobTracking(ctx, tool => tool, { home, runID: RUN1 }); await ledger.ready;
  listeners[0](event());
  const exec = { name: 'job_list', agent: { id: 'session-A' } };
  const warning = await hooks['tools/post-execute'](exec, { value: [], content: [] }, async () => ({ kind: 'accept' }));
  assert.match(warning.content[0].text, /does not prove/);
  const blocked = { kind: 'block' };
  assert.equal(await hooks['tools/post-execute'](exec, {}, async () => blocked), blocked);
  for (let i = 0; i < 20; i++) await tools.get('job_status').execute({ execution_id: `${RUN1}:bash-1` }, exec);
  assert.equal(starts, 0); await ledger.flush();
});
