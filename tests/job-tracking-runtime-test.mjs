// Real packaged Bash + job registry + job controls; only the shell service is a
// local POSIX child_process adapter. No downloads, iPad, credentials, or npm install.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { JobLedger } from '../app/JobTracking.bundle/job-ledger.mjs';
import http from 'node:http';
const fixtures = resolve(process.env.DSH_JOB_FIXTURES ?? 'build/job-tracking-fixtures');
const pkg = async name => import(pathToFileURL(join(fixtures, 'node_modules/@deepseek-ai', name, 'lib/index.js')).href);
const { Context } = await pkg('cordis');
const { LocalJobRegistry } = await pkg('dsh-jobs-local');
const { apply: applyBash } = await pkg('dsh-tool-bash');
const { apply: applyJobs } = await pkg('dsh-tool-jobs');

async function fixture(t, { refuse = false, track = true, preparationDelay = 0 } = {}) {
  const home = await mkdtemp(join(tmpdir(), 'dsh-real-job-'));
  const ledger = new JobLedger(home); await ledger.ready;
  const ctx = new Context(), definitions = new Map(), children = new Set(); let spawns = 0;
  const owners = new Map(['A', 'B'].map(id => [id, { id, session: { id, header: { cwd: process.cwd() } }, ctx: new Context(), status: 'busy' }]));
  ctx.provide('agents', { get: id => owners.get(id) });
  ctx.provide('systemPrompt', { section() {}, getSectionOrder() { return 1; } });
  ctx.provide('tools', { register(tool) { definitions.set(tool.name, tool); return () => definitions.delete(tool.name); } });
  ctx.provide('shellEnv', { collect: () => ({}) });
  const shell = {
    resolve: request => ({ ...request, timeoutMs: Math.min(request.timeoutMs ?? 25, 600000), onExpiry: request.onExpiry ?? 'kill' }),
    execute: async spec => {
      if (preparationDelay) await new Promise((resolve, reject) => {
        const timer = setTimeout(resolve, preparationDelay);
        spec.signal?.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('preparation aborted')); }, { once: true });
      });
      spawns++;
      const child = spawn('/bin/sh', ['-c', spec.command], { cwd: spec.workdir, stdio: ['ignore', 'pipe', 'pipe'] });
      children.add(child);
      const output = { stdout: '', stderr: '' };
      child.stdout.on('data', bytes => { output.stdout += bytes.toString(); });
      child.stderr.on('data', bytes => { output.stderr += bytes.toString(); });
      const proc = { status: 'running', exitCode: null, signal: null,
        observed: Object.fromEntries(['stdout', 'stderr'].map(channel => [channel, {
          readFrom: offset => ({ text: output[channel].slice(offset), nextOffset: output[channel].length, lossy: false }) }])),
        kill: () => child.kill('SIGTERM') };
      let timedOut = false;
      const timer = spec.onExpiry === 'none' ? null : setTimeout(() => { timedOut = true; proc.kill(); }, spec.timeoutMs);
      spec.signal?.addEventListener('abort', () => proc.kill(), { once: true });
      proc.done = new Promise((done, reject) => {
        child.once('error', reject);
        child.once('close', (code, signal) => { clearTimeout(timer); children.delete(child);
          proc.status = signal ? 'killed' : 'completed'; proc.exitCode = code; proc.signal = signal; done(); });
      });
      proc.result = async () => { await proc.done; return { exitCode: proc.exitCode, signal: proc.signal,
        timedOut, aborted: spec.signal?.aborted ?? false, timeoutMs: spec.timeoutMs,
        stdout: { text: output.stdout, truncated: false }, stderr: { text: output.stderr, truncated: false } }; };
      return proc;
    },
  };
  ctx.provide('shell', shell);
  new LocalJobRegistry(ctx, { maxConcurrentJobsPerOwner: 10, retainBytes: 65536, settledRetainBytes: 4096, pumpPollMs: 2 });
  const jobs = ctx.get('jobs'); if (track) jobs.events.subscribe({ owners: 'scope' }, e => ledger.observe(e));
  applyJobs(ctx, {}); applyBash(ctx, {});
  await new Promise(resolve => setTimeout(resolve, 5));
  assert(definitions.has('bash')); assert(definitions.has('job_output'));
  if (refuse) jobs.start = () => { throw new Error('controlled registration refusal'); };
  const exec = owner => ({ name: 'bash', agent: owners.get(owner), signal: new AbortController().signal,
    callId: 'fixture-call', workspace: process.cwd() });
  const call = (name, args, owner = 'A', context) => definitions.get(name).execute(args, context ?? exec(owner));
  t.after(async () => { await jobs.disposeAll(); await ledger.flush();
    for (const child of children) child.kill('SIGTERM');
    assert.equal(children.size, 0, 'no child process may be left behind');
    await rm(home, { recursive: true, force: true }); });
  return { jobs, ledger, call, exec, ctx, home, owners, spawns: () => spawns };
}
const command = (delay, code = 0) => `exec '${process.execPath}' -e 'setTimeout(()=>{console.log("unauthorized fixture");process.exit(${code})},${delay})'`;
const args = (delay, code, more = {}) => ({ command: command(delay, code), description: 'Run controlled local child', workdir: process.cwd(), ...more });

