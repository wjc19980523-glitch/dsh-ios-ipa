// Actual POSIX filesystem + loopback binary HTTP transfer; UIKit picker results
// are controlled protocol fixtures, never represented as iPad acceptance.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { constants } from 'node:fs';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, symlink, link, lstat, realpath, open, appendFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exportWorkspace, openWorkspaceFile, installWorkspaceExport, WORKSPACE_EXPORT_CHUNK_BYTES, WORKSPACE_EXPORT_MAX_BYTES } from '../app/JobTracking.bundle/workspace-export.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const TOKEN = 'bridge-credential-sentinel-not-for-output';
const SESSION = randomUUID();
async function fixture(t, config = {}) {
  const directory = await realpath(await mkdtemp(join(tmpdir(), 'dsh-workspace-export-')));
  const root = join(directory, 'workspace'), home = join(directory, 'home');
  await mkdir(root); await mkdir(home);
  const path = join(root, config.name ?? 'sample.ipa');
  const bytes = config.bytes ?? randomBytes(45306);
  await writeFile(path, bytes);
  const controller = new AbortController();
  const exec = { agent: { id: 'fixture-session', session: { header: { cwd: root } } }, signal: controller.signal };
  const events = [], sessions = new Map();
  let native, created = 0, chunkCalls = 0, committed = 0, statusCalls = 0, maxChunk = 0, cancelled = 0, pending = config.pending ?? 0;
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.headers.authorization, `Bearer ${TOKEN}`);
      const action = request.url.split('/').at(-1);
      let chunks = [], received = 0;
      for await (const chunk of request) { received += chunk.length; assert(received <= WORKSPACE_EXPORT_CHUNK_BYTES + 8192); chunks.push(chunk); }
      const data = Buffer.concat(chunks);
      events.push({ action, method: request.method, bytes: data.length, session_in_url: request.url.includes(SESSION) });
      if (config.errorStatus) { response.writeHead(config.errorStatus); response.end(JSON.stringify({ error: { code: config.errorCode, message: TOKEN + SESSION } })); return; }
      if (action === 'start') {
        assert.equal(request.method, 'POST');
        const metadata = JSON.parse(data);
        events.at(-1).request_id = metadata.request_id;
        assert.equal(metadata.workspace, root); assert.equal(metadata.source, path);
        assert.equal(metadata.bytes, bytes.length); assert.equal(metadata.sha256, digest(bytes));
        if (!sessions.has(metadata.request_id)) {
          created++; native = { ...metadata, session_id: SESSION, max_chunk_bytes: WORKSPACE_EXPORT_CHUNK_BYTES,
            offset: 0, state: pending ? 'pending_confirmation' : 'receiving', saved: false, parts: [], prior: null };
          sessions.set(metadata.request_id, native);
        } else assert.deepEqual(Object.fromEntries(Object.keys(metadata).map(key => [key, native[key]])), metadata);
        if (config.loseStart) { config.loseStart = false; response.destroy(); return; }
      } else {
        assert.equal(request.headers['x-dsh-export-session'], SESSION);
        assert.equal(request.headers['x-dsh-export-scope'], digest(exec.agent.id));
        if (action === 'status') {
          assert.equal(request.method, 'GET'); statusCalls++;
          if (config.unknownStatus) { config.unknownStatus--; response.writeHead(404); response.end('{"error":{"code":"unknown_session"}}'); return; }
          if (config.loseStatus) { config.loseStatus--; response.destroy(); return; }
          if (native.state === 'pending_confirmation' && --pending <= 0) native.state = config.decline ? 'cancelled' : 'receiving';
          else if (native.state === 'ready') native.state = 'saving';
          else if (native.state === 'saving') { native.state = config.pickerCancel ? 'cancelled' : 'saved'; native.saved = !config.pickerCancel; }
        } else if (action === 'chunk') {
          assert.equal(request.method, 'PUT'); assert.equal(request.headers['content-type'], 'application/octet-stream');
          assert.equal(Number(request.headers['content-length']), data.length); assert(data.length <= WORKSPACE_EXPORT_CHUNK_BYTES);
          maxChunk = Math.max(maxChunk, data.length); chunkCalls++;
          const offset = Number(request.headers['x-dsh-export-offset']);
          assert.equal(request.headers['x-dsh-export-sha256'], digest(data));
          if (config.loseBeforeChunk) { config.loseBeforeChunk = false; response.destroy(); return; }
          if (offset === native.offset) {
            native.parts.push(data); native.prior = { offset, checksum: digest(data), length: data.length }; native.offset += data.length;
          } else assert.deepEqual(native.prior, { offset, checksum: digest(data), length: data.length });
          if (config.onChunk) await config.onChunk({ path, native, controller, chunkCalls });
          if (config.badOffset) native.offset--;
          if (config.loseChunk) { config.loseChunk = false; response.destroy(); return; }
        } else if (action === 'finish') {
          assert.equal(request.method, 'POST'); committed++;
          assert.equal(native.offset, bytes.length);
          if (digest(Buffer.concat(native.parts)) !== digest(bytes)) { native.state = 'failed'; native.error_code = 'checksum_mismatch'; }
          else native.state = 'ready';
          if (config.loseFinish) { config.loseFinish = false; response.destroy(); return; }
        } else if (action === 'cancel') {
          assert.equal(request.method, 'POST'); cancelled++; native.state = 'cancelled'; native.saved = false;
        } else throw new Error('unexpected action');
      }
      const { parts, prior, ...value } = native;
      if (config.badSaved && value.state === 'saved') value.saved = false;
      if (config.missingSaveMetadata && value.state === 'saved') delete value.sha256;
      if (config.oversizedResponse) value.padding = 'x'.repeat(20000);
      response.writeHead(200, { 'content-type': 'application/json' });
      const encoded = Buffer.from(JSON.stringify(value));
      // Exercise UTF8 split across metadata response chunks.
      if (config.splitUTF8) { for (const byte of encoded) response.write(Buffer.from([byte])); response.end(); }
      else response.end(encoded);
    } catch (error) { response.writeHead(500); response.end(JSON.stringify({ error: { code: 'internal', message: error.message } })); config.serverError = error; }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const options = { home, environment: { DSH_WORKSPACE: root, DSH_HOST_BRIDGE_URL: `http://127.0.0.1:${server.address().port}`, DSH_HOST_BRIDGE_TOKEN: TOKEN },
    requestTimeoutMs: 1500, pollMs: 2, ...config.options };
  const run = (args = { path }, override = {}) => exportWorkspace(args, exec, { ...options, ...override });
  t.after(async () => { server.closeAllConnections(); await new Promise(done => server.close(done)); await rm(directory, { recursive: true, force: true }); if (config.serverError) throw config.serverError; });
  return { directory, root, home, path, bytes, exec, controller, options, run, events, sessions,
    observed: () => ({ created, chunkCalls, committed, statusCalls, maxChunk, cancelled, native }) };
}

