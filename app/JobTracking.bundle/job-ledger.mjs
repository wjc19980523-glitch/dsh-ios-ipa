import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdir, open, rename, unlink } from 'node:fs/promises';
import { join, resolve, parse, relative } from 'node:path';

const MAX_BYTES = 256 * 1024;
const MAX_RECORDS = 256;
const RUN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const JOB = /^(bash|terminal|subagent)-[1-9][0-9]{0,15}$/;
const STATES = new Set(['running', 'stopping', 'succeeded', 'failed', 'interrupted', 'unknown']);
const REASONS = new Set(['previous_run_unconfirmed', 'owner_or_service_teardown', 'removed_without_terminal_evidence']);
export const scopeID = owner => typeof owner === 'string' && owner.length > 0
  ? createHash('sha256').update(owner).digest('hex').slice(0, 24) : null;
const digest = records => createHash('sha256').update(JSON.stringify(records)).digest('hex');

// Registry 'completed' includes nonzero shell exits. Never infer success from
// that word, a tool's isError=false, free-form output, or a disappeared record.
export function jobOutcome(job, cause) {
  if (job?.status === 'running' || job?.status === 'stopping') return { state: job.status };
  const exit = job?.kind === 'bash' && /^exit code: (-?[0-9]+)$/.exec(job.detail ?? '');
  if (job?.status === 'completed' && exit && Number.isSafeInteger(Number(exit[1])))
    return { state: Number(exit[1]) === 0 ? 'succeeded' : 'failed', exit_code: Number(exit[1]) };
  const signal = /^signal: (SIG[A-Z0-9]{1,24})(?:;|$)/.exec(job?.detail ?? '');
  if (job?.status === 'killed' && signal)
    return { state: 'interrupted', signal: signal[1] };
  if (job?.status === 'failed' && cause !== 'teardown') return { state: 'failed' };
  return { state: 'unknown' };
}

export function toolOutcome(name, result) {
  if (result?.isError) return { outcome: 'error' };
  const value = result?.value;
  if (name === 'bash') {
    if (value?.kind === 'background' || value?.kind === 'promoted') return { outcome: 'started' };
    if (value?.kind !== 'foreground') return { outcome: 'unknown' };
    if (value.sandbox?.runnerFailed) return { outcome: 'unknown' };
    if (value.sandbox?.denied) return { outcome: 'refused' };
    if (value.signal != null || value.aborted === true || value.stopped !== undefined) return { outcome: 'interrupted' };
    if (value.timedOut === true) return { outcome: 'timed out' };
    if (!Number.isInteger(value.exitCode)) return { outcome: 'unknown' };
    return { outcome: value.exitCode === 0 ? 'ok' : 'error', result: `exit ${value.exitCode}` };
  }
  if (name === 'job_output') {
    const state = jobOutcome(value?.job).state;
    return { outcome: ({ succeeded: 'ok', failed: 'error', interrupted: 'interrupted',
      running: 'started', stopping: 'started', unknown: 'unknown' })[state] };
  }
  if (name === 'job_kill') return { outcome: 'unknown', result: 'cancellation requested; confirm terminal state' };
  return { outcome: 'ok' };
}

function validRecord(r) {
  return r && typeof r.run_id === 'string' && typeof r.job_id === 'string' &&
    typeof r.scope_id === 'string' && RUN.test(r.run_id) && JOB.test(r.job_id) &&
    r.execution_id === `${r.run_id}:${r.job_id}` && /^[a-f0-9]{24}$/.test(r.scope_id) &&
    STATES.has(r.state) && Number.isSafeInteger(r.observed_at) && r.observed_at >= 0 &&
    (r.exit_code === undefined || Number.isSafeInteger(r.exit_code)) &&
    (r.signal === undefined || (typeof r.signal === 'string' && /^SIG[A-Z0-9]{1,24}$/.test(r.signal))) &&
    (r.removed === undefined || typeof r.removed === 'boolean') &&
    (r.reason === undefined || REASONS.has(r.reason)) &&
    (r.state !== 'succeeded' || r.exit_code === 0);
}
function cleanRecord(r) {
  return Object.fromEntries(['run_id', 'job_id', 'execution_id', 'scope_id', 'state', 'observed_at',
    'exit_code', 'signal', 'removed', 'reason'].filter(k => r[k] !== undefined).map(k => [k, r[k]]));
}

