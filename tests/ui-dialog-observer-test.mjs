import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import assert from 'node:assert/strict';
import {test} from 'node:test';

// Execute the exact script compiled into the WKUserScript, with guarded DOM
// fixtures. This tests observation/privacy/bounds, not delivery by iOS WebKit.
const source = readFileSync(new URL('../app/DSHRootViewController.m', import.meta.url), 'utf8');
const literals = source.split('// BEGIN DSH_GUEST_DIALOG_OBSERVER')[1]
  .split('// END DSH_GUEST_DIALOG_OBSERVER')[0].match(/@?"(?:[^"\\]|\\.)*"/g);
const script = literals.map(s => JSON.parse(s.replace(/^@/, ''))).join('');

function fixture({title = 'Preview Notice', button = 'Continue', inert = false, underRoot = false, bridge = true} = {}) {
  const messages = [], listeners = [], microtasks = [], frames = [], timers = [];
  const secret = 'fixture-secret-that-must-never-be-read';
  const fail = () => { throw new Error('observer tried to read/write credential or interact with DOM'); };
  const root = {contains: value => underRoot && value === dialog};
  Object.defineProperty(root, 'inert', {get: () => inert, set: fail});
  const child = {};
  const action = {textContent: button, disabled: false, parentElement: null,
    contains: value => value === child,
    getBoundingClientRect: () => ({x: 100, y: 200, width: 120, height: 36}),
    click: fail, focus: fail};
  Object.defineProperty(action, 'value', {get: fail, set: fail});
  const heading = {textContent: title};
  const dialog = {isConnected: true, parentElement: underRoot ? root : null,
    querySelector: selector => { assert.equal(selector, 'h2'); return heading; },
    querySelectorAll: selector => { assert.equal(selector, 'button'); return [action]; }};
  Object.defineProperties(dialog, {textContent: {get: fail}, innerHTML: {get: fail}, outerHTML: {get: fail}});
  action.parentElement = dialog;
  let hit = child, dialogs = [dialog];
  const document = {
    documentElement: {},
    querySelectorAll: selector => { assert.equal(selector, '[role="dialog"]'); return dialogs; },
    getElementById: id => { assert.equal(id, 'root'); return root; },
    elementFromPoint: (x, y) => { assert.equal(x, 160); assert.equal(y, 218); return hit; },
  };
  let observer;
  const window = {
    innerWidth: 834, innerHeight: 1210,
    addEventListener: (name, callback, options) => listeners.push({name, callback, capture: !!options.capture, removed: false}),
    removeEventListener: (name, callback, capture) => {
      const found = listeners.find(item => item.name === name && item.callback === callback && item.capture === capture);
      assert.ok(found); found.removed = true;
    },
    webkit: bridge ? {messageHandlers: {dshGuestDialog: {postMessage: message => messages.push(structuredClone(message))}}} : undefined,
  };
  const context = {window, document, performance: {now: () => 1000},
    getComputedStyle: () => ({visibility: 'visible', display: 'block'}),
    queueMicrotask: callback => microtasks.push(callback),
    requestAnimationFrame: callback => frames.push(callback),
    setTimeout: callback => timers.push(callback),
    MutationObserver: class {
      constructor(callback) { this.callback = callback; this.disconnected = false; observer = this; }
      observe() {}
      disconnect() { this.disconnected = true; }
    }};
  runInNewContext(script, context);
  return {messages, listeners, microtasks, frames, timers, dialog, action, child, secret, window,
    observer: () => observer,
    setHit: value => { hit = value; },
    setDialogs: value => { dialogs = value; },
    scan: () => { observer.callback(); while(frames.length) frames.shift()(); },
    flush: () => { while(microtasks.length) microtasks.shift()(); },
    event: (name, event) => {
      for (const listener of listeners.filter(item => item.name === name && !item.removed)) listener.callback(event);
    }};
}

test('inactive without the explicit native bridge', () => {
  const f = fixture({bridge: false});
  assert.equal(f.messages.length, 0);
  assert.equal(f.listeners.length, 0);
  assert.equal(f.observer(), undefined);
});

