// Private evidence of bytes that passed the original complete semantic decoder.
// Neither this module nor its diagnostics exports session contents or paths.
import { createHash } from 'node:crypto';
import { open, stat } from 'node:fs/promises';

const decoded = new WeakMap();
const prepared = new WeakMap();
const poisoned = new WeakSet();
const slots = new WeakMap();
const changed = () => Object.assign(new Error('session checkpoint changed'), { code: 'DSH_SESSION_CHECKPOINT_CHANGED' });
const unstable = () => Object.assign(new Error('session checkpoint has no complete stable snapshot'), { code: 'DSH_SESSION_CHECKPOINT_UNSTABLE' });

function slot(backend, id) {
  let entries = slots.get(backend);
  if (!entries) slots.set(backend, entries = new Map());
  let value = entries.get(id);
  if (!value) entries.set(id, value = { epoch: 0, path: undefined });
  return value;
}
function currentSlot(backend, id) { return slots.get(backend)?.get(id); }
function physicalIdentity(value) {
  return [value.dev, value.ino, value.size, value.mtimeNs, value.ctimeNs].map(String).join(':');
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    const result = Object.create(null);
    for (const key of Object.keys(value).sort()) if (value[key] !== undefined) result[key] = canonical(value[key]);
    return result;
  }
  return value;
}
function witness(header, cursor, state) {
  return JSON.stringify(canonical({ header: { ...header, delegationDepth: header.delegationDepth ?? 0 },
    cursor, inheritedEventCount: state.inheritedEventCount,
    tornTruncateTo: state.tornTruncateTo ?? null, recoveredTail: state.recoveredTail ?? [] }));
}
function writerWitness(writer) { return witness(writer.header, writer.state.cursor, writer.state); }
function liveLease(writer) { return writer.lease && !writer.lease.released && !writer.lease.dshUncertain; }
function sameProof(left, right) {
  return left.path === right.path && left.identity === right.identity && left.digest === right.digest
    && left.bytes === right.bytes && left.witness === right.witness;
}
function sameRestoredBytes(left, right) {
  return left.path === right.path && left.fileIdentity === right.fileIdentity
    && left.digest === right.digest && left.bytes === right.bytes && left.witness === right.witness;
}
function poison(writer) {
  poisoned.add(writer);
  const previous = prepared.get(writer);
  if (previous) previous.poisoned = true;
  throw changed();
}

