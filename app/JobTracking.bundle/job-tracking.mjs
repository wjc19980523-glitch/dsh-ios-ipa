import { JobLedger, jobOutcome, toolOutcome, scopeID } from './job-ledger.mjs';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { developmentPreflight } from './development-tools.mjs';
import { installWorkspaceExport } from './workspace-export.mjs';

const singletons = globalThis[Symbol.for('dsh.jobTracking.v1')] ??= new WeakMap();
const stateText = state => ({ succeeded: 'succeeded (exit 0)', failed: 'failed',
  interrupted: 'interrupted', unknown: 'unknown; do not assume success or repeat',
  running: 'still registered as running', stopping: 'cancellation requested; not yet stopped' })[state];

// Passive host-plane observer. Does not spawn, kill, replay, or restore jobs.
export function installJobTracking(ctx, defineTool, options = {}) {
  installWorkspaceExport(ctx, defineTool, options.workspaceExport ?? {});
  const jobs = ctx.get('jobs');
  if (!jobs) return;
  let ledger = singletons.get(jobs);
  if (!ledger) {
    ledger = new JobLedger(options.home ?? process.env.DSH_HOME ?? `${homedir()}/.dsh`, options);
    singletons.set(jobs, ledger);
  }
  jobs.events.subscribe({ owners: 'scope' }, event => { ledger.observe(event); });
  // Numeric output observations only, kept in memory. A quiet compiler is not
  // proof of a hung process; observing progress must never cancel or replay it.
  const progress = ledger.liveProgress ??= new Map();
  jobs.events.subscribe({ owners: 'scope' }, event => {
    const id = event.job?.id ?? event.id, owner = event.job?.owner ?? event.owner;
    const total = event.job?.output?.total ?? event.total;
    if (!/^(bash|terminal|subagent)-[1-9][0-9]{0,15}$/.test(id ?? '') ||
        !scopeID(owner) || !Number.isSafeInteger(total) || total < 0) return;
    const key = `${scopeID(owner)}:${id}`, prior = progress.get(key);
    progress.set(key, { total, lastOutputAt: total > (prior?.total ?? 0) ? ledger.now() : prior?.lastOutputAt ?? null });
    while (progress.size > 256) progress.delete(progress.keys().next().value);
  });
  const systemPrompt = ctx.get('systemPrompt');
  systemPrompt?.section({ name: 'dsh:durable-job-status', order: systemPrompt.getSectionOrder('TOOL_JOBS'), text:
    'Background jobs are scoped to the owning session and current Harness run. Keep every returned jobId. '
    + 'Use job_output for live output and job_status/job_history for retained metadata. '
    + 'job_output(wait:true) can return still running; that is not completion. '
    + 'completed is successful only with exit code 0. An empty job_list or unknown/interrupted history is not success '
    + 'and is never permission to repeat a side-effecting command. A saved record does not restore a process. '
    + 'A DSH background job does not grant iOS background execution. '
    + 'Call development_preflight before installing a compiler or beginning a build. Native iOS IPA compilation requires '
    + 'a verified real Mac/Xcode/iPhoneOS SDK; do not repeatedly download Linux Swift or invent musl/glibc shims to claim an IPA build. '
    + 'Check the lockfile, installed tools and exact package versions before any install; keep the current job ID rather than starting a duplicate. '
    + 'For explicit dependency-file downloads with a trusted expected SHA256, use bash to run '
    + 'node /usr/local/lib/dsh-plugins/dsh-host-bridge/development-tools.mjs download <https-url> <absolute-destination> <expected-sha256>. '
    + 'Quote each argument. This helper reuses a checksum-matching file, refuses overwrite and concurrent transfers, '
    + 'bounds connect/stall/total time, verifies before publication and never retries automatically. '
    + 'It does not install packages or speed up a slow network. Do not use arbitrary downloaded hashes as independent trust evidence. '
    + 'job_status includes live numeric output observations; no recent output alone is not proof of a hang.' });
  // Harness passes (arguments, validated output); rendering the first argument
  // would put an object in text and invalidate the next model request.
  const output = { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] };
  ctx.tools.register(defineTool({ name: 'development_preflight', description:
    'Read the actual development environment before installing tools. Native iOS requires a real Mac/Xcode; no install, network request or build is started.',
    parameters: { target: { type: 'string', required: true, enum: ['native-ios', 'web', 'script'] } }, output,
    async execute(args) { return JSON.stringify(await developmentPreflight(args.target)); } }));
  ctx.tools.register(defineTool({ name: 'job_history', description:
    'Read bounded, private task metadata for this session across Harness runs. Does not execute or restart work.',
    parameters: {}, output, async execute(_args, exec) {
      const history = await ledger.list(exec.agent?.id);
      return JSON.stringify({ ...history, records: history.records.slice(-50), truncated: history.records.length > 50,
        notice: 'No commands or output retained. Prior running tasks are unknown after a new run. Use execution_id for unambiguous lookup.' });
    } }));
  ctx.tools.register(defineTool({ name: 'job_status', description:
    'Read retained status by execution_id (run UUID plus job ID), within this session. No process is restarted.',
    parameters: { execution_id: { type: 'string', required: true, description: 'Exact execution_id from job_history or tracking notice.' } },
    output, async execute(args, exec) {
      if (typeof args.execution_id !== 'string' || args.execution_id.length > 100) throw new Error('invalid execution id');
      const status = await ledger.status(args.execution_id, exec.agent?.id);
      if (status.record?.run_id === ledger.runID) {
        try {
          const live = jobs.get(status.record.job_id, exec.agent?.id);
          const observation = progress.get(`${scopeID(exec.agent?.id)}:${live.id}`);
          const now = ledger.now(), silence = observation?.lastOutputAt == null ? null : Math.max(0, now - observation.lastOutputAt);
          status.live = { state: jobOutcome(live).state, output_bytes: live.output?.total ?? null,
            last_output_at: observation?.lastOutputAt ?? null, silence_ms: silence,
            observation: ['running', 'stopping'].includes(live.status) ?
              silence === null ? 'no_output_observed' : silence >= 60000 ? 'no_recent_output' : 'output_observed_recently' : 'terminal',
            notice: 'Output bytes are an observation, not proof of build progress. Silence alone never establishes a hang or authorizes cancellation/retry.' };
        } catch { status.live = { state: 'unknown', observation: 'registry_entry_unavailable' }; }
      }
      return JSON.stringify(status);
    } }));
  ctx.on('tools/post-execute', async (exec, result, next) => {
    const decision = await next();
    if (!['bash', 'job_output', 'job_list', 'job_kill'].includes(exec.name) || decision.kind !== 'accept' ||
        Object.hasOwn(decision, 'value') || Object.hasOwn(decision, 'content')) return decision;
    try {
      const value = result.value;
      let note;
      if (exec.name === 'bash' && ['background', 'promoted'].includes(value?.kind)) {
        const live = jobs.get(value.jobId, exec.agent?.id);
        ledger.observe({ type: 'registered', job: live });
        note = `Task remains registered; execution_id=${ledger.runID}:${live.id}. Continue with job_output; do not start a duplicate.`;
      } else if (exec.name === 'job_list' && Array.isArray(value) && value.length === 0) {
        note = 'No live registry entries visible in this session. This does not prove previous tasks succeeded or stopped. Consult job_history; do not repeat work automatically.';
      } else if (exec.name === 'job_output') {
        note = `Task evidence: ${stateText(jobOutcome(value?.job).state)}. execution_id=${ledger.runID}:${value?.job?.id ?? 'unavailable'}.`;
      } else if (exec.name === 'bash') {
        const status = toolOutcome('bash', result);
        note = `Command evidence: ${status.outcome}${status.result ? ` (${status.result})` : ''}. No background job ID was returned; do not infer promotion.`;
      } else note = 'Cancellation request is not proof of process exit. Collect terminal status before claiming stopped.';
      return { ...decision, content: [...result.content ?? [], { type: 'text', text: `[DSH task tracking] ${note}` }] };
    } catch {
      return { ...decision, content: [...result.content ?? [], { type: 'text', text:
        '[DSH task tracking] Live task identity is unavailable. Consult job_history; neither success nor permission to retry is established.' }] };
    }
  });
  return ledger;
}
export { toolOutcome };

