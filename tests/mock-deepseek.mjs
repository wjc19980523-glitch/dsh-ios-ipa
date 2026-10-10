// Minimal DeepSeek server used by the rootfs tests.
//
// Two wire protocols are served, because the guest's dsh changed shape:
//
//   POST /v1/messages          Anthropic-style Messages API (dsh 0.2.x)
//   POST /v1/chat/completions  OpenAI-style chat completions (dsh 0.1.x)
//
// dsh 0.2.x replaced the OpenAI adapter with "DeepSeek Messages": it resolves
// `${baseURL}/v1` and POSTs to `/messages`, streams Anthropic SSE
// (message_start / content_block_start / content_block_delta / message_stop)
// and puts tools on the wire as `input_schema`. Serving only the old path made
// every LLM round trip fail with HTTP_404 while the rest of the image was
// healthy, so this file now speaks both. The old path is kept so the same stub
// can still exercise an 0.1.x guest.
//
// Either way the point is the same: stream a fixed reply as SSE so the guest's
// undici fetch path (the WebAssembly-less llhttp polyfill) is exercised end to
// end, and so a tool round trip can be driven without a real API key.
//
// Usage: node tests/mock-deepseek.mjs [port]   (default 3199)
import http from 'node:http';

const port = Number(process.argv[2] ?? 3199);
const REPLY = 'MOCK-REPLY-7f3a: hello from the mock DeepSeek server';
// With --tool <name>, the first completion asks for that tool and the second
// reports what came back, so a whole tool round trip can be tested headlessly.
// --tool-args '<json>' supplies its arguments (default '{}').
const toolFlag = process.argv.indexOf('--tool');
const TOOL = toolFlag > 0 ? process.argv[toolFlag + 1] : null;
// Tools with required parameters (health_query's `metric`) need real arguments.
const argsFlag = process.argv.indexOf('--tool-args');
const TOOL_ARGS = argsFlag > 0 ? process.argv[argsFlag + 1] : '{}';

const SERVER_ID = 'msg_mock_1';

// ---------------------------------------------------------------------------
// Anthropic-style Messages API (dsh 0.2.x)
// ---------------------------------------------------------------------------

/** Frame one SSE event the way the Messages API does: named event + JSON data. */
const sseEvent = (type, payload) =>
  `event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`;

/**
 * Walk a Messages request and report the tool result, if the conversation
 * already carries one. dsh 0.2.x sends tool output back as a `tool_result`
 * block inside a `user` message, not as a message with role `tool`.
 */
function findMessagesToolResult(messages) {
  for (const message of [...messages].reverse()) {
    for (const block of message.content ?? []) {
      if (block?.type === 'tool_result') return block;
    }
  }
  return null;
}

/** Flatten a tool_result block's content into the text the test greps for. */
function toolResultText(block) {
  if (typeof block.content === 'string') return block.content;
  if (Array.isArray(block.content)) {
    return block.content
      .map((part) => (typeof part === 'string' ? part : part?.text ?? JSON.stringify(part)))
      .join(' ');
  }
  return JSON.stringify(block.content ?? {});
}

function serveMessages(req, res, payload) {
  const model = payload.model ?? 'deepseek-chat';
  const tools = payload.tools ?? [];
  const usage = (out) => ({
    input_tokens: 10,
    output_tokens: out,
    cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0,
  });

  const start = (inputTokens = 10) => {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    });
    res.write(sseEvent('message_start', {
      message: { id: SERVER_ID, type: 'message', role: 'assistant', model, content: [], usage: usage(0) },
    }));
  };

  // A text-only reply: one text block, streamed word by word so the guest
  // really has to reassemble deltas rather than read one blob.
  const streamText = (text, stopReason = 'end_turn') => {
    start(10);
    res.write(sseEvent('content_block_start', {
      index: 0,
      content_block: { type: 'text', text: '' },
    }));
    for (const word of text.split(' ')) {
      res.write(sseEvent('content_block_delta', {
        index: 0,
        delta: { type: 'text_delta', text: word + ' ' },
      }));
    }
    res.write(sseEvent('content_block_stop', { index: 0 }));
    res.write(sseEvent('message_delta', {
      delta: { stop_reason: stopReason, stop_sequence: null },
      usage: usage(12),
    }));
    res.write(sseEvent('message_stop', {}));
    res.end();
  };

  if (TOOL) {
    console.log('[mock] tools offered:',
      tools.map((t) => t.name ?? t.function?.name).join(', ') || '(none)');
    const result = findMessagesToolResult(payload.messages ?? []);
    if (result) console.log('[mock] tool_result:', JSON.stringify(result).slice(0, 400));
    const offers = tools.some((t) => (t.name ?? t.function?.name) === TOOL);

    // Ask for the tool on every turn that has not yet seen its result, so one
    // mock process behaves identically for repeated runs.
    if (!result && offers) {
      start(20);
      res.write(sseEvent('content_block_start', {
        index: 0,
        content_block: { type: 'tool_use', id: 'toolu_mock_1', name: TOOL, input: {} },
      }));
      // Ship the arguments as a partial-JSON delta, which is the shape a real
      // provider uses and the shape the translator accumulates.
      res.write(sseEvent('content_block_delta', {
        index: 0,
        delta: { type: 'input_json_delta', partial_json: TOOL_ARGS },
      }));
      res.write(sseEvent('content_block_stop', { index: 0 }));
      res.write(sseEvent('message_delta', {
        delta: { stop_reason: 'tool_use', stop_sequence: null },
        usage: usage(5),
      }));
      res.write(sseEvent('message_stop', {}));
      res.end();
      return;
    }

    const observed = result ? toolResultText(result) : '{}';
    streamText(`TOOL-RESULT-BEGIN ${observed.slice(0, 800)} TOOL-RESULT-END`);
    return;
  }

  streamText(REPLY);
}