test('ordinary binary file crosses real HTTP octet-stream and only real saved receipt succeeds', async t => {
  const f = await fixture(t, { pending: 2, name: '游戏.ipa', splitUTF8: true });
  const result = await f.run();
  assert.deepEqual(result, { state: 'saved', saved: true, name: '游戏.ipa', bytes: f.bytes.length, sha256: digest(f.bytes) });
  assert.equal(f.observed().committed, 1); assert.equal(f.observed().created, 1);
  assert(f.events.every(e => !e.session_in_url));
  const output = JSON.stringify(result);
  assert(!output.includes(TOKEN)); assert(!output.includes(SESSION)); assert(!output.includes('base64'));
  const checkpoints = await readdir(join(f.home, '.workspace-export-v1'));
  assert.equal(checkpoints.length, 1);
  const stored = await readFile(join(f.home, '.workspace-export-v1', checkpoints[0]), 'utf8');
  assert(!stored.includes(TOKEN)); assert(!stored.includes(SESSION)); assert(!stored.includes(f.path));
});

test('binary above old 8 MiB ceiling preserves SHA256 with at most 128 KiB chunks', async t => {
  const f = await fixture(t, { bytes: randomBytes(9 * 1024 * 1024 + 37) });
  const result = await f.run();
  assert.equal(result.saved, true); assert.equal(result.sha256, digest(f.bytes));
  assert(f.observed().chunkCalls > 64); assert.equal(f.observed().maxChunk, WORKSPACE_EXPORT_CHUNK_BYTES);
  assert.equal(f.observed().native.offset, f.bytes.length);
});

