// Use the pinned rootfs's actual ToolRuntime, message factory and DeepSeek
// adapter. Only the HTTP peer is a local strict protocol fixture; no API key.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, realpath, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { captureBridgeLedger, cleanupJobTrackingFixture, closeFixtureServer } from './job-tracking-cleanup.mjs';

const fixtures = resolve(process.env.DSH_JOB_FIXTURES ?? 'build/job-tracking-fixtures');
const pkg = name => import(pathToFileURL(join(fixtures, 'node_modules/@deepseek-ai', name, 'lib/index.js')).href);
const { Context } = await pkg('cordis');
const { ToolRuntime, defineTool } = await pkg('dsh-tools');
const { SystemPrompt } = await pkg('dsh-system-prompt');
const { LocalJobRegistry } = await pkg('dsh-jobs-local');
const { apply: applyJobs } = await pkg('dsh-tool-jobs');
const { createUserMessage, createAssistantMessage, createToolResultMessage } = await pkg('dsh-llm');
const { DeepSeekAdapter, resolveAdapterOptions } = await pkg('dsh-llm-deepseek');
const MODEL = 'deepseek-flash'; // Packaged catalog: DeepSeek V4.1 Flash.
const RUN = '11111111-1111-4111-8111-111111111111';

function invalidText(value, path = 'body') {
  if (!value || typeof value !== 'object') return null;
  if (value.type === 'text' && typeof value.text !== 'string') return `${path}.text`;
  for (const [key, child] of Object.entries(value)) {
    const invalid = invalidText(child, `${path}.${key}`);
    if (invalid) return invalid;
  }
  return null;
}