test('known modal reports only fixed classifications and numeric metadata', () => {
  const f = fixture();
  assert.equal(f.messages.length, 1);
  assert.deepEqual(f.messages[0], {ui_dialog: 'welcome', ui_dialog_present: true,
    ui_modal_instance: 1, ui_action_instance: 2,
    ui_root_inert: false, ui_modal_inert: false, ui_modal_under_root: false,
    ui_action_enabled: true, ui_action_visible: true, ui_hit_action: true,
    ui_view_width: 834, ui_view_height: 1210, ui_phase: 'started', ui_sequence: 1, ui_elapsed_ms: 0});
  assert.equal(JSON.stringify(f.messages).includes(f.secret), false);
});

test('inert ancestry and body portal are observed without changing them', () => {
  const f = fixture({inert: true, underRoot: true});
  assert.equal(f.messages[0].ui_root_inert, true);
  assert.equal(f.messages[0].ui_modal_inert, true);
  assert.equal(f.messages[0].ui_modal_under_root, true);
  const portal = fixture({inert: true});
  assert.equal(portal.messages[0].ui_root_inert, true);
  assert.equal(portal.messages[0].ui_modal_inert, false);
});

test('records real event delivery and a later state without invoking actions', () => {
  const f = fixture();
  const event = {target: f.child, isTrusted: true, defaultPrevented: false, preventDefault() { throw new Error('mutated event'); }};
  f.event('click', event);
  f.action.disabled = true;
  event.defaultPrevented = true;
  f.flush();
  assert.deepEqual(f.messages.slice(1).map(r => r.ui_phase), ['click_capture', 'click_bubble', 'after_event', 'after_event']);
  assert.ok(f.messages.slice(1).every(r => r.ui_target_action && r.ui_trusted));
  assert.ok(f.messages.slice(-2).every(r => r.ui_default_prevented && !r.ui_action_enabled));
});

test('does not confuse an overlaid target with the known safe action', () => {
  const f = fixture({title: 'Add an API key to get started', button: 'Configure later'});
  f.setHit({});
  f.event('pointerdown', {target: {}, isTrusted: false});
  f.flush();
  assert.equal(f.messages[1].ui_dialog, 'api');
  assert.equal(f.messages[1].ui_hit_action, false);
  assert.equal(f.messages[1].ui_target_action, false);
  assert.equal(f.messages[1].ui_trusted, false);
});

test('modal removal is recorded independently of the AX waiter', () => {
  const f = fixture();
  f.setDialogs([]);
  f.dialog.isConnected = false;
  f.scan();
  assert.equal(f.messages.at(-1).ui_phase, 'state');
  assert.equal(f.messages.at(-1).ui_dialog_present, false);
});

test('same-title remount in a single animation frame has a new identity', () => {
  const f = fixture();
  const replacement = {...f.dialog};
  f.setDialogs([replacement]);
  f.scan();
  assert.equal(f.messages.length, 2);
  assert.equal(f.messages[1].ui_phase, 'state');
  assert.notEqual(f.messages[1].ui_modal_instance, f.messages[0].ui_modal_instance);
});

test('unknown dialog text is never exported, credential actions are never selected', () => {
  const unknown = fixture({title: 'fixture-secret-that-must-never-be-read'});
  assert.equal(unknown.messages.length, 0);
  const save = fixture({title: 'Add an API key to get started', button: 'Save credential-secret'});
  assert.equal(save.messages[0].ui_action_enabled, false);
  assert.equal(JSON.stringify(save.messages).includes('credential-secret'), false);
});

test('event export has a strict per-document cap and observer lifetime is bounded', () => {
  const f = fixture();
  for(let i = 0; i < 250; i++) {
    f.event('pointerup', {target: f.child, isTrusted: true});
    f.flush();
  }
  f.scan();
  assert.equal(f.messages.length, 192);
  assert.ok(f.messages.every((message, index) => message.ui_sequence === index + 1));
  assert.equal(f.observer().disconnected, true);
  assert.ok(f.listeners.every(item => item.removed));
  f.event('click', {target: f.child, isTrusted: true});
  assert.equal(f.messages.length, 192);
});

test('duplicate installation and noisy unrelated mutations remain bounded', () => {
  const f = fixture();
  for(let i = 0; i < 513; i++) f.scan();
  assert.equal(f.observer().disconnected, true);
  assert.deepEqual(f.messages.map(r => r.ui_phase), ['started', 'finished']);
  f.timers[0]();
  assert.equal(f.messages.length, 2);
});
