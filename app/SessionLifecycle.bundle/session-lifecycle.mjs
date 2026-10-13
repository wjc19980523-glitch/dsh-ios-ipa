import { SessionLifecycleAdmission, settleLifecycleWriters, lifecycleErrorCode } from './session-lifecycle-core.mjs';
export { SessionLifecycleAdmission, settleLifecycleWriters };

const BASE = process.env.DSH_HOST_BRIDGE_URL;
const TOKEN = process.env.DSH_HOST_BRIDGE_TOKEN;
const ENABLED = process.env.DSH_SESSION_LIFECYCLE === '1';
const backends = new Set();
let started = false;
let latest;
let applying = false;
let completedGeneration = -1;
let pendingAcknowledgement;
let activeAcknowledgement;
let pollEpoch = 0;
const activeRequests = new Set();

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function request(path, body, desired) {
  const controller = new AbortController();
  activeRequests.add(controller);
  if (desired) activeAcknowledgement = { desired, controller };
  // A TCP connection predating a long iOS suspension can remain blackholed.
  // Keep this private control request below the host's 15-second resume window.
  const timer = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch(`${BASE}${path}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', connection: 'close' },
      body: JSON.stringify(body), signal: controller.signal,
    });
    if (!response.ok) throw new Error('lifecycle transport failed');
    return await response.json();
  } finally {
    clearTimeout(timer); activeRequests.delete(controller);
    if (activeAcknowledgement?.controller === controller) activeAcknowledgement = undefined;
  }
}

function snapshot() {
  const result = { writer_count: 0, released_count: 0, pending_events: 0 };
  const diagnostics = {};
  const fields = ['checkpoint_read_ms', 'checkpoint_hash_ms', 'checkpoint_serialized_bytes',
    'drain_ms', 'close_ms', 'acquire_ms', 'active_writer_transitions',
    'peak_writer_transitions', 'transition_ms'];
  for (const backend of backends) {
    const current = backend.dshLifecycleSnapshot();
    for (const key of Object.keys(result)) result[key] += current[key];
    for (const key of fields) {
      const value = current.diagnostics?.[key];
      if (Number.isSafeInteger(value) && value >= 0)
        diagnostics[key] = (diagnostics[key] ?? 0) + value;
    }
  }
  return Object.keys(diagnostics).length === 0 ? result : { ...result, diagnostics };
}

async function applyLatest() {
  if (applying) return;
  applying = true;
  let attemptedDesired;
  try {
    while (latest && completedGeneration !== latest.generation) {
      const desired = latest;
      attemptedDesired = desired;
      if (pendingAcknowledgement?.desired === desired) {
        // The host treats the first terminal ACK as immutable. A lost response
        // retries its exact payload rather than running storage work twice.
        await request('/v1/lifecycle/ack', pendingAcknowledgement.body, desired);
        if (latest !== desired) continue;
        completedGeneration = desired.generation;
        pendingAcknowledgement = undefined;
        continue;
      }
      pendingAcknowledgement = undefined;
      let state;
      let errorCode;
      try {
        if (desired.state === 'quiescing') {
          for (const backend of backends) backend.dshLifecycleBeginQuiesce();
          for (const backend of backends) await backend.dshLifecycleSuspend();
          state = 'quiesced';
        } else {
          // Validate every backend before releasing any paused writer.
          for (const backend of backends) await backend.dshLifecycleResume();
          if (latest !== desired) continue;
          for (const backend of backends) backend.dshLifecycleOpen();
          state = 'running';
        }
      } catch (error) {
        state = 'failed';
        errorCode = lifecycleErrorCode(error);
        for (const backend of backends) backend.dshLifecycleFail();
      }
      if (latest !== desired) continue;
      const body = {
        pid: process.pid, generation: desired.generation, state,
        ...snapshot(), ...(errorCode ? { error_code: errorCode } : {}),
      };
      pendingAcknowledgement = { desired, body };
      await request('/v1/lifecycle/ack', body, desired);
      if (latest !== desired) continue;
      completedGeneration = desired.generation;
      pendingAcknowledgement = undefined;
    }
  } finally {
    applying = false;
    if (latest && latest !== attemptedDesired
        && completedGeneration !== latest.generation)
      queueMicrotask(() => { void applyLatest().catch(() => {}); });
  }
}

async function poll(epoch) {
  while (started && epoch === pollEpoch && backends.size > 0) {
    try {
      // Reuse the ordinary control poll for metadata-only progress. A stale
      // generation cannot complete a transition; the host keeps this separate
      // from immutable terminal ACKs and safety admission decisions.
      const diagnostics = snapshot().diagnostics;
      const desired = await request('/v1/lifecycle/poll', {
        pid: process.pid, after_generation: latest?.generation ?? -1, wait_ms: 3000,
        ...(latest && diagnostics ? { progress_generation: latest.generation, diagnostics } : {}),
      });
      if (desired.protocol !== 1 || !Number.isSafeInteger(desired.generation)
          || desired.generation < 0 || !['running', 'quiescing'].includes(desired.state)
          || (latest && desired.generation < latest.generation)
          || (latest && desired.generation === latest.generation && desired.state !== latest.state))
        throw new Error('invalid lifecycle response');
      if (!latest || desired.generation !== latest.generation) {
        latest = desired;
        // The host may suspend sockets immediately after accepting an ACK.
        // A lost old response must not delay a newer foreground transition.
        // Cancel only control transport; admitted persistence work still drains.
        if (activeAcknowledgement && activeAcknowledgement.desired !== latest)
          activeAcknowledgement.controller.abort();
        // Seal write admission synchronously, before starting async drains.
        if (desired.state === 'quiescing')
          for (const backend of backends) backend.dshLifecycleBeginQuiesce();
      }
      void applyLatest().catch(() => {});
    } catch {
      // A missing bridge cannot change persistence semantics. Once paused,
      // transport errors keep write admission closed until a validated resume.
      if (!started || epoch !== pollEpoch || backends.size === 0) return;
      await sleep(1000);
    }
  }
}

export function registerSessionBackend(backend) {
  if (!ENABLED || !BASE || !TOKEN) return;
  backends.add(backend);
  if (latest?.state === 'quiescing') backend.dshLifecycleBeginQuiesce();
  // A constructor has no writers yet. Sealing it is sufficient after an
  // already acknowledged pause; terminal ACK metadata must never be changed.
  if (BASE && TOKEN && !started) {
    started = true;
    void poll(++pollEpoch);
  }
}

export function unregisterSessionBackend(backend) {
  backends.delete(backend);
  if (backends.size === 0) {
    started = false;
    pollEpoch += 1;
    latest = undefined;
    completedGeneration = -1;
    pendingAcknowledgement = undefined;
    for (const request of activeRequests) request.abort();
  }
}
