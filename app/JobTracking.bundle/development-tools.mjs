// Explicit development helpers. No automatic installs, retries, job cancellation,
// mirror changes, signing, or remote build submission.
import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, link, unlink, rmdir } from 'node:fs/promises';
import { dirname, join, parse, relative, resolve, basename } from 'node:path';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const run = promisify(execFile);
export async function developmentPreflight(target, { platform = process.platform, arch = process.arch, probe = run } = {}) {
  if (!['native-ios', 'web', 'script'].includes(target)) throw new Error('invalid development target');
  const result = { target, platform, arch, node_version: process.version,
    network: 'not_tested', dependencies: 'not_installed_or_changed', build_executed: false };
  if (target === 'native-ios' && platform !== 'darwin') return { ...result, state: 'requires_mac', can_build_here: false,
    next: 'Keep source and assets here; compile and test the IPA on an authorized real Mac with Xcode. Linux Swift or musl/glibc shims do not establish an iOS SDK.' };
  if (target === 'native-ios') {
    try {
      const options = { timeout: 10000, maxBuffer: 16384 };
      const version = await probe('xcodebuild', ['-version'], options);
      const sdk = await probe('xcrun', ['--sdk', 'iphoneos', '--show-sdk-path'], options);
      if (!/^Xcode [0-9]/m.test(version.stdout) || !sdk.stdout.trim()) throw new Error('no verified SDK');
      return { ...result, state: 'environment_ready', can_build_here: true, project_build_verified: false };
    } catch { return { ...result, state: 'xcode_or_ios_sdk_unverified', can_build_here: false }; }
  }
  const tools = {};
  for (const name of ['curl', 'clang', 'swift']) {
    try { const value = await probe('which', [name], { timeout: 3000, maxBuffer: 4096 });
      tools[name] = value.stdout.trim() ? 'present' : 'not_found';
    } catch (error) { tools[name] = error.code === 1 ? 'not_found' : 'unknown'; }
  }
  return { ...result, state: 'environment_observed', tools, project_build_verified: false,
    next: 'Check the project lockfile and required versions before installing anything. Present is not proof that a dependency is compatible.' };
}

async function safeParents(directory) {
  let cursor = parse(directory).root;
  for (const component of relative(cursor, directory).split(/[\\/]/).filter(Boolean)) {
    cursor = join(cursor, component);
    const info = await lstat(cursor);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_parent');
  }
}
async function hashFile(path, maxBytes, expectedIdentity) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size > maxBytes ||
      (expectedIdentity && (info.ino !== expectedIdentity.ino || info.dev !== expectedIdentity.dev))) throw new Error('unsafe_file');
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await file.stat();
    if (opened.ino !== info.ino || opened.dev !== info.dev || opened.nlink !== 1) throw new Error('changed_file');
    const hash = createHash('sha256'), buffer = Buffer.alloc(65536); let bytes = 0;
    for (;;) {
      const read = await file.read(buffer, 0, buffer.length, null);
      if (!read.bytesRead) break;
      bytes += read.bytesRead;
      if (bytes > maxBytes) throw new Error('too_large');
      hash.update(buffer.subarray(0, read.bytesRead));
    }
    return { sha256: hash.digest('hex'), bytes, ino: info.ino, dev: info.dev };
  } finally { await file.close(); }
}
const integer = (n, min, max) => Number.isSafeInteger(n) && n >= min && n <= max;