test('real TapGame IPA fixture (when supplied) preserves independently known size and SHA256', async t => {
  const source = process.env.DSH_TAPGAME_IPA;
  if (!source) { t.skip('Set DSH_TAPGAME_IPA to the independently verified official artifact; synthetic samples are tested separately.'); return; }
  const bytes = await readFile(source);
  assert.equal(bytes.length, 45306); assert.equal(digest(bytes), 'e07179577a9272ca04898eb91e47730c18b5cb60490097091c2a0e2d1ecf1c4d');
  const f = await fixture(t, { bytes, name: 'TapGame_unsigned.ipa' });
  const result = await f.run(); assert.equal(result.saved, true); assert.equal(result.sha256, digest(bytes));
});

test('relative, noncanonical ../, outside-root and session-outside-root paths fail before HTTP', async t => {
  const f = await fixture(t);
  for (const path of ['sample.ipa', `${f.root}/../workspace/sample.ipa`, `${f.root}/./sample.ipa`, join(f.directory, 'outside.ipa'), `${f.root}2/file.ipa`]) {
    const result = await f.run({ path }); assert.equal(result.saved, false); assert.equal(result.state, 'refused');
  }
  f.exec.agent.session.header.cwd = f.directory;
  assert.equal((await f.run()).reason, 'workspace_outside_authorized_root'); assert.equal(f.events.length, 0);
});

test('current session subdirectory confines sibling files even inside initial workspace', async t => {
  const f = await fixture(t); const sub = join(f.root, 'project'); await mkdir(sub);
  f.exec.agent.session.header.cwd = sub;
  assert.equal((await f.run()).reason, 'file_outside_current_workspace'); assert.equal(f.events.length, 0);
});

test('sensitive directories, credentials, tokens and private key paths are denied', async t => {
  const f = await fixture(t);
  for (const name of ['.ssh/id_ed25519', '.git/config', '.env', '.dsh/config.yml', 'github-token.txt', 'credentials.json', 'signing.p12', 'id_rsa']) {
    const path = join(f.root, name); await mkdir(join(path, '..'), { recursive: true }); await writeFile(path, 'private');
    assert.equal((await f.run({ path })).reason, 'sensitive_path', name);
  }
  assert.equal(f.events.length, 0);
});

test('invalid destination names are refused before confirmation or file read', async t => {
  const f = await fixture(t);
  for (const name of ['../evil.ipa', 'folder/file.ipa', '.hidden', 'x\\y.ipa', 'x\n.ipa', 'a'.repeat(181), ' file.ipa'])
    assert.equal((await f.run({ path: f.path, name })).reason, 'invalid_export_name');
  assert.equal(f.events.length, 0);
});

test('ordinary final symlink, symlink parent, hardlink and directory are refused', async t => {
  const f = await fixture(t); const alias = join(f.root, 'alias.ipa'); await symlink(f.path, alias);
  assert.equal((await f.run({ path: alias })).saved, false);
  await mkdir(join(f.root, 'actual')); await writeFile(join(f.root, 'actual/file.ipa'), 'file');
  await symlink(join(f.root, 'actual'), join(f.root, 'linked'));
  assert.equal((await f.run({ path: join(f.root, 'linked/file.ipa') })).reason, 'unsafe_parent');
  await link(f.path, join(f.root, 'hardlink.ipa'));
  assert.equal((await f.run()).reason, 'ordinary_unlinked_file_required');
  assert.equal((await f.run({ path: join(f.root, 'actual') })).saved, false); assert.equal(f.events.length, 0);
});

