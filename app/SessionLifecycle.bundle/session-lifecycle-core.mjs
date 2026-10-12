import { AsyncLocalStorage } from 'node:async_hooks';

// One backend's write admission. Tickets are revoked after their operation,
// so timers inheriting an old async context cannot bypass a later pause.
export class SessionLifecycleAdmission {
  state = 'running';
  active = 0;
  context = new AsyncLocalStorage();
  runningWaiters = [];
  idleWaiters = [];
  failure;

  run(operation) {
    const inherited = this.context.getStore();
    const admitted = inherited?.owner === this && inherited.active;
    if (!admitted && this.failure) return Promise.reject(this.failure);
    if (!admitted && this.state !== 'running')
      return this.whenRunning().then(() => this.run(operation));
    this.active += 1;
    const ticket = { owner: this, active: true };
    return Promise.resolve().then(() => this.context.run(ticket, operation)).finally(() => {
      ticket.active = false;
      this.active -= 1;
      if (this.active === 0) this.idleWaiters.splice(0).forEach(resolve => resolve());
    });
  }

  close() { this.state = 'quiescing'; }

  async drain(operation) {
    if (this.active !== 0) await new Promise(resolve => this.idleWaiters.push(resolve));
    const ticket = { owner: this, active: true };
    try { return await this.context.run(ticket, operation); }
    finally {
      ticket.active = false;
      if (this.active !== 0) await new Promise(resolve => this.idleWaiters.push(resolve));
    }
  }

  markQuiesced() { this.state = 'quiesced'; }
  beginResume() { this.state = 'resuming'; }
  fail() {
    this.state = 'failed';
    this.failure ??= Object.assign(new Error('session persistence lifecycle failed'), {
      code: 'DSH_SESSION_LIFECYCLE_FAILED',
    });
    this.runningWaiters.splice(0).forEach(waiter => waiter.reject(this.failure));
  }
  open() {
    this.failure = undefined;
    this.state = 'running';
    this.runningWaiters.splice(0).forEach(waiter => waiter.resolve());
  }
  whenRunning() {
    if (this.failure) return Promise.reject(this.failure);
    return this.state === 'running' ? Promise.resolve()
      : new Promise((resolve, reject) => this.runningWaiters.push({ resolve, reject }));
  }
}

export function lifecycleErrorCode(error) {
  if (error?.code === 'DSH_SESSION_CHECKPOINT_CHANGED') return 'checkpoint_changed';
  if (error?.code === 'DSH_SESSION_NOT_MATERIALIZED') return 'not_materialized';
  if (error?.name === 'SessionAlreadyOwnedError') return 'ownership_conflict';
  if (error?.code === 'EIO' || error?.code === 'ENOSPC') return 'storage_failure';
  if (error?.code === 'DSH_SESSION_STORAGE_UNCERTAIN') return 'storage_failure';
  if (error?.code === 'EBADF') return 'close_failure';
  if (error?.code === 'DSH_SESSION_LEASE_UNCERTAIN') return 'close_failure';
  return 'transition_failed';
}