// Runs only when explicitly requested. curl retains its normal TLS, CA and proxy
// configuration. HTTPS-only redirects, no implicit retry, checksum before publish.
// The existing bash/job tools remain responsible for waiting and backgrounding.
export async function downloadDependency({ url, destination, sha256, connectSeconds = 15,
  stallSeconds = 60, totalSeconds = 900, maxBytes = 64 * 1024 * 1024 },
  { environment = process.env, progress = () => {}, signal } = {}) {
  let parsed;
  try { parsed = new URL(url); } catch { return { state: 'refused', reason: 'invalid_url' }; }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.hash || /[\r\n]/.test(url))
    return { state: 'refused', reason: 'https_without_embedded_credentials_required' };
  if (typeof sha256 !== 'string' || !/^[a-fA-F0-9]{64}$/.test(sha256) ||
      typeof destination !== 'string' || resolve(destination) !== destination ||
      !integer(connectSeconds, 1, 60) || !integer(stallSeconds, 1, 300) ||
      !integer(totalSeconds, 1, 1800) || !integer(maxBytes, 1, 256 * 1024 * 1024))
    return { state: 'refused', reason: 'invalid_arguments' };
  sha256 = sha256.toLowerCase();
  if (signal?.aborted) return { state: 'interrupted', reason: 'cancelled_before_transfer', transfers_started: 0 };
  const parent = dirname(destination), lock = `${destination}.dsh-download-lock`;
  let ownedLock, temporary, identity, child, timer, forceTimer, monitor, monitorBusy = false;
  let phase = 'preflight', bytes = 0, cancel;
  try {
    await safeParents(parent);
    try {
      await lstat(destination);
      const existing = await hashFile(destination, maxBytes);
      return existing.sha256 === sha256 ? { state: 'cached', bytes: existing.bytes, checksum_verified: true, transfers_started: 0 }
        : { state: 'refused', reason: 'existing_file_checksum_mismatch', existing_file_preserved: true };
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    phase = 'acquire';
    try { await mkdir(lock, { mode: 0o700 }); ownedLock = await lstat(lock); }
    catch (error) { if (error.code === 'EEXIST') return { state: 'blocked', reason: 'existing_download_or_unconfirmed_previous_run', transfers_started: 0 }; throw error; }
    temporary = join(parent, `.${basename(destination)}.dsh-part-${randomUUID()}`);
    const file = await open(temporary, 'wx', 0o600);
    try { identity = await file.stat(); } finally { await file.close(); }
    phase = 'transfer';
    const args = ['--fail', '--silent', '--show-error', '--location',
      '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', String(connectSeconds),
      '--speed-time', String(stallSeconds), '--speed-limit', '1', '--max-time', String(totalSeconds),
      '--max-filesize', String(maxBytes), '--retry', '0', '--output', temporary,
      '--write-out', 'DSH_HTTP=%{http_code}\n', '--', url];
    let output = '', deadline = false, lastBytes = -1;
    const finished = await new Promise(resolveDone => {
      child = spawn('curl', args, { stdio: ['ignore', 'pipe', 'pipe'], env: environment });
      cancel = () => { child.kill('SIGTERM'); clearTimeout(forceTimer);
        forceTimer = setTimeout(() => child.kill('SIGKILL'), 1000); };
      signal?.addEventListener('abort', cancel, { once: true });
      if (signal?.aborted) cancel();
      child.stdout.on('data', data => { if (output.length < 4096) output += data.toString(); });
      child.stderr.resume(); // Never print a URL, credential or server error body.
      timer = setTimeout(() => { deadline = true; child.kill('SIGTERM');
        forceTimer = setTimeout(() => child.kill('SIGKILL'), 1000); }, (totalSeconds + 2) * 1000);
      monitor = setInterval(async () => {
        if (monitorBusy) return;
        monitorBusy = true;
        try {
          const info = await lstat(temporary); bytes = info.size;
          if (bytes !== lastBytes) { lastBytes = bytes; try { progress({ event: 'download_progress', bytes }); } catch {} }
          if (bytes > maxBytes) child.kill('SIGTERM');
        } catch {} finally { monitorBusy = false; }
      }, 250);
      let unavailable = false;
      child.once('error', () => { unavailable = true; });
      child.once('close', (code, signal) => resolveDone({ code, signal, unavailable }));
    });
    clearTimeout(timer); clearTimeout(forceTimer); clearInterval(monitor);
    if (signal?.aborted) return { state: 'interrupted', reason: 'cancelled', signal: finished.signal, published: false };
    const http = /DSH_HTTP=([0-9]{3})/.exec(output);
    if (finished.code !== 0 || deadline) return { state: 'failed', reason: deadline ? 'total_deadline' :
      finished.unavailable ? 'curl_unavailable' : finished.code === 28 ? 'transfer_timeout_or_stall' : 'transfer_failed',
      curl_exit_code: finished.code, signal: finished.signal, http_status: http ? Number(http[1]) : null,
      partial_bytes: bytes, published: false, retries_started: 0 };
    if (!http || Number(http[1]) < 200 || Number(http[1]) >= 300)
      return { state: 'failed', reason: 'unexpected_http_status', published: false };
    phase = 'verify';
    await safeParents(parent);
    const downloaded = await hashFile(temporary, maxBytes, identity);
    if (downloaded.sha256 !== sha256) return { state: 'failed', reason: 'checksum_mismatch', published: false };
    if (signal?.aborted) return { state: 'interrupted', reason: 'cancelled_before_publication', published: false };
    const synced = await open(temporary, 'r');
    try { await synced.sync(); } finally { await synced.close(); }
    if (signal?.aborted) return { state: 'interrupted', reason: 'cancelled_before_publication', published: false };
    phase = 'publish';
    // link is an atomic no-clobber publication; rename could overwrite a file
    // created by the user while the network transfer was running.
    await link(temporary, destination);
    phase = 'sync_publication';
    const directory = await open(parent, 'r');
    try { await directory.sync(); } finally { await directory.close(); }
    return { state: 'completed', bytes: downloaded.bytes, checksum_verified: true, transfers_started: 1, retries_started: 0 };
  } catch (error) {
    return { state: phase === 'sync_publication' ? 'unknown' : 'failed', reason: `local_${phase}_failed`,
      error_code: /^[A-Z0-9_]{1,30}$/.test(error.code ?? '') ? error.code : 'UNCONFIRMED',
      existing_file_preserved: true, published: phase === 'sync_publication' };
  } finally {
    clearTimeout(timer); clearTimeout(forceTimer); clearInterval(monitor);
    if (cancel) signal?.removeEventListener('abort', cancel);
    if (temporary && identity) {
      try { const current = await lstat(temporary);
        if (current.ino === identity.ino && current.dev === identity.dev && !current.isSymbolicLink()) await unlink(temporary);
      } catch {}
    }
    if (ownedLock) {
      try { const current = await lstat(lock);
        if (current.ino === ownedLock.ino && current.dev === ownedLock.dev && !current.isSymbolicLink()) await rmdir(lock);
      } catch {}
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [action, ...args] = process.argv.slice(2);
  let result;
  try {
    if (action === 'preflight') result = await developmentPreflight(args[0]);
    else if (action === 'download') {
      const controller = new AbortController(), abort = () => controller.abort();
      process.once('SIGTERM', abort); process.once('SIGINT', abort);
      try { result = await downloadDependency({ url: args[0], destination: args[1], sha256: args[2] },
        { signal: controller.signal, progress: value => console.log(JSON.stringify(value)) }); }
      finally { process.removeListener('SIGTERM', abort); process.removeListener('SIGINT', abort); }
    }
    else throw new Error('invalid action');
  } catch { result = { state: 'refused', reason: 'invalid_request' }; }
  console.log(JSON.stringify(result));
  process.exitCode = ['completed', 'cached', 'environment_observed', 'environment_ready'].includes(result.state) ? 0 : 1;
}