test('lstat/open substitution is rejected BEFORE reading even when platform ignores O_NOFOLLOW', async t => {
  const f = await fixture(t); const secret = join(f.directory, 'private.ipa'); await writeFile(secret, 'secret-sentinel');
  let reads = 0, opened = 0;
  const io = { lstat, realpath, open: async (_path, flags) => {
    assert(flags & constants.O_NONBLOCK); opened++;
    const file = await open(secret, 'r'); const read = file.read.bind(file);
    file.read = async (...args) => { reads++; return read(...args); }; return file;
  } };
  await assert.rejects(openWorkspaceFile({ path: f.path }, f.exec, { ...f.options, io }), /source_changed_before_read/);
  assert.equal(opened, 1); assert.equal(reads, 0); assert.equal(f.events.length, 0);
});

test('empty ordinary file exports exact empty SHA without a binary chunk', async t => {
  const f = await fixture(t, { bytes: Buffer.alloc(0), name: 'empty.txt' });
  const result = await f.run(); assert.equal(result.saved, true); assert.equal(result.sha256, digest(Buffer.alloc(0)));
  assert.equal(f.observed().chunkCalls, 0); assert.equal(f.observed().committed, 1);
});

test('>512 MiB sparse file fails without transferring', async t => {
  const f = await fixture(t);
  const file = await open(f.path, 'r+'); await file.truncate(WORKSPACE_EXPORT_MAX_BYTES + 1); await file.close();
  assert.equal((await f.run()).reason, 'invalid_file_size'); assert.equal(f.events.length, 0);
});

test('lost start response reuses durable request identity without duplicate confirmation', async t => {
  const f = await fixture(t, { loseStart: true });
  assert.equal((await f.run()).saved, true); assert.equal(f.observed().created, 1);
  assert.equal(f.events.filter(e => e.action === 'start').length, 2);
});

test('lost chunk ACK queries offset and never appends accepted bytes twice', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), loseChunk: true });
  assert.equal((await f.run()).saved, true); assert.equal(f.observed().chunkCalls, 3);
  assert.equal(Buffer.concat(f.observed().native.parts).length, f.bytes.length);
});

test('dropped unaccepted chunk retries exact same offset after status verification', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), loseBeforeChunk: true });
  assert.equal((await f.run()).saved, true); assert.equal(f.observed().chunkCalls, 4);
  assert.equal(f.observed().native.parts.length, 3);
});

test('interrupted transfer resumes checkpoint and native offset without another confirmation', async t => {
  const config = { bytes: randomBytes(300000), loseChunk: true, loseStatus: 1 };
  const f = await fixture(t, config);
  const first = await f.run(); assert.equal(first.state, 'interrupted'); assert.equal(first.resumable, true); assert.equal(first.saved, false);
  const second = await f.run(); assert.equal(second.saved, true);
  assert.equal(f.observed().created, 1); assert.equal(f.observed().chunkCalls, 3); assert.equal(f.observed().committed, 1);
});

test('lost finish ACK resumes committed ready/saving state without finishing twice', async t => {
  const f = await fixture(t, { loseFinish: true });
  assert.equal((await f.run()).saved, true); assert.equal(f.observed().committed, 1);
});

test('Native app restart keeps request identity, asks again and never assumes previous save', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), loseChunk: true, unknownStatus: 1 });
  const first = await f.run(); assert.equal(first.reason, 'bridge_unknown_session'); assert.equal(first.resumable, true); assert.equal(first.saved, false);
  f.sessions.clear(); // A new app process has no prior Native session or staged file.
  const second = await f.run(); assert.equal(second.saved, true); assert.equal(f.observed().created, 2);
  const starts = f.events.filter(e => e.action === 'start'); assert.equal(starts[0].request_id, starts[1].request_id);
  assert.equal(f.observed().committed, 1);
});

