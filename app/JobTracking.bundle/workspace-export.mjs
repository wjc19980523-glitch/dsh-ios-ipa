// Trusted Guest -> Native transfer. Model arguments contain paths, never bytes,
// bridge credentials, session identifiers or encoded file contents.
import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, realpath, open, mkdir, rename, unlink, opendir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, parse, relative, resolve, sep } from 'node:path';

export const WORKSPACE_EXPORT_MAX_BYTES = 512 * 1024 * 1024;
export const WORKSPACE_EXPORT_CHUNK_BYTES = 128 * 1024;
const HASH = /^[a-f0-9]{64}$/;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SESSION = /^[a-zA-Z0-9_-]{16,128}$/;
const STATES = new Set(['pending_confirmation', 'receiving', 'ready', 'saving', 'saved', 'cancelled', 'expired', 'failed']);
const TERMINAL = new Set(['saved', 'cancelled', 'expired', 'failed']);
const BRIDGE_ERRORS = new Set(['permission_denied', 'unavailable', 'unauthorized', 'invalid_request', 'not_found',
  'conflict', 'expired', 'checksum_mismatch', 'unknown_session', 'busy', 'offset_mismatch', 'invalid_state', 'incomplete', 'insufficient_storage']);
const TERMINAL_ERRORS = new Set(['permission_denied', 'cancelled', 'expired', 'checksum_mismatch', 'unavailable', 'timed_out', 'disk_full',
  'file_picker_timeout', 'capability_disabled', 'app_backgrounded', 'app_not_active', 'no_foreground_presenter', 'presenter_transition_timeout',
  'presenter_busy', 'picker_not_presented', 'picker_presentation_failed', 'invalid_staged_file', 'export_ui_busy', 'invalid_picker_result',
  'export_cancelled', 'user_cancelled', 'staging_failed', 'insufficient_storage', 'write_failed', 'sync_failed', 'close_failed', 'commit_failed']);
const PRIVATE = /^(?:\..*|id_(?:rsa|dsa|ecdsa|ed25519)(?:\..*)?|(?:.*[-_.])?(?:credentials?|secrets?|tokens?)(?:[-_.].*)?)$|\.(?:pem|p12|pfx|key)$/i;
const active = new Map();
const sha = value => createHash('sha256').update(value).digest('hex');
const failure = code => Object.assign(new Error(code), { exportCode: code });
const inside = (root, path) => path !== root && !relative(root, path).startsWith(`..${sep}`) && relative(root, path) !== '..' && !isAbsolute(relative(root, path));
const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
const safeName = name => typeof name === 'string' && name.length > 0 && Buffer.byteLength(name) <= 128 &&
  !/[\p{Cc}\p{Cf}/\\:]/u.test(name) && !name.startsWith('.') && name !== '..' && name.trim() === name;
const checkSignal = signal => { if (signal?.aborted) throw failure('cancelled'); };

async function parents(path, io) {
  let cursor = parse(path).root;
  for (const part of relative(cursor, path).split(sep).filter(Boolean)) {
    cursor = join(cursor, part);
    const info = await io.lstat(cursor, { bigint: true });
    if (!info.isDirectory() || info.isSymbolicLink()) throw failure('unsafe_parent');
  }
}