// The current Harness session/event payload stores tool results in messages;
// it does not expose structured exit status there. Observe the actual tool
// pipeline instead. No command arguments, output, or free-form errors leave it.
export function installTaskActivity(ctx, push) {
  const starts = new WeakMap();
  const emit = event => { try { push(event); } catch {} };
  ctx.on('tools/pre-execute', (exec, next) => {
    const name = /^[a-zA-Z0-9_.:-]{1,80}$/.test(exec.name) ? exec.name : 'tool';
    const call = { id: randomUUID(), name, at: Date.now() };
    starts.set(exec, call);
    emit({ id: call.id, name, outcome: 'started', result: `scope=${scopeID(exec.agent?.id) ?? 'unowned'}` });
    return next();
  });
  ctx.on('tools/post-execute', async (exec, result, next) => {
    const decision = await next();
    const call = starts.get(exec); starts.delete(exec);
    if (call) emit({ id: call.id, name: call.name, ...toolOutcome(call.name, result),
      duration: Math.max(0, Date.now() - call.at) / 1000 });
    return decision;
  });
  ctx.get('jobs')?.events.subscribe({ owners: 'scope' }, event => {
    if (!['registered', 'stopping', 'settled'].includes(event.type)) return;
    const job = event.job;
    if (!/^(bash|terminal|subagent)-[1-9][0-9]{0,15}$/.test(job?.id) || !scopeID(job.owner)) return;
    const state = jobOutcome(job, event.cause).state;
    emit({ id: `job:${process.pid}:${job.id}`, name: 'background_job',
      outcome: ({ running: 'started', stopping: 'started', succeeded: 'ok', failed: 'error',
        interrupted: 'interrupted', unknown: 'unknown' })[state],
      result: `job=${job.id}; scope=${scopeID(job.owner)}; state=${state}` });
  });
}