test('user declines confirmation: no binary, no finish and saved false', async t => {
  const f = await fixture(t, { pending: 1, decline: true });
  const result = await f.run(); assert.equal(result.state, 'cancelled'); assert.equal(result.saved, false);
  assert.equal(f.observed().chunkCalls, 0); assert.equal(f.observed().committed, 0);
});

test('user cancels native save picker: binary may be staged but never reported saved', async t => {
  const f = await fixture(t, { pickerCancel: true });
  const result = await f.run(); assert.equal(result.state, 'cancelled'); assert.equal(result.saved, false);
  assert.equal(f.observed().committed, 1);
});

test('Agent cancellation requests Native cleanup without deleting source', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), onChunk: ({ controller, chunkCalls }) => { if (chunkCalls === 1) controller.abort(); } });
  const result = await f.run();
  assert.equal(result.state, 'cancelled'); assert.equal(result.saved, false); assert.equal(f.observed().cancelled, 1);
  assert.equal(digest(await readFile(f.path)), digest(f.bytes));
});

test('source mutation during transfer cancels before finish and keeps original path', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), onChunk: async ({ path, chunkCalls }) => { if (chunkCalls === 1) await appendFile(path, 'changed'); } });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'source_changed');
  assert.equal(f.observed().committed, 0); assert.equal(f.observed().cancelled, 1);
  assert.equal((await lstat(f.path)).size, f.bytes.length + 7);
});

test('Native full-stream SHA rejects changed bytes even when filesystem metadata cannot reveal mutation', async t => {
  const bytes = randomBytes(300000);
  const f = await fixture(t, { bytes, onChunk: async ({ path, chunkCalls }) => {
    if (chunkCalls !== 1) return;
    const file = await open(path, 'r+');
    try { await file.write(Buffer.from([bytes[200000] ^ 255]), 0, 1, 200000); } finally { await file.close(); }
  } });
  const io = { lstat, realpath, open: async (...args) => {
    const file = await open(...args), identity = await file.stat({ bigint: true });
    // Model a platform with metadata granularity insufficient to expose a
    // same-size edit. The bytes still come from the actual mutated disk file.
    file.stat = async () => identity; return file;
  } };
  const result = await f.run({ path: f.path }, { io });
  assert.equal(result.state, 'failed'); assert.equal(result.saved, false); assert.equal(result.reason, 'checksum_mismatch');
  assert.equal(f.observed().committed, 1); assert.equal(f.observed().native.state, 'failed');
});

test('inconsistent native offsets fail closed and cancel session', async t => {
  const f = await fixture(t, { bytes: randomBytes(300000), badOffset: true });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'bridge_invalid_chunk_offset');
  assert.equal(f.observed().committed, 0); assert.equal(f.observed().cancelled, 1);
});

test('saved state without true save evidence is rejected', async t => {
  const f = await fixture(t, { badSaved: true });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'save_not_confirmed');
});

test('saved without exact bytes/name/SHA receipt is not accepted as success', async t => {
  const f = await fixture(t, { missingSaveMetadata: true });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'save_not_confirmed');
});

test('capability disabled / auth denied errors never transfer or leak server message', async t => {
  for (const [errorStatus, errorCode, reason] of [[403, 'permission_denied', 'bridge_permission_denied'], [401, 'unauthorized', 'bridge_unauthorized']]) {
    const f = await fixture(t, { errorStatus, errorCode }); const result = await f.run();
    assert.equal(result.saved, false); assert.equal(result.reason, reason); assert.equal(f.observed().chunkCalls, 0);
    assert(!JSON.stringify(result).includes(TOKEN)); assert(!JSON.stringify(result).includes(SESSION));
  }
});

