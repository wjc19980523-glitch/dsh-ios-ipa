// Bounded ZIP verification and single-IPA publication. No unzip/Python/gh,
// extract-all, shell interpolation, overwrite, signing or device installation.
import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { open, lstat, realpath, mkdir, link, unlink } from 'node:fs/promises';
import { dirname, basename, join, resolve, relative, parse } from 'node:path';
import { createInflateRaw } from 'node:zlib';
import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const LIMIT = 512 * 1024 * 1024;
const fail = code => { throw Object.assign(new Error(code), { code }); };
const table = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let n = 0; n < 8; n++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crcUpdate(crc, bytes) {
  for (const value of bytes) crc = table[(crc ^ value) & 255] ^ (crc >>> 8);
  return crc >>> 0;
}
export function crc32(bytes) { return (crcUpdate(0xffffffff, bytes) ^ 0xffffffff) >>> 0; }
export async function secureParents(path) {
  let current = parse(resolve(path)).root;
  for (const part of relative(current, resolve(path)).split(/[\\/]/).filter(Boolean)) {
    current = join(current, part);
    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink()) fail('unsafe_parent');
  }
}
export function safeZipName(name) {
  if (typeof name !== 'string' || name.length === 0 || Buffer.byteLength(name) > 2048 ||
      /[\\:\x00-\x1f\x7f]/.test(name) || name.startsWith('/') || name.normalize('NFC') !== name)
    fail('unsafe_zip_path');
  const parts = name.replace(/\/$/, '').split('/');
  if (parts.some(x => !x || x === '.' || x === '..' || /[ .]$/.test(x))) fail('unsafe_zip_path');
  return name;
}
async function exact(file, size, position) {
  const bytes = Buffer.alloc(size);
  let offset = 0;
  while (offset < size) {
    const read = await file.read(bytes, offset, size - offset, position + offset);
    if (!read.bytesRead) fail('truncated_zip');
    offset += read.bytesRead;
  }
  return bytes;
}
async function sameFile(file, original) {
  const now = await file.stat();
  if (!now.isFile() || now.ino !== original.ino || now.dev !== original.dev || now.size !== original.size ||
      now.mtimeMs !== original.mtimeMs || now.ctimeMs !== original.ctimeMs || now.nlink !== 1) fail('file_changed');
}
async function reader(path, maxBytes) {
  await secureParents(dirname(path));
  const entry = await lstat(path);
  if (!entry.isFile() || entry.isSymbolicLink() || entry.nlink !== 1 || entry.size > maxBytes) fail('unsafe_file');
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK | (constants.O_NOFOLLOW ?? 0));
  const original = await file.stat();
  if (!original.isFile() || original.nlink !== 1 || entry.ino !== original.ino || entry.dev !== original.dev) { await file.close(); fail('file_changed'); }
  return { file, original };
}
export async function hashVerifiedFile(path, maxBytes = LIMIT, signal) {
  const { file, original } = await reader(path, maxBytes);
  try {
    const hash = createHash('sha256'), buffer = Buffer.alloc(65536); let bytes = 0;
    while (bytes < original.size) {
      if (signal?.aborted) fail('cancelled');
      const amount = Math.min(buffer.length, original.size - bytes);
      const part = await exact(file, amount, bytes); bytes += part.length; hash.update(part);
    }
    await sameFile(file, original);
    const result = { bytes, sha256: hash.digest('hex') };
    Object.defineProperty(result, 'identity', { value: original });
    return result;
  } finally { await file.close(); }
}
async function directory(file, size, { maxEntries = 30000, maxExpanded = 2 * 1024 ** 3 } = {}) {
  if (size < 22) fail('invalid_zip');
  const tailAt = Math.max(0, size - 65557), tail = await exact(file, size - tailAt, tailAt);
  let end = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail.readUInt32LE(i) === 0x06054b50 && i + 22 + tail.readUInt16LE(i + 20) === tail.length) { end = i; break; }
  }
  if (end < 0 || tail.readUInt16LE(end + 4) || tail.readUInt16LE(end + 6)) fail('unsupported_zip');
  const count = tail.readUInt16LE(end + 10), diskCount = tail.readUInt16LE(end + 8);
  const length = tail.readUInt32LE(end + 12), offset = tail.readUInt32LE(end + 16);
  if (!count || count !== diskCount || count === 65535 || count > maxEntries || length > 8 * 1024 ** 2 ||
      offset + length !== tailAt + end) fail('unsupported_zip');
  const central = await exact(file, length, offset), entries = [], seen = new Set();
  let cursor = 0, expanded = 0;
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > central.length || central.readUInt32LE(cursor) !== 0x02014b50) fail('invalid_central_directory');
    const flags = central.readUInt16LE(cursor + 8), method = central.readUInt16LE(cursor + 10);
    const compressed = central.readUInt32LE(cursor + 20), bytes = central.readUInt32LE(cursor + 24);
    const nameLength = central.readUInt16LE(cursor + 28), extra = central.readUInt16LE(cursor + 30), comment = central.readUInt16LE(cursor + 32);
    const mode = central.readUInt32LE(cursor + 38) >>> 16, local = central.readUInt32LE(cursor + 42);
    if (cursor + 46 + nameLength + extra + comment > central.length || flags & ~0x080e || flags & 1 ||
        ![0, 8].includes(method) || central.readUInt16LE(cursor + 34) ||
        compressed === 0xffffffff || bytes === 0xffffffff || local === 0xffffffff) fail('unsupported_zip_entry');
    const rawName = central.subarray(cursor + 46, cursor + 46 + nameLength);
    const name = safeZipName(rawName.toString('utf8'));
    if (!Buffer.from(name).equals(rawName) || (!(flags & 0x800) && rawName.some(v => v > 127))) fail('unsupported_zip_encoding');
    const alias = name.replace(/\/$/, '').toLowerCase();
    if (seen.has(alias)) fail('duplicate_zip_path');
    seen.add(alias);
    const type = mode & 0xf000;
    if (type && type !== 0x8000 && type !== 0x4000) fail('unsupported_zip_file_type');
    const isDirectory = name.endsWith('/');
    if (isDirectory && bytes || type === 0x4000 && !isDirectory ||
        method === 0 && compressed !== bytes) fail('invalid_zip_entry');
    expanded += bytes;
    if (bytes > LIMIT || expanded > maxExpanded) fail('expanded_zip_limit');
    entries.push({ name, rawName, flags, method, compressed, bytes, crc: central.readUInt32LE(cursor + 16), local, isDirectory });
    cursor += 46 + nameLength + extra + comment;
  }
  if (cursor !== central.length) fail('invalid_central_directory');
  const paths = new Map(entries.map(e => [e.name.replace(/\/$/, '').toLowerCase(), e]));
  for (const entry of entries) {
    const parts = entry.name.replace(/\/$/, '').split('/'); parts.pop();
    while (parts.length) { const parent = paths.get(parts.join('/').toLowerCase()); if (parent && !parent.isDirectory) fail('zip_file_directory_collision'); parts.pop(); }
  }
  for (const entry of entries) {
    const header = await exact(file, 30, entry.local);
    if (header.readUInt32LE(0) !== 0x04034b50 || header.readUInt16LE(6) !== entry.flags ||
        header.readUInt16LE(8) !== entry.method) fail('zip_local_mismatch');
    const nameSize = header.readUInt16LE(26), extraSize = header.readUInt16LE(28);
    const name = await exact(file, nameSize, entry.local + 30);
    if (!name.equals(entry.rawName)) fail('zip_local_mismatch');
    for (const [at, expected] of [[14, entry.crc], [18, entry.compressed], [22, entry.bytes]]) {
      const value = header.readUInt32LE(at);
      if (value !== expected && (!(entry.flags & 8) || value !== 0)) fail('zip_local_mismatch');
    }
    entry.data = entry.local + 30 + nameSize + extraSize;
    entry.end = entry.data + entry.compressed;
    if (entry.end > offset) fail('zip_entry_outside_data');
    if (entry.flags & 8) {
      const first = await exact(file, 4, entry.end);
      const descriptor = await exact(file, first.readUInt32LE(0) === 0x08074b50 ? 16 : 12, entry.end);
      const base = descriptor.length === 16 ? 4 : 0;
      if (descriptor.readUInt32LE(base) !== entry.crc || descriptor.readUInt32LE(base + 4) !== entry.compressed ||
          descriptor.readUInt32LE(base + 8) !== entry.bytes) fail('zip_descriptor_mismatch');
      entry.end += descriptor.length;
    }
    if (entry.end > offset) fail('zip_entry_outside_data');
  }
  const sorted = [...entries].sort((a, b) => a.local - b.local);
  for (let i = 1; i < sorted.length; i++) if (sorted[i].local < sorted[i - 1].end) fail('overlapping_zip_entries');
  return entries;
}
async function streamEntry(file, entry, sink, signal) {
  let crc = 0xffffffff, bytes = 0, prefix = Buffer.alloc(0);
  async function* chunks() {
    for (let position = entry.data; position < entry.data + entry.compressed;) {
      if (signal?.aborted) fail('cancelled');
      const value = await exact(file, Math.min(65536, entry.data + entry.compressed - position), position);
      position += value.length; yield value;
    }
  }
  const output = new Writable({ write(chunk, _encoding, next) {
    (async () => {
      bytes += chunk.length;
      if (bytes > entry.bytes || signal?.aborted) fail(signal?.aborted ? 'cancelled' : 'expanded_zip_limit');
      crc = crcUpdate(crc, chunk);
      if (prefix.length < 64) prefix = Buffer.concat([prefix, chunk.subarray(0, 64 - prefix.length)]);
      if (sink) await sink(chunk);
    })().then(() => next(), next);
  } });
  const streams = [Readable.from(chunks())];
  if (entry.method === 8) streams.push(createInflateRaw());
  streams.push(output);
  await pipeline(streams, { signal });
  if (bytes !== entry.bytes || ((crc ^ 0xffffffff) >>> 0) !== entry.crc) fail('zip_crc_mismatch');
  return { bytes, prefix };
}
export async function verifyIpa(path, { signal, maxBytes = LIMIT } = {}) {
  const { file, original } = await reader(path, maxBytes);
  try {
    const entries = await directory(file, original.size), apps = new Set(); let info = false, executable = false;
    for (const entry of entries) {
      const value = await streamEntry(file, entry, null, signal);
      const match = /^Payload\/([^/]+\.app)\/(.+)$/.exec(entry.name);
      if (!match) continue;
      apps.add(match[1]);
      if (match[2] === 'Info.plist') {
        info = value.prefix.subarray(0, 8).toString() === 'bplist00' || /^\s*(<\?xml|<plist)/.test(value.prefix.toString());
      }
      if (!match[2].includes('/') && value.prefix.length >= 4 &&
          ['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca'].includes(value.prefix.subarray(0, 4).toString('hex'))) executable = true;
    }
    if (apps.size !== 1 || !info || !executable) fail('invalid_ipa_payload');
    await sameFile(file, original);
    return { zip_crc_verified: true, payload_structure_verified: true, entries: entries.length,
      verification: 'basic ZIP/Payload/Info.plist/Mach-O only; no signature or installation claim' };
  } finally { await file.close(); }
}
export async function extractVerifiedArtifact({ archive, directory: destination, expectedSize, expectedSha256,
  ipaMember, signal, maxBytes = LIMIT }) {
  if (!Number.isSafeInteger(expectedSize) || expectedSize < 22 || expectedSize > maxBytes ||
      !/^[a-f0-9]{64}$/.test(expectedSha256 ?? '')) fail('invalid_artifact_expectation');
  const digest = await hashVerifiedFile(archive, maxBytes, signal);
  if (digest.bytes !== expectedSize || digest.sha256 !== expectedSha256) fail('artifact_digest_mismatch');
  await secureParents(dirname(destination));
  try { await mkdir(destination, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
  await secureParents(destination);
  if (await realpath(destination) !== resolve(destination)) fail('unsafe_destination');
  const { file, original } = await reader(archive, maxBytes);
  let temporary;
  try {
    // The path must still identify the exact file hashed against GitHub's
    // official digest, including across an unlink/replace between operations.
    await sameFile(file, digest.identity);
    const entries = await directory(file, original.size), candidates = entries.filter(e => !e.isDirectory && /\.ipa$/i.test(e.name));
    const chosen = ipaMember === undefined ? (candidates.length === 1 ? candidates[0] : null) : candidates.find(e => e.name === ipaMember);
    if (!chosen) fail(candidates.length > 1 ? 'multiple_ipas_select_member' : 'ipa_not_found');
    temporary = join(destination, `.ipa-part-${randomUUID()}`);
    const output = await open(temporary, 'wx', 0o600), hash = createHash('sha256');
    try {
      for (const entry of entries) await streamEntry(file, entry, entry === chosen ? async chunk => {
        hash.update(chunk); let at = 0;
        while (at < chunk.length) { const result = await output.write(chunk, at, chunk.length - at); at += result.bytesWritten; }
      } : null, signal);
      await output.sync();
    } finally { await output.close(); }
    await sameFile(file, original);
    const sha256 = hash.digest('hex'), structure = await verifyIpa(temporary, { signal, maxBytes });
    const snapshot = await hashVerifiedFile(temporary, maxBytes, signal);
    if (snapshot.bytes !== chosen.bytes || snapshot.sha256 !== sha256) fail('extracted_ipa_changed');
    const name = basename(chosen.name), published = join(destination, name);
    if (Buffer.byteLength(name) > 128 || Buffer.byteLength(published) > 1024) fail('ipa_name_or_path_limit');
    await secureParents(destination);
    if (signal?.aborted) fail('cancelled');
    try { await link(temporary, published); }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const old = await hashVerifiedFile(published, maxBytes, signal);
      if (old.bytes !== chosen.bytes || old.sha256 !== sha256) fail('existing_ipa_preserved');
    }
    await unlink(temporary); temporary = undefined;
    const parent = await open(destination, 'r'); try { await parent.sync(); } finally { await parent.close(); }
    const final = await hashVerifiedFile(published, maxBytes, signal);
    if (final.bytes !== chosen.bytes || final.sha256 !== sha256) fail('published_ipa_changed');
    return { path: published, name, bytes: chosen.bytes, sha256, artifact_sha256: digest.sha256,
      artifact_zip_crc_verified: true, artifact_entries: entries.length, ...structure };
  } finally { await file.close(); if (temporary) await unlink(temporary).catch(() => {}); }
}