async function fixture(t) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'dsh-render-chain-')));
  const requests = [], nativeRequests = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks)) : {};
    res.setHeader('content-type', 'application/json');
    if (req.url === '/v1/messages') {
      requests.push(body);
      const bad = invalidText(body);
      if (bad) {
        res.writeHead(400);
        res.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error',
          message: `INVALID_REQUEST: ${bad}: invalid type: map, expected a string` } }));
        return;
      }
      res.setHeader('content-type', 'text/event-stream');
      const event = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
      event('message_start', { message: { id: 'fixture-response', type: 'message', role: 'assistant', model: MODEL,
        content: [], usage: { input_tokens: 1, output_tokens: 0 } } });
      event('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: 'continued after tool' } });
      event('content_block_stop', { index: 0 });
      event('message_delta', { delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } });
      event('message_stop', {});
      res.end();
      return;
    }
    nativeRequests.push({ path: req.url, body });
    const values = {
      '/v1/device': { systemVersion: 'fixture-iPad' },
      '/v1/files/import': { name: 'snake.txt', bytes: 5, base64: Buffer.from('snake').toString('base64') },
      '/v1/files/export': { name: body.name, bytes: Buffer.from(body.base64 ?? '', 'base64').length },
      '/v1/activity': { accepted: body.events?.length ?? 0 },
    };
    if (!Object.hasOwn(values, req.url)) { res.writeHead(404); res.end('{}'); return; }
    res.end(JSON.stringify(values[req.url]));
  });
  const ctx = new Context();
  new SystemPrompt(ctx, {}); new ToolRuntime(ctx, {});
  const agent = { id: 'A', ctx: new Context(), session: { id: 'A', header: { cwd: home } }, status: 'busy' };
  ctx.provide('agents', { get: id => id === 'A' ? agent : undefined });
  new LocalJobRegistry(ctx, {});
  const jobs = ctx.get('jobs');
  const envKeys = ['DSH_HOST_BRIDGE_URL', 'DSH_HOST_BRIDGE_TOKEN', 'DSH_HOME', 'DSH_WORKSPACE'];
  const before = Object.fromEntries(envKeys.map(key => [key, process.env[key]]));
  let ledger;
  t.after(() => cleanupJobTrackingFixture({ jobs, ctx, ledger, trackingLedger: ledger,
    remove: () => rm(home, { recursive: true, force: true }),
    closeServer: () => closeFixtureServer(server),
    restoreEnvironment: () => {
      for (const [key, value] of Object.entries(before)) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
    },
  }));
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const baseURL = `http://127.0.0.1:${server.address().port}`;
  process.env.DSH_HOST_BRIDGE_URL = baseURL;
  process.env.DSH_HOST_BRIDGE_TOKEN = 'local-fixture-only';
  process.env.DSH_HOME = home;
  process.env.DSH_WORKSPACE = home;
  const bridge = await import(pathToFileURL(join(fixtures, 'bridge-patched.mjs')).href + `?chain=${encodeURIComponent(home)}`);
  captureBridgeLedger(ctx, () => bridge.apply(ctx), value => { ledger = value; });
  applyJobs(ctx, {});
  await ledger.ready;
  const adapter = new DeepSeekAdapter({
    options: () => resolveAdapterOptions({ baseURL, reasoningEffort: 'high', streamIdleTimeoutMs: 3000,
      models: [{ id: MODEL, systemPromptUpdate: 'in-history', toolUpdate: 'addition-only' }] }),
    resolveAuth: async () => ({ headers: {} }), resolveUserId: () => 'local-fixture',
    prepareExtensions: async () => ({ fields: {}, accept: async () => {} }),
  });
  const execute = (name, args, owner = agent) => ctx.get('tools').execute({ name, arguments: args,
    callId: `call-${name}`, signal: AbortSignal.timeout(5000), agent: owner, workspace: home });
  async function send(name, args, result) {
    // This is the same exported factory and field mapping used by
    // dsh-agent-loop appendToolResult, with no replacement serializer.
    const toolMessage = createToolResultMessage({ callId: `call-${name}`, content: result.content, isError: result.isError });
    const messages = [
      createUserMessage({ content: [{ type: 'text', text: '开发贪吃蛇 IPA' }], source: { kind: 'user' } }),
      createAssistantMessage({ content: [{ type: 'tool-call', id: `call-${name}`, name, arguments: JSON.stringify(args) }],
        source: { provider: 'deepseek', model: MODEL } }), toolMessage,
    ];
    const chunks = [];
    for await (const chunk of adapter.stream({ provider: 'deepseek', model: MODEL, reasoningEffort: 'high',
      messages, signal: AbortSignal.timeout(5000) })) chunks.push(chunk);
    assert(chunks.length > 0, 'the next model response must actually be consumed');
    const body = requests.at(-1);
    assert.equal(body.output_config.effort, 'high'); assert.equal(body.model, MODEL);
    assert.equal(invalidText(body), null);
    const wireResult = body.messages[2].content.find(block => block.type === 'tool_result');
    assert(wireResult); assert.equal(wireResult.tool_use_id, `call-${name}`);
    assert.deepEqual(wireResult.content, result.content, 'serialization must retain the execution result, not arguments');
    return { body, toolMessage };
  }
  return { ctx, jobs, ledger, agent, home, execute, send, requests, nativeRequests };
}

for (const [name, args] of [
  ['development_preflight', { target: 'native-ios' }],
  ['job_history', {}],
  ['job_status', { execution_id: `${RUN}:bash-999` }],
]) {
  test(`${name}: real execution -> render -> message -> DeepSeek High request`, async t => {
    const f = await fixture(t), result = await f.execute(name, args);
    assert.equal(result.isError, false);
    await f.send(name, args, result); // Old Build 30 reaches the server and fails here.
    assert.equal(typeof result.value, 'string');
    assert.deepEqual(result.content, [{ type: 'text', text: result.value }]);
    assert.notDeepEqual(JSON.parse(result.value), args, 'must render the output, never JSON-stringified input');
  });
}