test('non-loopback bridge and credentials-bearing URLs never receive bearer token', async t => {
  const f = await fixture(t);
  for (const url of ['https://example.com', 'http://example.com', 'http://user:pass@127.0.0.1', 'http://127.0.0.1/?token=x']) {
    const result = await f.run({ path: f.path }, { environment: { ...f.options.environment, DSH_HOST_BRIDGE_URL: url } });
    assert.equal(result.reason, 'bridge_unavailable'); assert.equal(result.saved, false);
  }
  assert.equal(f.events.length, 0);
});

test('bounded response prevents oversized metadata body from reaching model', async t => {
  const f = await fixture(t, { oversizedResponse: true });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'bridge_invalid_response');
  assert(JSON.stringify(result).length < 300);
});

test('overall wait expiry is interrupted/resumable and never saved', async t => {
  const f = await fixture(t, { pending: 100000, options: { overallTimeoutMs: 15 } });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'export_wait_timed_out'); assert.equal(result.resumable, true);
  assert.equal(f.observed().committed, 0);
});

test('duplicate active invocation does not create parallel transfer or save', async t => {
  const config = { pending: 25 }; const f = await fixture(t, config);
  const first = f.run();
  const second = await f.run(); assert.equal(second.reason, 'export_already_active'); assert.equal(second.saved, false);
  assert.equal((await first).saved, true); assert.equal(f.observed().created, 1);
});

test('different paths cannot start parallel hashing or another Native session', async t => {
  const f = await fixture(t, { pending: 25 });
  const other = join(f.root, 'second.ipa'); await writeFile(other, f.bytes);
  const first = f.run(); const second = await f.run({ path: other });
  assert.equal(second.reason, 'another_export_active'); assert.equal(second.saved, false);
  assert.equal((await first).saved, true); assert.equal(f.observed().created, 1);
});

test('checkpoint capacity is bounded to 256 and preserves every prior record', async t => {
  const f = await fixture(t); const directory = join(f.home, '.workspace-export-v1'); await mkdir(directory, { mode: 0o700 });
  for (let i = 0; i < 256; i++) await writeFile(join(directory, `${i.toString(16).padStart(64, '0')}.json`), 'prior-recovery-record', { mode: 0o600 });
  const result = await f.run(); assert.equal(result.saved, false); assert.equal(result.reason, 'checkpoint_capacity_reached');
  assert.equal(f.events.length, 0); assert.equal((await readdir(directory)).length, 256);
  assert.equal(await readFile(join(directory, `${'0'.repeat(64)}.json`), 'utf8'), 'prior-recovery-record');
});

test('unsafe checkpoint symlink is preserved and no Native request is made', async t => {
  const f = await fixture(t); await mkdir(join(f.home, '.workspace-export-v1'), { mode: 0o700 });
  const scope = digest('fixture-session'), key = digest(JSON.stringify([scope, f.path, null]));
  const sentinel = join(f.directory, 'prior-record'); await writeFile(sentinel, 'preserve me');
  await symlink(sentinel, join(f.home, '.workspace-export-v1', `${key}.json`));
  assert.equal((await f.run()).saved, false); assert.equal(await readFile(sentinel, 'utf8'), 'preserve me'); assert.equal(f.events.length, 0);
});

test('tool registration needs no jobs service and exposes paths only, preserving legacy tools', async () => {
  const definitions = new Map([['file_import', {}], ['file_export', {}]]);
  const ctx = { tools: { register(tool) { assert(!definitions.has(tool.name)); definitions.set(tool.name, tool); } } };
  installWorkspaceExport(ctx, value => value);
  const tool = definitions.get('file_export_from_workspace'); assert(tool);
  assert.deepEqual(Object.keys(tool.parameters), ['path', 'name']);
  assert(definitions.has('file_import')); assert(definitions.has('file_export'));
  const result = JSON.parse(await tool.execute({ path: '/root/workspace/file.ipa' }, {}));
  assert.equal(result.saved, false); assert.equal(result.reason, 'session_owner_required');
});
