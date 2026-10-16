// Test-owned cleanup only. Preserve the first failure while releasing every resource.
export function captureBridgeLedger(ctx, apply, receive) {
  // Cordis returns a new context-tracing proxy for each service lookup. Observe
  // the exact proxies used by apply; do not substitute a different registry key.
  const descriptor = Object.getOwnPropertyDescriptor(ctx, 'get');
  const originalGet = ctx.get, lookups = [];
  Object.defineProperty(ctx, 'get', { configurable: true, writable: true, value: function (...args) {
    const value = originalGet.apply(this, args);
    if (args[0] === 'jobs') lookups.push(value);
    return value;
  } });
  try { return apply(); }
  finally {
    if (descriptor) Object.defineProperty(ctx, 'get', descriptor);
    else delete ctx.get;
    const singletons = globalThis[Symbol.for('dsh.jobTracking.v1')];
    const ledgers = new Set(lookups.map(jobs => singletons?.get(jobs)).filter(Boolean));
    for (const ledger of ledgers) receive(ledger);
  }
}

export async function cleanupJobTrackingFixture({ jobs, ctx, ledger, trackingLedger,
  checkChildren = () => {}, remove, closeServer, restoreEnvironment,
  step = (_stage, operation) => operation() }) {
  let failed = false, firstError;
  const attempt = async (stage, operation) => {
    try { await step(stage, operation); }
    catch (error) { if (!failed) { failed = true; firstError = error; } }
  };
  try {
    // disposeAll emits the final removed events; context disposal then detaches
    // subscriptions and the bridge activity timer before either journal is drained.
    await attempt('fixture:jobs.disposeAll', () => jobs.disposeAll());
    await attempt('bridge:ctx.dispose', () => ctx.fiber.dispose());
    await attempt('bridge:ledger.flush', () => trackingLedger?.flush());
    if (ledger !== trackingLedger) await attempt('fixture:ledger.flush', () => ledger.flush());
    await attempt('fixture:children.stop', checkChildren);
    await attempt('fixture:rm', remove);
  } finally {
    await attempt('bridge:server.close', closeServer);
    await attempt('bridge:env.restore', restoreEnvironment);
  }
  if (failed) throw firstError;
}

export function closeFixtureServer(server) {
  if (!server) return;
  return new Promise((resolve, reject) => {
    server.close(error => {
      if (error && error.code !== 'ERR_SERVER_NOT_RUNNING') reject(error);
      else resolve();
    });
    // Call after close begins so a connection cannot enter between the two calls.
    server.closeAllConnections();
  });
}