test('actual foreground wait timeout promotes same running process, then records real exit zero', async t => {
  const f = await fixture(t);
  const result = await f.call('bash', args(150, 0, { timeoutMs: 20 }));
  assert.equal(result.kind, 'promoted'); assert.equal(f.spawns(), 1);
  assert.equal(f.jobs.get(result.jobId, 'A').status, 'running');
  const end = await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 1000 });
  assert.equal(end.job.status, 'completed'); assert.match(end.job.detail, /^exit code: 0/);
  assert.equal(f.spawns(), 1); assert.equal((await f.ledger.list('A')).records[0].state, 'succeeded');
});
test('actual explicit background task survives short job_output wait and returns nonzero truthfully', async t => {
  const f = await fixture(t);
  const result = await f.call('bash', args(150, 7, { run_in_background: true, timeoutMs: 1 }));
  assert.equal(result.kind, 'background');
  const waiting = await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 10 });
  assert.equal(waiting.job.status, 'running'); assert.equal(f.spawns(), 1);
  const end = await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 1000 });
  assert.match(end.job.detail, /^exit code: 7/); assert.equal((await f.ledger.list('A')).records[0].state, 'failed');
});
test('actual finished job remains listed and repeated output queries never repeat execution', async t => {
  const f = await fixture(t); const result = await f.call('bash', args(30, 3, { run_in_background: true }));
  await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 1000 });
  for (let i = 0; i < 20; i++) await f.call('job_output', { job_id: result.jobId });
  const list = await f.call('job_list', {}); assert.equal(list.length, 1); assert.equal(list[0].status, 'completed');
  assert.equal(f.spawns(), 1);
});
test('actual registry enforces cross-session visibility', async t => {
  const f = await fixture(t); const result = await f.call('bash', args(60, 0, { run_in_background: true }));
  assert.deepEqual(await f.call('job_list', {}, 'B'), []);
  await assert.rejects(f.call('job_output', { job_id: result.jobId }, 'B'), /another session/);
  assert.deepEqual((await f.ledger.list('B')).records, []);
  await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 1000 });
});
test('actual registration refusal is foreground fallback, never a fake background job', async t => {
  const f = await fixture(t, { refuse: true });
  const result = await f.call('bash', args(150, 0, { timeoutMs: 20 }));
  assert.equal(result.kind, 'foreground'); assert.equal(result.timedOut, true);
  assert.equal(result.signal, 'SIGTERM'); assert.equal(result.jobId, undefined); assert.equal(f.spawns(), 1);
  assert.deepEqual((await f.ledger.list('A')).records, []);
});
test('explicit background registration refusal executes nothing', async t => {
  const f = await fixture(t, { refuse: true });
  await assert.rejects(f.call('bash', args(20, 0, { run_in_background: true })), /registration refusal/);
  assert.equal(f.spawns(), 0);
});

test('timeout before process creation is not falsely promoted or marked successful', async t => {
  const f = await fixture(t, { preparationDelay: 200 });
  const result = await f.call('bash', args(10, 0, { timeoutMs: 20 }));
  assert.equal(result.kind, 'foreground'); assert.equal(result.timedOut, true);
  assert.equal(result.jobId, undefined); assert.equal(f.spawns(), 0);
  assert.equal((await f.ledger.list('A')).records[0].state, 'unknown');
});
test('actual job cancellation records a signal, not success', async t => {
  const f = await fixture(t); const result = await f.call('bash', args(1000, 0, { run_in_background: true }));
  await new Promise(resolve => setTimeout(resolve, 20));
  await f.call('job_kill', { job_id: result.jobId, reason: 'controlled test cancellation' });
  const end = await f.call('job_output', { job_id: result.jobId, wait: true, timeout_ms: 1000 });
  assert.equal(end.job.status, 'killed'); assert.match(end.job.detail, /SIGTERM/);
  assert.equal((await f.ledger.list('A')).records[0].state, 'interrupted');
});