// iSH's generic_openat currently follows symlinks even with O_NOFOLLOW. The
// lstat/open/fstat comparison BEFORE any read is essential, not an optimization.
// O_NONBLOCK also prevents a concurrently substituted FIFO from blocking open.
export async function openWorkspaceFile(args, exec, options = {}) {
  const io = options.io ?? { lstat, realpath, open };
  const environment = options.environment ?? process.env;
  const root = environment.DSH_WORKSPACE ?? '/root/workspace';
  const workspace = exec?.agent?.session?.header?.cwd;
  const path = args?.path;
  if (![root, workspace, path].every(value => typeof value === 'string' && isAbsolute(value) &&
      !value.includes('\\') && !/[\p{Cc}\p{Cf}]/u.test(value) && resolve(value) === value &&
      !value.split('/').some(part => part === '..' || part === '.')))
    throw failure('absolute_canonical_workspace_path_required');
  if (Buffer.byteLength(path) > 1024 || Buffer.byteLength(workspace) > 1024) throw failure('workspace_path_too_long');
  if (workspace !== root && !inside(root, workspace)) throw failure('workspace_outside_authorized_root');
  if (!inside(workspace, path)) throw failure('file_outside_current_workspace');
  if (relative(root, path).split(sep).some(part => PRIVATE.test(part))) throw failure('sensitive_path');
  const name = args.name ?? basename(path);
  if (!safeName(name)) throw failure('invalid_export_name');
  checkSignal(exec?.signal);
  await parents(dirname(path), io);
  if (await io.realpath(root) !== root || await io.realpath(workspace) !== workspace || await io.realpath(path) !== path)
    throw failure('symbolic_path');
  const observed = await io.lstat(path, { bigint: true });
  if (!observed.isFile() || observed.isSymbolicLink() || observed.nlink !== 1n) throw failure('ordinary_unlinked_file_required');
  if (observed.size < 0n || observed.size > BigInt(WORKSPACE_EXPORT_MAX_BYTES)) throw failure('invalid_file_size');
  const file = await io.open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | constants.O_NONBLOCK);
  try {
    const opened = await file.stat({ bigint: true });
    if (!opened.isFile() || opened.nlink !== 1n || !same(opened, observed)) throw failure('source_changed_before_read');
    await parents(dirname(path), io);
    if (await io.realpath(path) !== path) throw failure('source_changed_before_read');
    return { file, identity: opened, workspace, path, name, bytes: Number(opened.size) };
  } catch (error) { await file.close(); throw error; }
}

async function assertUnchanged(source) {
  const info = await source.file.stat({ bigint: true });
  if (!info.isFile() || info.nlink !== 1n || !same(info, source.identity)) throw failure('source_changed');
}

async function hashSource(source, signal) {
  const hash = createHash('sha256'), buffer = Buffer.alloc(64 * 1024);
  let offset = 0;
  while (offset < source.bytes) {
    checkSignal(signal);
    const { bytesRead } = await source.file.read(buffer, 0, Math.min(buffer.length, source.bytes - offset), offset);
    if (!bytesRead) throw failure('source_changed');
    hash.update(buffer.subarray(0, bytesRead)); offset += bytesRead;
  }
  await assertUnchanged(source);
  return hash.digest('hex');
}

