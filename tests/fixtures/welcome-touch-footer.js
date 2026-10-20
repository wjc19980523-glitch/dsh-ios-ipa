// CONDITIONAL REAL-WK FIXTURE ONLY. Append after the SAME manifest helper.
// No DOM writes, layout/style reads, synthetic input, eval or automatic retry.
(() => {
  'use strict';
  const ids = ['original', 'quick', 'slow', 'pending', 'retry-false', 'retry-reject', 'drag', 'cleaned'];
  const cases = new Map();
  let resolvePending = null;
  const buttons = new Map(ids.map(id => {
    const button = document.getElementById('welcome-' + id);
    if (button === null || button.tagName !== 'BUTTON') throw new Error('Welcome fixture button missing');
    return [id, button];
  }));
  const resolveButton = document.getElementById('welcome-resolve-false');
  if (resolveButton === null || resolveButton.tagName !== 'BUTTON') throw new Error('Welcome fixture control missing');

  function snapshot(record) {
    return {
      version: 1, scenario: record.id,
      touchStarts: record.touchStarts, trustedEnds: record.trustedEnds,
      moves: record.moves, cancels: record.cancels,
      naturalClicks: record.naturalClicks, blockedClicks: record.blockedClicks,
      preventedEnds: record.preventedEnds, uncancelableEnds: record.uncancelableEnds,
      ackCalls: record.ackCalls, finishes: record.finishes,
      rejections: record.rejections, settled: record.settled, controls: record.controls,
      status: record.state.status, acknowledged: record.state.acknowledged,
      disposed: record.disposed,
      ambiguousClicks: record.binding?.inspect().ambiguousClicks ?? 0,
    };
  }
  function publish(record) {
    // Only fixed enum + finite nonnegative counters + booleans leave the page.
    window.webkit.messageHandlers.dshWelcomeFixture.postMessage(snapshot(record));
  }
  function create(id) {
    const record = {id, state: {status: 'ready', acknowledged: false},
      touchStarts: 0, trustedEnds: 0, moves: 0, cancels: 0,
      naturalClicks: 0, blockedClicks: 0, preventedEnds: 0, uncancelableEnds: 0,
      ackCalls: 0, finishes: 0, rejections: 0, settled: 0, controls: 0,
      disposed: false, binding: null};
    cases.set(id, record);
    return record;
  }
  function observe(record, button) {
    button.addEventListener('touchstart', event => {
      if (event.isTrusted) {record.touchStarts++; publish(record);}
    }, {passive: true});
    button.addEventListener('touchmove', event => {
      if (event.isTrusted) {record.moves++; publish(record);}
    }, {passive: true});
    // Installed AFTER binder, so defaultPrevented is the actual final decision.
    button.addEventListener('touchend', event => {
      if (!event.isTrusted) return;
      record.trustedEnds++;
      if (event.defaultPrevented) record.preventedEnds++;
      if (!event.cancelable) record.uncancelableEnds++;
      publish(record);
    }, {passive: true});
    for (const type of ['touchcancel', 'pointercancel']) button.addEventListener(type, event => {
      if (event.isTrusted) {record.cancels++; publish(record);}
    }, {passive: true});
    button.addEventListener('click', event => {
      if (!event.isTrusted) return;
      record.naturalClicks++;
      if (record.id === 'original') {
        record.blockedClicks++;
        event.preventDefault();
        event.stopImmediatePropagation();
      }
      publish(record);
    }, {capture: true});
  }
  function answer(record) {
    const count = record.ackCalls;
    if (record.id === 'pending' && count === 1) return new Promise(resolve => {resolvePending = resolve;});
    if (record.id === 'retry-reject' && count === 1) return Promise.reject(new Error('controlled fixture reject'));
    if (record.id === 'quick') return false;
    if (record.id === 'retry-false' && count === 1) return false;
    return true;
  }
  for (const id of ids) {
    const record = create(id), button = buttons.get(id);
    if (id === 'original') {
      // The capture listener below withholds the REAL compatibility click.
      // Original click-only action is never invoked by touchend or script.
      button.onclick = event => {
        if (!event.isTrusted) return;
        record.ackCalls++;
        publish(record);
      };
    } else {
      record.binding = dshBindWelcomeTouch(button, {
        getState: () => record.state,
        acknowledge: () => {
          record.ackCalls++;
          record.state.status = 'saving';
          publish(record);
          return Promise.resolve().then(() => answer(record)).then(confirmed => {
            record.state.acknowledged = confirmed === true;
            record.state.status = confirmed === true ? 'ready' : 'error';
            return confirmed === true;
          }, () => {
            record.state.status = 'error';
            throw new Error('controlled fixture reject');
          }).finally(() => {
            record.settled++;
            publish(record);
          });
        },
        finish: () => {record.finishes++; publish(record);},
        onRejected: () => {record.rejections++; publish(record);},
      });
      button.onclick = event => { void record.binding.onClick(event); };
      if (id === 'cleaned') {record.binding.cleanup(); record.disposed = true;}
    }
    observe(record, button);
    publish(record);
  }
  resolveButton.onclick = event => {
    if (!event.isTrusted) return;
    const record = cases.get('pending');
    record.controls++;
    if (resolvePending !== null) {
      const resolve = resolvePending;
      resolvePending = null;
      resolve(false);
    }
    // A real control interaction also re-publishes every accumulated count;
    // Native can confirm no late natural click appeared before the next step.
    for (const item of cases.values()) publish(item);
  };
})();