for (const [name, args] of [
  ['development_preflight', { target: 'native-ios' }], ['job_history', {}],
  ['job_status', { execution_id: `${RUN}:bash-999` }],
]) {
  test(`${name}: old single-argument renderer is rejected by the wire contract`, async t => {
    const f = await fixture(t), negative = `old_${name}`;
    f.ctx.tools.register(defineTool({ name: negative, description: 'negative control',
      parameters: Object.fromEntries(Object.keys(args).map(key => [key, { type: 'string' }])),
      output: { schema: { type: 'string' }, render: value => [{ type: 'text', text: value }] },
      execute: async () => 'actual-tool-result',
    }));
    const result = await f.execute(negative, args);
    assert.equal(result.isError, false); assert.deepEqual(result.content[0].text, args);
    await assert.rejects(f.send(negative, args, result), /invalid type: map, expected a string/);
    assert.equal(f.requests.length, 1); assert(invalidText(f.requests[0]));
  });
}

test('history and status preserve the execution outcome and session ownership through serialization', async t => {
  const f = await fixture(t);
  f.ledger.observe({ type: 'registered', job: { id: 'bash-1', owner: 'A', kind: 'bash', status: 'running' } });
  f.ledger.observe({ type: 'settled', job: { id: 'bash-1', owner: 'A', kind: 'bash', status: 'completed', detail: 'exit code: 7' } });
  await f.ledger.flush();
  const history = await f.execute('job_history', {});
  await f.send('job_history', {}, history);
  const record = JSON.parse(history.value).records[0];
  assert.equal(record.state, 'failed'); assert.equal(record.exit_code, 7);
  const args = { execution_id: record.execution_id };
  const status = await f.execute('job_status', args); await f.send('job_status', args, status);
  assert.equal(JSON.parse(status.value).record.state, 'failed');
  const other = { ...f.agent, id: 'B' };
  const hidden = await f.execute('job_status', args, other); await f.send('job_status', args, hidden);
  assert.equal(JSON.parse(hidden.value).record, null);
  const persisted = await readFile(join(f.home, '.job-history/v1.json'), 'utf8');
  assert(persisted.includes(record.execution_id));
});

test('invalid arguments and execution errors also serialize as strings', async t => {
  const f = await fixture(t);
  for (const [name, args] of [['development_preflight', { target: 'invalid' }],
    ['job_status', {}], ['job_status', { execution_id: 'x'.repeat(101) }],
    ['job_output', { job_id: 'bash-999' }]]) {
    const result = await f.execute(name, args); assert.equal(result.isError, true);
    await f.send(name, args, result);
  }
});

for (const [name, args, expected] of [
  ['device_info', {}, 'fixture-iPad'],
  ['file_import', {}, 'snake.txt'],
  ['file_export', { name: 'snake.txt', base64: Buffer.from('snake').toString('base64') }, 'snake.txt'],
]) {
  test(`${name}: original bridge tool still executes, renders and serializes`, async t => {
    const f = await fixture(t), result = await f.execute(name, args);
    assert.equal(result.isError, false); await f.send(name, args, result);
    assert(result.content.some(block => block.text.includes(expected)));
    assert(f.nativeRequests.some(request => request.path !== '/v1/activity'));
  });
}

test('original job_list retains its output and tracking notice through the real runtime', async t => {
  const f = await fixture(t), result = await f.execute('job_list', {});
  assert.equal(result.isError, false); assert.deepEqual(result.value, []);
  await f.send('job_list', {}, result);
  assert(result.content.some(block => block.text.includes('[DSH task tracking]')));
});

test('workspace export refusal survives the complete chain without a native transfer', async t => {
  const f = await fixture(t), args = { path: '/root/.ssh/id_ed25519' };
  const result = await f.execute('file_export_from_workspace', args);
  assert.equal(result.isError, false); await f.send('file_export_from_workspace', args, result);
  const value = JSON.parse(result.value);
  assert.equal(value.saved, false); assert.equal(value.reason, 'file_outside_current_workspace');
  assert.deepEqual(result.content, [{ type: 'text', text: result.value }]);
  assert(!f.nativeRequests.some(request => request.path.startsWith('/v1/files/workspace-export/')));
});