export function beginDecodedSnapshot(backend, id, path) {
  // Standalone read handles do not create persistent per-session bookkeeping.
  // A write-open claim is represented by null and does count as an owner here.
  const entry = backend.tracker.writers.has(id) ? slot(backend, id) : { epoch: 0 };
  entry.path = path;
  return { backend, id, entry, epoch: entry.epoch, owner: backend.tracker.writers.get(id) };
}
export function rememberDecodedSnapshot(stored, path, buffer, snapshot, context) {
  // A bounded-prefix fallback remains useful to ordinary readers, but is never
  // a complete-file proof. Record that provenance so lifecycle cannot mistake it.
  const complete = snapshot?.dshCompleteStable === true
    && BigInt(buffer.byteLength) === snapshot.identity.size;
  const record = { context, complete, proof: undefined };
  if (complete && currentSlot(context.backend, context.id) === context.entry && context.entry.epoch === context.epoch) {
    record.proof = Object.freeze({ path, identity: physicalIdentity(snapshot.identity),
      fileIdentity: [snapshot.identity.dev, snapshot.identity.ino].map(String).join(':'),
      mutationEntry: context.entry, mutationEpoch: context.epoch,
      bytes: buffer.byteLength, digest: createHash('sha256').update(buffer).digest('hex'),
      witness: witness(stored.meta, stored.events.length, stored) });
  }
  decoded.set(stored, record);
}
export function invalidatePreparedCheckpoint(backend, id) {
  const writer = backend.tracker.writers.get(id);
  if (writer && (poisoned.has(writer) || prepared.get(writer)?.poisoned)) throw changed();
  if (!backend.tracker.writers.has(id) && !currentSlot(backend, id)) return;
  slot(backend, id).epoch += 1;
  if (writer) prepared.delete(writer);
}
export function invalidatePreparedPath(backend, path) {
  const entries = slots.get(backend);
  const ids = new Set();
  if (entries) for (const [id, entry] of entries) if (entry.path === path) ids.add(id);
  for (const writer of backend.tracker.writers.values()) {
    if (writer && (prepared.get(writer)?.proof.path === path || backend.locate(writer.header).path === path)) ids.add(writer.id);
  }
  // These are internal mutation entry points. A direct call with an unmapped
  // namespace must not preserve a proof merely because its final path differs.
  if (ids.size === 0) {
    if (entries) for (const id of entries.keys()) ids.add(id);
    for (const writer of backend.tracker.writers.values()) if (writer) ids.add(writer.id);
  }
  for (const id of ids) invalidatePreparedCheckpoint(backend, id);
}
export function retirePreparedCheckpoint(backend, writer) {
  if (writer.access !== 'write' || backend.tracker.writers.get(writer.id) !== writer) return;
  assertCheckpointNotPoisoned(writer);
  const entry = currentSlot(backend, writer.id);
  if (entry) entry.epoch += 1;
  slots.get(backend)?.delete(writer.id);
  prepared.delete(writer);
}
export function retireUnadoptedCheckpoint(backend, id) {
  if (backend.tracker.writers.get(id) !== null) return;
  const entry = currentSlot(backend, id);
  if (entry) entry.epoch += 1;
  slots.get(backend)?.delete(id);
}
export function adoptDecodedCheckpoint(backend, writer, stored, constructing = false) {
  assertCheckpointNotPoisoned(writer);
  const record = decoded.get(stored);
  if (!record || record.context.backend !== backend || record.context.id !== writer.id
      || currentSlot(backend, writer.id) !== record.context.entry || record.context.entry.epoch !== record.context.epoch
      || !liveLease(writer) || writer.access !== 'write'
      || (!constructing && backend.tracker.writers.get(writer.id) !== writer)
      || (record.context.owner && record.context.owner !== writer)) return false;
  const previous = prepared.get(writer);
  if (!record.proof) {
    if (previous) poison(writer);
    return false;
  }
  if (previous?.poisoned || (previous && !sameProof(previous.proof, record.proof))) poison(writer);
  if (record.proof.witness !== writerWitness(writer)) {
    if (previous) poison(writer);
    return false;
  }
  prepared.set(writer, { proof: record.proof, lease: writer.lease,
    epoch: record.context.epoch, entry: record.context.entry, poisoned: false });
  return true;
}
export function checkpointFromDecoded(backend, writer, stored) {
  const record = decoded.get(stored);
  if (!record?.complete || !record.proof) throw unstable();
  if (!adoptDecodedCheckpoint(backend, writer, stored)) throw unstable();
  return record.proof;
}
export function verifyDecodedCheckpoint(backend, writer, stored, checkpoint) {
  const record = decoded.get(stored);
  if (!record?.complete || !record.proof) throw unstable();
  // A retained append can fail and be durably rolled back under our lease.
  // That changes ctime/mtime. Only our explicit pre-write epoch permits this
  // case, and fresh full validation must still prove the identical original
  // bytes, inode, authoritative path and complete logical witness before retry.
  const ownMutation = checkpoint.mutationEntry === record.context.entry
    && checkpoint.mutationEpoch !== record.context.epoch;
  if (!sameProof(record.proof, checkpoint) && !(ownMutation && sameRestoredBytes(record.proof, checkpoint))) poison(writer);
  if (!adoptDecodedCheckpoint(backend, writer, stored)) throw unstable();
}
export function hasPreparedCheckpoint(writer) { return prepared.has(writer); }
export function assertCheckpointNotPoisoned(writer) {
  if (poisoned.has(writer) || prepared.get(writer)?.poisoned) throw changed();
}

export async function verifyPreparedCheckpoint(backend, writer) {
  assertCheckpointNotPoisoned(writer);
  const current = prepared.get(writer);
  if (!current) return undefined;
  if (poisoned.has(writer) || current.poisoned || currentSlot(backend, writer.id) !== current.entry || current.entry.epoch !== current.epoch
      || current.lease !== writer.lease || !liveLease(writer)
      || backend.tracker.writers.get(writer.id) !== writer
      || current.proof.witness !== writerWitness(writer)) poison(writer);
  const proof = current.proof;
  // Keep the original authoritative-generation and duplicate/encoding checks.
  const selected = await backend.findLog(writer.id);
  if (!selected || selected.sourceVersion !== 4 || selected.sourcePath !== proof.path) poison(writer);
  let file;
  try {
    file = await open(proof.path, 'r');
    const before = await file.stat({ bigint: true });
    if (physicalIdentity(before) !== proof.identity) poison(writer);
    const hash = createHash('sha256'); const buffer = Buffer.allocUnsafe(64 * 1024);
    let bytes = 0;
    for (;;) {
      const { bytesRead } = await file.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      bytes += bytesRead;
      if (bytes > proof.bytes) poison(writer);
      hash.update(buffer.subarray(0, bytesRead));
    }
    const after = await file.stat({ bigint: true });
    const pathname = await stat(proof.path, { bigint: true });
    const finalSelected = await backend.findLog(writer.id);
    if (bytes !== proof.bytes || hash.digest('hex') !== proof.digest
        || physicalIdentity(after) !== proof.identity || physicalIdentity(pathname) !== proof.identity
        || !finalSelected || finalSelected.sourceVersion !== 4 || finalSelected.sourcePath !== proof.path
        || currentSlot(backend, writer.id) !== current.entry || current.entry.epoch !== current.epoch || prepared.get(writer) !== current
        || current.lease !== writer.lease || !liveLease(writer)
        || backend.tracker.writers.get(writer.id) !== writer || writerWitness(writer) !== proof.witness) poison(writer);
    return proof;
  } finally { if (file) await file.close(); }
}
