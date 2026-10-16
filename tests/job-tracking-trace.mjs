// Optional test diagnostics: synchronous append only, with no test-runner import.
import { appendFileSync, writeSync } from 'node:fs';
import { resolve } from 'node:path';

const destination = process.env.DSH_JOB_TRACE_FILE
  ? `${resolve(process.env.DSH_JOB_TRACE_FILE)}.${process.pid}.jsonl` : null;
const contexts = new WeakMap();
const FILE_TAGS = new Set(['runner', 'job-ledger-test', 'job-tracking-runtime-test', 'development-tools-test']);
const AWAIT_STAGES = new Set([
  'fixture:ledger.ready', 'fixture:ledger.flush', 'fixture:jobs.disposeAll', 'fixture:rm',
  'fixture:server.listen', 'fixture:server.close', 'bridge:server.listen', 'bridge:server.close',
  'bridge:ctx.dispose', 'bridge:ledger.flush', 'bridge:env.restore', 'fixture:children.stop',
  'registration:server.listen', 'registration:jobs.disposeAll', 'registration:ledger.flush',
  'registration:ctx.dispose', 'registration:server.close', 'registration:rm',
  'plugin:rm', 'progress:ledger.flush', 'progress:rm',
  'cli:close', 'cli:finally.close', 'cli:preflight-or-invalid.close',
  'proxy:server.listen', 'proxy:server.close',
]);
const IMPORT_STAGES = ['import:cordis', 'import:jobs-local', 'import:system-prompt',
  'import:tools', 'import:tool-bash', 'import:tool-jobs'];
const EVENTS = new Set([
  'bootstrap', 'beforeExit', 'exit', 'file:bootstrap', 'file:registered',
  'body:start', 'body:done', 'body:error', 'after:last',
  ...[...AWAIT_STAGES, ...IMPORT_STAGES].flatMap(stage =>
    ['start', 'done', 'error'].map(boundary => `${stage}:${boundary}`)),
]);

function traceFailure(code) {
  if (process.exitCode == null || process.exitCode === 0 || process.exitCode === '0') process.exitCode = 1;
  try { writeSync(2, `${code}\n`); } catch {}
  const error = new Error(code);
  error.code = code;
  return error;
}

function append(fileTag, event, caseID, exitCode) {
  if (!destination) return;
  if (!FILE_TAGS.has(fileTag) || !EVENTS.has(event)) throw traceFailure('DSH_JOB_TRACE_INVALID_FIELD');
  const row = { schema: 1, phase: 'job-tracking', pid: process.pid, ppid: process.ppid,
    monotonic_ns: process.hrtime.bigint().toString(), fileTag, event };
  if (event === 'bootstrap') row.node_version = process.version;
  if (caseID !== undefined) row.case_id = caseID;
  if (exitCode !== undefined) row.exit_code = exitCode;
  try { appendFileSync(destination, `${JSON.stringify(row)}\n`, { encoding: 'utf8', mode: 0o600 }); }
  catch { throw traceFailure('DSH_JOB_TRACE_WRITE_FAILED'); }
}

export function traceStage(fileTag, event, context) {
  append(fileTag, event, context && contexts.get(context));
}

export function traceAwait(fileTag, stage, context, operation) {
  if (!destination) return operation();
  if (!FILE_TAGS.has(fileTag) || !AWAIT_STAGES.has(stage)) throw traceFailure('DSH_JOB_TRACE_INVALID_FIELD');
  traceStage(fileTag, `${stage}:start`, context);
  let result;
  try { result = operation(); }
  catch (error) { traceStage(fileTag, `${stage}:error`, context); throw error; }
  return Promise.resolve(result).then(value => {
    traceStage(fileTag, `${stage}:done`, context); return value;
  }, error => {
    traceStage(fileTag, `${stage}:error`, context); throw error;
  });
}

export function createTracedTest(nodeTest, fileTag) {
  if (!destination) return nodeTest;
  if (!FILE_TAGS.has(fileTag)) throw traceFailure('DSH_JOB_TRACE_INVALID_FIELD');
  let nextCaseID = 0;
  return function tracedTest(...args) {
    const caseID = ++nextCaseID;
    const index = args.length - 1, callback = args[index];
    if (typeof callback !== 'function') return nodeTest.apply(this, args);
    args[index] = function tracedBody(context, ...rest) {
      contexts.set(context, caseID);
      append(fileTag, 'body:start', caseID);
      const afterMarker = () => context.after(() => append(fileTag, 'after:last', caseID));
      const done = value => {
        append(fileTag, 'body:done', caseID); afterMarker(); return value;
      };
      const failed = error => {
        append(fileTag, 'body:error', caseID); afterMarker(); throw error;
      };
      let result;
      try { result = callback.call(this, context, ...rest); }
      catch (error) { return failed(error); }
      // A synchronous callback remains synchronous; body:done is not case success.
      if (result && typeof result.then === 'function') return result.then(done, failed);
      return done(result);
    };
    return nodeTest.apply(this, args);
  };
}

if (destination) {
  append('runner', 'bootstrap');
  process.on('beforeExit', code => {
    try { append('runner', 'beforeExit', undefined, code); } catch {}
  });
  process.on('exit', code => {
    try { append('runner', 'exit', undefined, code); } catch {}
  });
}