test('actual owner teardown removes live registry entry but retains interrupted metadata', async t => {
  const f = await fixture(t); const result = await f.call('bash', args(1000, 0, { run_in_background: true }));
  await new Promise(resolve => setTimeout(resolve, 20));
  await f.jobs.disposeOwned(f.owners.get('A'));
  assert.deepEqual(await f.call('job_list', {}), []);
  const record = (await f.ledger.list('A')).records[0];
  assert.equal(record.state, 'interrupted'); assert.equal(record.removed, true);
  assert.equal(record.job_id, result.jobId);
});

test('actual foreground call cancellation is distinct from a wait timeout', async t => {
  const f = await fixture(t); const controller = new AbortController();
  const context = { ...f.exec('A'), signal: controller.signal };
  const pending = f.call('bash', args(1000, 0, { timeoutMs: 500 }), 'A', context);
  setTimeout(() => controller.abort(), 30);
  await assert.rejects(pending, /aborted/);
  assert.deepEqual(await f.call('job_list', {}), []);
  assert.equal((await f.ledger.list('A')).records[0].state, 'interrupted');
});

test('pinned patched bridge runs through real Cordis hooks and reports exit evidence without command contents', async t => {
  const f = await fixture(t, { track: false }); await f.ledger.flush();
  const rows = [];
  const server = http.createServer((request, response) => {
    let text = '';
    request.on('data', bytes => { text += bytes; });
    request.on('end', () => {
      assert.equal(request.url, '/v1/activity');
      rows.push(...JSON.parse(text).events);
      response.setHeader('content-type', 'application/json'); response.end('{"accepted":1}');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const before = Object.fromEntries(['DSH_HOST_BRIDGE_URL', 'DSH_HOST_BRIDGE_TOKEN', 'DSH_HOME'].map(k => [k, process.env[k]]));
  process.env.DSH_HOST_BRIDGE_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.DSH_HOST_BRIDGE_TOKEN = 'controlled-fixture-not-a-credential'; process.env.DSH_HOME = f.home;
  t.after(() => { for (const [key, value] of Object.entries(before)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  } });
  const bridge = await import(pathToFileURL(join(fixtures, 'bridge-patched.mjs')).href);
  bridge.apply(f.ctx);
  const exec = f.exec('A');
  await f.ctx.waterfall('tools/pre-execute', exec, async () => ({ kind: 'allow' }));
  const value = await f.call('bash', args(100, 8, { run_in_background: true }));
  const decision = await f.ctx.waterfall('tools/post-execute', exec, { value, isError: false, content: [] }, async () => ({ kind: 'accept' }));
  assert.match(decision.content.at(-1).text, /execution_id=/);
  await f.call('job_output', { job_id: value.jobId, wait: true, timeout_ms: 1000 });
  const deadline = Date.now() + 3000;
  while (!rows.some(row => row.name === 'background_job' && row.outcome === 'error') && Date.now() < deadline)
    await new Promise(resolve => setTimeout(resolve, 25));
  assert(rows.some(row => row.name === 'bash' && row.outcome === 'started'));
  assert(rows.some(row => row.name === 'background_job' && row.outcome === 'error'));
  assert(!JSON.stringify(rows).includes('unauthorized fixture'));
  assert(!JSON.stringify(rows).includes('controlled-fixture-not-a-credential'));
  let history = JSON.parse(await f.call('job_history', {}));
  while (history.pending_writes && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 5));
    history = JSON.parse(await f.call('job_history', {}));
  }
  assert.equal(history.persistence, 'available'); assert.equal(history.pending_writes, false);
  assert.equal(history.records.at(-1).state, 'failed'); assert.equal(history.records.at(-1).exit_code, 8);
  const saved = JSON.parse(await readFile(join(f.home, '.job-history/v1.json'), 'utf8'));
  assert(saved.records.some(record => record.job_id === value.jobId && record.state === 'failed' && record.exit_code === 8));
  const status = JSON.parse(await f.call('job_status', { execution_id: history.records.at(-1).execution_id }));
  assert.equal(status.record.state, 'failed'); assert.equal(f.spawns(), 1);
});