// Checkpoints are private bounded metadata only. In particular no Native
// session capability, bearer token, signed URL or file contents is persisted.
class Checkpoint {
  constructor(home, key) { this.directory = join(resolve(home), '.workspace-export-v1'); this.path = join(this.directory, `${key}.json`); }
  async prepare() {
    await parents(dirname(this.directory), { lstat });
    try { await mkdir(this.directory, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    await parents(this.directory, { lstat });
    const info = await lstat(this.directory);
    if ((info.mode & 0o077) !== 0) throw failure('checkpoint_not_private');
    let count = 0, existing = false;
    // Stream the directory instead of materializing an unbounded listing.
    // Preserve unknown/old records; exhaustion never silently erases recovery.
    for await (const entry of await opendir(this.directory)) {
      count++; if (entry.name === basename(this.path)) existing = true;
      if (count > 256) throw failure('checkpoint_capacity_reached');
    }
    if (count === 256 && !existing) throw failure('checkpoint_capacity_reached');
  }
  async load() {
    await this.prepare();
    let info;
    try { info = await lstat(this.path, { bigint: true }); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
    if (!info.isFile() || info.nlink !== 1n || info.size > 8192n || (info.mode & 0o077n) !== 0n) throw failure('unsafe_checkpoint');
    const file = await open(this.path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | constants.O_NONBLOCK);
    try {
      if (!same(info, await file.stat({ bigint: true }))) throw failure('unsafe_checkpoint');
      const buffer = Buffer.alloc(8193);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      if (bytesRead > 8192 || !same(info, await file.stat({ bigint: true }))) throw failure('unsafe_checkpoint');
      const data = buffer.subarray(0, bytesRead);
      const record = JSON.parse(data.toString('utf8'));
      if (record.schema !== 1 || !UUID.test(record.request_id ?? '') || !HASH.test(record.fingerprint ?? '') ||
          !['created', 'transferring', 'waiting', 'interrupted', 'terminal'].includes(record.phase) || typeof record.reported !== 'boolean')
        throw failure('invalid_checkpoint');
      return record;
    } finally { await file.close(); }
  }
  async save(record) {
    await this.prepare();
    const temporary = `${this.path}.${randomUUID()}.tmp`;
    let created = false;
    try {
      const file = await open(temporary, 'wx', 0o600); created = true;
      try { await file.writeFile(JSON.stringify(record)); await file.sync(); } finally { await file.close(); }
      await parents(this.directory, { lstat });
      await rename(temporary, this.path); created = false;
      const directory = await open(this.directory, 'r');
      try { await directory.sync(); } finally { await directory.close(); }
    } finally { if (created) await unlink(temporary).catch(() => {}); }
  }
}

function bridgeTransport(options, signal) {
  const environment = options.environment ?? process.env;
  const base = environment.DSH_HOST_BRIDGE_URL, token = environment.DSH_HOST_BRIDGE_TOKEN;
  let url;
  try { url = new URL(base); } catch { throw failure('bridge_unavailable'); }
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.username || url.password || url.pathname !== '/' || url.search || url.hash || !token || /[\r\n]/.test(token))
    throw failure('bridge_unavailable');
  const fetcher = options.fetch ?? fetch;
  const timeout = options.requestTimeoutMs ?? 15000;
  return async (action, { method = 'POST', json, data, session, scope, offset, checksum, ignoreCancellation = false } = {}) => {
    const controller = new AbortController();
    const abort = () => controller.abort();
    if (!ignoreCancellation) { signal?.addEventListener('abort', abort, { once: true }); if (signal?.aborted) abort(); }
    const timer = setTimeout(abort, timeout);
    try {
      const response = await fetcher(new URL(`/v1/files/workspace-export/${action}`, url), {
        method, redirect: 'error', signal: controller.signal,
        headers: { authorization: `Bearer ${token}`,
          ...(json ? { 'content-type': 'application/json' } : {}),
          ...(data ? { 'content-type': 'application/octet-stream', 'content-length': String(data.length),
            'x-dsh-export-offset': String(offset), 'x-dsh-export-sha256': checksum } : {}),
          ...(session ? { 'x-dsh-export-session': session, 'x-dsh-export-scope': scope } : {}) },
        body: data ?? (json ? JSON.stringify(json) : undefined),
      });
      // Do not echo an arbitrary server error/message (or fetch's URL-bearing
      // exception) into model output. Bound even the metadata response body.
      let text = '', responseBytes = 0; const decoder = new TextDecoder(); const reader = response.body?.getReader();
      if (!reader) throw failure('bridge_invalid_response');
      try {
        for (;;) { const part = await reader.read(); if (part.done) break;
          responseBytes += part.value.length;
          if (responseBytes > 16384) { await reader.cancel(); throw failure('bridge_invalid_response'); }
          text += decoder.decode(part.value, { stream: true }); }
        text += decoder.decode();
      } finally { reader.releaseLock(); }
      let value; try { value = JSON.parse(text); } catch { throw failure('bridge_invalid_response'); }
      if (!response.ok) {
        const code = value?.error?.code;
        throw failure(BRIDGE_ERRORS.has(code) ? `bridge_${code}` : `bridge_http_${response.status}`);
      }
      if (!value || typeof value !== 'object' || !STATES.has(value.state)) throw failure('bridge_invalid_state');
      return value;
    } catch (error) {
      if (error.exportCode) throw error;
      throw failure(signal?.aborted && !ignoreCancellation ? 'cancelled' : 'bridge_interrupted');
    } finally { clearTimeout(timer); if (!ignoreCancellation) signal?.removeEventListener('abort', abort); }
  };
}

function validateStatus(status, source, session) {
  if (!Number.isSafeInteger(status.offset) || status.offset < 0 || status.offset > source.bytes ||
      (status.session_id !== undefined && !SESSION.test(status.session_id)) ||
      (session && status.session_id !== undefined && status.session_id !== session) ||
      (status.bytes !== undefined && status.bytes !== source.bytes) ||
      (status.sha256 !== undefined && status.sha256 !== source.sha256) ||
      (status.name !== undefined && status.name !== source.name)) throw failure('bridge_inconsistent_metadata');
  if (status.state === 'saved' && (status.saved !== true || status.offset !== source.bytes ||
      status.bytes !== source.bytes || status.sha256 !== source.sha256 || status.name !== source.name))
    throw failure('save_not_confirmed');
  if (status.state !== 'saved' && status.saved === true) throw failure('save_not_confirmed');
  return status;
}

const sleep = (ms, signal) => new Promise((done, reject) => {
  const onAbort = () => { clearTimeout(timer); reject(failure('cancelled')); };
  const timer = setTimeout(() => { signal?.removeEventListener('abort', onAbort); done(); }, ms);
  signal?.addEventListener('abort', onAbort, { once: true });
  if (signal?.aborted) onAbort();
});

export async function exportWorkspace(args, exec, options = {}) {
  let source, checkpoint, record, transport, session;
  const signal = exec?.signal;
  const owner = exec?.agent?.id;
  if (typeof owner !== 'string' || !owner || owner.length > 1024) return { state: 'refused', saved: false, reason: 'session_owner_required' };
  const scope = sha(owner), key = sha(JSON.stringify([scope, args?.path, args?.name ?? null]));
  if (active.has(key)) return { state: 'pending', saved: false, reason: 'export_already_active', resumable: true };
  if (active.size) return { state: 'pending', saved: false, reason: 'another_export_active', resumable: true };
  active.set(key, true);
  try {
    source = await openWorkspaceFile(args, exec, options);
    source.sha256 = await hashSource(source, signal);
    const metadata = { scope_id: scope, workspace: source.workspace, source: source.path, name: source.name, bytes: source.bytes, sha256: source.sha256 };
    const fingerprint = sha(JSON.stringify(metadata));
    checkpoint = new Checkpoint(options.home ?? process.env.DSH_HOME ?? join(homedir(), '.dsh'), key);
    record = await checkpoint.load();
    if (record && record.fingerprint !== fingerprint && record.phase !== 'terminal') throw failure('source_changed_since_checkpoint');
    if (!record || record.fingerprint !== fingerprint || (record.phase === 'terminal' && record.reported))
      record = { schema: 1, request_id: randomUUID(), fingerprint, phase: 'created', reported: false };
    await checkpoint.save(record); // durable request identity BEFORE Native sees it
    const send = bridgeTransport(options, signal);
    transport = (action, request = {}) => send(action, { ...request, scope });
    let status;
    // A lost start response is reconciled only by the SAME request id. Native
    // must return the existing session without a second confirmation/save.
    for (let attempt = 0; attempt < 2; attempt++) {
      try { status = await transport('start', { json: { request_id: record.request_id, ...metadata } }); break; }
      catch (error) { if (error.exportCode !== 'bridge_interrupted' || attempt === 1) throw error; }
    }
    validateStatus(status, source);
    session = status.session_id;
    if (!SESSION.test(session ?? '')) throw failure('bridge_invalid_session');
    const maxChunk = status.max_chunk_bytes;
    if (!Number.isSafeInteger(maxChunk) || maxChunk < 1 || maxChunk > WORKSPACE_EXPORT_CHUNK_BYTES) throw failure('bridge_invalid_chunk_limit');
    const now = options.now ?? Date.now, deadline = now() + (options.overallTimeoutMs ?? 30 * 60 * 1000);
    const pollMs = options.pollMs ?? 500;
    const observe = value => { try { options.progress?.({ state: value.state, bytes_sent: value.offset, total_bytes: source.bytes }); } catch {} };
    const getStatus = async () => validateStatus(await transport('status', { method: 'GET', session }), source, session);
    const ensureLive = () => { checkSignal(signal); if (now() >= deadline) throw failure('export_wait_timed_out'); };
    let offset = status.offset;
    record.phase = 'transferring'; await checkpoint.save(record);
    while (!TERMINAL.has(status.state)) {
      ensureLive(); observe(status);
      if (status.state === 'pending_confirmation' || status.state === 'ready' || status.state === 'saving') {
        await sleep(pollMs, signal); status = await getStatus(); continue;
      }
      if (status.state !== 'receiving') throw failure('bridge_invalid_state');
      offset = status.offset;
      if (offset === source.bytes) {
        await assertUnchanged(source);
        // Native hashes the actual received stream and refuses a digest that
        // differs from the pre-confirmation SHA256. Do not spend the Native
        // session's idle window rereading a large file a third time here.
        record.phase = 'waiting'; await checkpoint.save(record);
        try { status = validateStatus(await transport('finish', { json: {}, session }), source, session); }
        catch (error) { if (error.exportCode !== 'bridge_interrupted') throw error; status = await getStatus(); }
        continue;
      }
      await assertUnchanged(source);
      const chunk = Buffer.alloc(Math.min(maxChunk, source.bytes - offset));
      let filled = 0;
      while (filled < chunk.length) {
        const { bytesRead } = await source.file.read(chunk, filled, chunk.length - filled, offset + filled);
        if (!bytesRead) throw failure('source_changed'); filled += bytesRead;
      }
      const checksum = sha(chunk);
      let next;
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          next = validateStatus(await transport('chunk', { method: 'PUT', data: chunk, session, offset, checksum }), source, session);
          break;
        } catch (error) {
          if (error.exportCode !== 'bridge_interrupted') throw error;
          const reconciled = await getStatus();
          if (TERMINAL.has(reconciled.state)) { next = reconciled; break; }
          if (reconciled.state !== 'receiving' || ![offset, offset + chunk.length].includes(reconciled.offset)) throw failure('bridge_invalid_chunk_offset');
          if (reconciled.offset === offset + chunk.length) { next = reconciled; break; }
          if (attempt === 1) throw error;
        }
      }
      if (!TERMINAL.has(next.state) && (next.state !== 'receiving' || next.offset !== offset + chunk.length)) throw failure('bridge_invalid_chunk_offset');
      status = next;
    }
    observe(status);
    record.phase = 'terminal'; record.reported = true; await checkpoint.save(record);
    return { state: status.state, saved: status.state === 'saved', name: source.name, bytes: source.bytes, sha256: source.sha256,
      ...(status.state === 'saved' ? {} : { reason: TERMINAL_ERRORS.has(status.error_code) ? status.error_code : status.state }) };
  } catch (error) {
    const reason = error.exportCode ?? 'local_file_or_checkpoint_error';
    if (reason === 'cancelled' && session && transport) {
      try { await transport('cancel', { json: {}, session, ignoreCancellation: true }); } catch {}
    } else if (session && transport && ['source_changed', 'bridge_inconsistent_metadata', 'bridge_invalid_chunk_offset', 'save_not_confirmed'].includes(reason)) {
      try { await transport('cancel', { json: {}, session, ignoreCancellation: true }); } catch {}
    }
    const resumable = ['bridge_interrupted', 'export_wait_timed_out', 'bridge_unavailable', 'bridge_unknown_session'].includes(reason);
    if (record && checkpoint) {
      record.phase = resumable ? 'interrupted' : 'terminal'; record.reported = !resumable;
      try { await checkpoint.save(record); } catch {}
    }
    return { state: reason === 'cancelled' ? 'cancelled' : resumable ? 'interrupted' : 'refused', saved: false, reason, resumable };
  } finally { if (source) await source.file.close().catch(() => {}); active.delete(key); }
}

export function installWorkspaceExport(ctx, defineTool, options = {}) {
  const output = { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] };
  ctx.tools.register(defineTool({
    name: 'file_export_from_workspace',
    description: 'Save an existing ordinary file from this session workspace to iOS Files. Supply only its absolute path and optional name. Trusted code streams binary chunks (up to 512 MiB), verifies SHA256, asks the user to confirm its source/name/size and opens the native save picker. Never read or send file Base64. A cancelled, interrupted or merely displayed picker is not saved. Repeat an interrupted call with the same path/name to resume; do not reset data. Sensitive paths, links and files outside the authorized current workspace are refused. The user may disable this capability.',
    parameters: { path: { type: 'string', required: true, description: 'Absolute existing file path inside the current authorized session workspace.' }, name: { type: 'string', description: 'Optional single file name for iOS Files.' } },
    output,
    async execute(args, exec) { return JSON.stringify(await exportWorkspace(args, exec, options)); },
    presentCall: args => ({ card: 'generic', title: `Save workspace file ${safeName(args.name ?? '') ? args.name : ''}`.trim(), kind: 'other' }),
  }));
}