// ---------------------------------------------------------------------------
// OpenAI-style chat completions (dsh 0.1.x, kept for the older guest shape)
// ---------------------------------------------------------------------------

function serveChatCompletions(res, payload) {
  const id = 'chatcmpl-mock';
  const model = payload.model ?? 'deepseek-chat';
  const chunk = (delta, finish = null) => `data: ${JSON.stringify({
    id, object: 'chat.completion.chunk', created: 1700000000, model,
    choices: [{ index: 0, delta, finish_reason: finish }],
  })}\n\n`;

  // Tool mode: first turn asks for the tool, later turns quote its result.
  if (TOOL) {
    const messages = payload.messages ?? [];
    console.log('[mock] tools offered:',
      (payload.tools ?? []).map((t) => t.function?.name ?? t.name).join(', ') || '(none)');
    const lastTool = [...messages].reverse().find((m) => m.role === 'tool');
    if (lastTool) console.log('[mock] tool message:', JSON.stringify(lastTool).slice(0, 400));
    const toolResult = [...messages].reverse().find((m) => m.role === 'tool');
    const offers = (payload.tools ?? []).some((t) => (t.function?.name ?? t.name) === TOOL);
    // Ask for the tool until its result comes back in the conversation, so
    // repeated runs against one mock process behave identically.
    if (!toolResult && offers) {
      const call = { index: 0, id: 'call_mock_1', type: 'function', function: { name: TOOL, arguments: TOOL_ARGS } };
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      res.write(chunk({ role: 'assistant', content: '', tool_calls: [call] }));
      res.write(chunk({}, 'tool_calls'));
      res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1700000000, model, choices: [], usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 } })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
      return;
    }
    const observed = typeof toolResult?.content === 'string' ? toolResult.content : JSON.stringify(toolResult?.content ?? {});
    const text = `TOOL-RESULT-BEGIN ${observed.slice(0, 800)} TOOL-RESULT-END`;
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(chunk({ role: 'assistant', content: '' }));
    for (const word of text.split(' ')) res.write(chunk({ content: word + ' ' }));
    res.write(chunk({}, 'stop'));
    res.write('data: [DONE]\n\n');
    res.end();
    return;
  }

  if (payload.stream === false) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      id, object: 'chat.completion', created: 1700000000, model,
      choices: [{ index: 0, message: { role: 'assistant', content: REPLY }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 10, completion_tokens: 12, total_tokens: 22 },
    }));
    return;
  }
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });
  res.write(chunk({ role: 'assistant', content: '' }));
  const words = REPLY.split(' ');
  let i = 0;
  const timer = setInterval(() => {
    if (i < words.length) {
      res.write(chunk({ content: (i ? ' ' : '') + words[i++] }));
    } else {
      clearInterval(timer);
      res.write(chunk({}, 'stop'));
      res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1700000000, model, choices: [], usage: { prompt_tokens: 10, completion_tokens: 12, total_tokens: 22 } })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    }
  }, 20);
}

// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const url = (req.url ?? '').split('?')[0];
    if (req.method === 'GET' && url.endsWith('/models')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ object: 'list', data: [{ id: 'deepseek-chat', object: 'model' }] }));
      return;
    }
    if (req.method !== 'POST') {
      res.writeHead(404); res.end('not found'); return;
    }
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch { /* ignore */ }

    if (url.endsWith('/messages')) {
      serveMessages(req, res, payload);
      return;
    }
    if (url.endsWith('/chat/completions')) {
      serveChatCompletions(res, payload);
      return;
    }
    // Say what arrived: a silent 404 here once cost a full round of debugging.
    console.log('[mock] 404 for', req.method, url);
    res.writeHead(404); res.end('not found');
  });
});

// Bind all interfaces when asked (--lan), so a device on the same network can
// reach it for on-device end-to-end tests; loopback only by default.
const host = process.argv.includes('--lan') ? '0.0.0.0' : '127.0.0.1';
server.listen(port, host, () => {
  console.log(`mock-deepseek listening on http://${host}:${port}`);
});