export class JobLedger {
  constructor(home, { runID = randomUUID(), now = Date.now, fs = { lstat, mkdir, open, rename, unlink } } = {}) {
    if (!RUN.test(runID)) throw new Error('invalid tracking run');
    this.runID = runID; this.now = now; this.fs = fs;
    this.directory = join(resolve(home), '.job-history'); this.path = join(this.directory, 'v1.json');
    this.records = new Map(); this.pending = []; this.storage = 'loading'; this.evicted = 0;
    this.ready = this.load(); this.queue = this.ready;
  }
  async checkParents(allowMissingLast = false) {
    const root = parse(this.directory).root;
    let cursor = root;
    for (const component of relative(root, this.directory).split(/[\\/]/).filter(Boolean)) {
      cursor = join(cursor, component);
      let stat;
      try { stat = await this.fs.lstat(cursor); }
      catch (error) { if (allowMissingLast && cursor === this.directory && error.code === 'ENOENT') return; throw error; }
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('unsafe journal directory');
    }
  }
  async load() {
    try {
      await this.checkParents(true);
      try { await this.fs.mkdir(this.directory, { mode: 0o700 }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
      await this.checkParents();
      let stat;
      try { stat = await this.fs.lstat(this.path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (stat) {
        if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > MAX_BYTES)
          throw new Error('unsafe journal file');
        const file = await this.fs.open(this.path, 'r');
        let bytes;
        try { bytes = await file.readFile(); } finally { await file.close(); }
        if (bytes.length > MAX_BYTES) throw new Error('oversized journal');
        const data = JSON.parse(bytes.toString('utf8'));
        if (data.schema !== 1 || !Array.isArray(data.records) || data.records.length > MAX_RECORDS ||
            data.digest !== digest(data.records) || !data.records.every(validRecord)) throw new Error('invalid journal');
        for (const original of data.records) {
          const record = cleanRecord(original);
          if (this.records.has(record.execution_id)) throw new Error('duplicate journal record');
          if (record.run_id !== this.runID && ['running', 'stopping'].includes(record.state)) {
            record.state = 'unknown'; record.reason = 'previous_run_unconfirmed';
          }
          this.records.set(record.execution_id, record);
        }
      }
      this.storage = 'available';
    } catch {
      // Preserve an unreadable/unknown file. No replacement, reset, or deletion.
      this.records.clear(); this.storage = 'unavailable';
    }
    for (const event of this.pending.splice(0)) this.update(event);
    this.schedule();
  }
  observe(event) {
    const job = event?.job;
    if (!job || !JOB.test(job.id) || !scopeID(job.owner)) return;
    const safe = { type: event.type, job: { id: job.id }, scope: scopeID(job.owner),
      outcome: jobOutcome(job, event.cause), ...(event.cause === 'teardown' ? { cause: 'teardown' } : {}) };
    if (this.storage === 'loading') { if (this.pending.length < 1024) this.pending.push(safe); return; }
    this.update(safe); this.schedule();
  }
  update(event) {
    const job = event?.job;
    const scope = event.scope;
    if (!job || !JOB.test(job.id) || !scope || !['registered', 'stopping', 'settled', 'removed'].includes(event.type)) return;
    const execution = `${this.runID}:${job.id}`;
    const prior = this.records.get(execution);
    // A terminal observation is immutable; late progress/removal cannot revive it.
    if (prior && !['running', 'stopping'].includes(prior.state)) {
      if (event.type === 'removed') prior.removed = true;
      return;
    }
    const outcome = event.outcome;
    const record = { run_id: this.runID, job_id: job.id, execution_id: execution, scope_id: scope,
      ...outcome, observed_at: Math.max(0, Math.trunc(this.now())),
      ...(event.type === 'removed' ? { removed: true } : {}),
      ...(event.cause === 'teardown' ? { reason: 'owner_or_service_teardown' } : {}) };
    if (event.type === 'removed' && ['running', 'stopping'].includes(record.state)) {
      record.state = 'unknown'; record.reason = 'removed_without_terminal_evidence';
    }
    this.records.delete(execution); this.records.set(execution, record);
    while (this.records.size > MAX_RECORDS) {
      const terminal = [...this.records.values()].find(r => !['running', 'stopping'].includes(r.state));
      this.records.delete(terminal?.execution_id ?? this.records.keys().next().value); this.evicted++;
    }
  }
  schedule() {
    this.dirty = true;
    if (this.saving) return;
    this.saving = true;
    this.queue = this.queue.then(async () => {
      do { this.dirty = false; await this.save(); } while (this.dirty && this.storage === 'available');
    }).catch(() => { this.storage = 'unavailable'; }).finally(() => {
      this.saving = false;
      if (this.dirty && this.storage === 'available') this.schedule();
    });
  }
  async save() {
    if (this.storage !== 'available') return;
    await this.checkParents();
    let previous;
    try {
      previous = await this.fs.lstat(this.path);
      if (!previous.isFile() || previous.isSymbolicLink() || previous.nlink !== 1) throw new Error('unsafe journal');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const records = [...this.records.values()].map(cleanRecord);
    const bytes = Buffer.from(JSON.stringify({ schema: 1, digest: digest(records), records }));
    if (bytes.length > MAX_BYTES) throw new Error('oversized journal');
    const temporary = join(this.directory, `${this.runID}-${randomUUID()}.tmp`);
    let created = false;
    try {
      const file = await this.fs.open(temporary, 'wx', 0o600); created = true;
      try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
      // Refuse a link or target replacement that happened during the write.
      let current;
      try { current = await this.fs.lstat(this.path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if ((previous && (!current || current.ino !== previous.ino || current.dev !== previous.dev || current.nlink !== 1)) ||
          (!previous && current) || current?.isSymbolicLink()) throw new Error('journal target changed');
      await this.fs.rename(temporary, this.path); created = false;
      const directory = await this.fs.open(this.directory, 'r');
      try { await directory.sync(); } finally { await directory.close(); }
    } finally { if (created) await this.fs.unlink(temporary).catch(() => {}); }
  }
  async flush() { await this.ready; do { await this.queue; } while (this.saving); }
  async list(owner) {
    await this.ready;
    const scope = scopeID(owner);
    return { persistence: this.storage, pending_writes: this.saving || this.dirty || false,
      run_id: this.runID, scope_id: scope, retention_limit: MAX_RECORDS,
      evicted_this_run: this.evicted, records: scope ? [...this.records.values()].filter(r => r.scope_id === scope).map(r => ({ ...r })) : [] };
  }
  async status(execution, owner) {
    const history = await this.list(owner);
    return { ...history, records: undefined, record: history.records.find(r => r.execution_id === execution) ?? null,
      notice: 'Metadata only. Missing or unknown does not mean succeeded, running, or safe to repeat. No process is restarted.' };
  }
}
