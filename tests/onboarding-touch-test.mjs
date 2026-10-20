import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {dirname, resolve} from 'node:path';
import {runInNewContext, Script} from 'node:vm';
import {test} from 'node:test';
import {getEventListeners} from 'node:events';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(resolve(root, 'app/OnboardingInteraction.bundle/manifest.json')));
const patch = manifest.patches[0];
const replacement = patch.replacements[0].replace;
const begin = '// BEGIN DSH_OPTIONAL_CANCEL_TOUCH_BINDER';
const end = '// END DSH_OPTIONAL_CANCEL_TOUCH_BINDER';
const binder = replacement.slice(replacement.indexOf(begin) + begin.length, replacement.indexOf(end));
const bind = runInNewContext(binder + '\ndshBindOptionalCancelTouch;');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

class Button extends EventTarget {
  isConnected = true;
  disabled = false;
  rect = {left: 20, top: 40, right: 120, bottom: 80};
  child = {};
  registrations = [];
  hit = this;
  modal = {};
  inert = false;
  hidden = false;
  ownerDocument = Object.assign(new EventTarget(), {
    elementFromPoint: () => this.hit,
    querySelectorAll: selector => {
      assert.equal(selector, '[role="dialog"][aria-modal="true"], [role="menu"]');
      return this.layers ?? [this.modal];
    },
  });
  closest(selector) {
    if (selector === '[inert], [hidden]') return this.inert || this.hidden ? {} : null;
    assert.equal(selector, '[role="dialog"][aria-modal="true"], [role="menu"]');
    return this.modal;
  }
  getBoundingClientRect() { return this.rect; }
  contains(target) { return target === this.child; }
  addEventListener(name, listener, options) {
    this.registrations.push({name, listener, options});
    super.addEventListener(name, listener, options);
  }
  removeEventListener(name, listener) {
    this.registrations = this.registrations.filter(r => r.name !== name || r.listener !== listener);
    super.removeEventListener(name, listener);
  }
}
const point = (identifier = 7, clientX = 60, clientY = 60) => ({identifier, clientX, clientY});
// Native Node EventTarget dispatch exercises the actual listeners and cancellation.
// Trusted flags are fixture-only; genuine WebKit trusted touch is tested separately on iOS.
function fire(button, type, {touch = point(), touches, changedTouches, at = 100, trusted = true,
                            cancelable = true, refusesCancellation = false, preCancelled = false} = {}) {
  const event = new Event(type, {cancelable});
  Object.defineProperties(event, {
    isTrusted: {value: trusted}, timeStamp: {value: at},
    touches: {value: touches ?? (type === 'touchend' ? [] : [touch])},
    changedTouches: {value: changedTouches ?? [touch]},
  });
  if (refusesCancellation) event.preventDefault = () => {};
  if (preCancelled) event.preventDefault();
  button.dispatchEvent(event);
  return event;
}
function fixture() {
  const button = new Button(); let calls = 0;
  const cleanup = bind(button, () => { calls++; });
  return {button, cleanup, calls: () => calls};
}
function tap(f, endOptions = {}) {
  fire(f.button, 'touchstart');
  return fire(f.button, 'touchend', {at: 150, ...endOptions});
}

test('pinned package patch has exact scope and no extra guest resources', () => {
  assert.equal(manifest.schema, 1);
  assert.equal(manifest.rootfs_sha256, 'd3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0');
  assert.deepEqual(manifest.files, []); assert.equal(manifest.patches.length, 1);
  assert.equal(patch.target, '/usr/local/lib/node_modules/@deepseek-ai/dsh-client-ui-settings-models/lib/client.js');
  assert.equal(patch.original_sha256, '7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa');
  assert.equal(patch.replacements.length, 5);
  assert.equal(replacement.split(begin).length, 2); assert.equal(replacement.split(end).length, 2);
  assert.match(replacement, /props\.touchCancel === true && props\.cancelLabelKey === "onboardingLater"/);
  assert.match(replacement, /onClick: touchCancel \? cancelOnce : props\.onCancel/);
  assert.doesNotMatch(binder, /window\.addEventListener|\.click\(|dispatchEvent|setTimeout|requestAnimationFrame|\.value\b|fetch\(/);
  assert.match(binder, /document\.addEventListener\("touchstart", guardAdditionalTouch, \{ capture: true, passive: true \}\)/);
});

test('real rootfs member and all exact replacements match both official hashes', () => {
  const tar = resolve(root, 'build/root.tar.gz');
  if (!existsSync(tar)) {
    assert.notEqual(process.env.DSH_ONBOARDING_ROOTFS_REQUIRED, '1', 'required fixed rootfs is absent');
    console.log('Rootfs not present: only package/interaction tests run; CI acceptance requires DSH_ONBOARDING_ROOTFS_REQUIRED=1.');
    return;
  }
  assert.equal(sha(readFileSync(tar)), manifest.rootfs_sha256);
  const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  const output = spawnSync(python, ['-c', 'import sys,tarfile; t=tarfile.open(sys.argv[1],"r:gz"); sys.stdout.buffer.write(t.extractfile(sys.argv[2]).read())',
    tar, '.' + patch.target], {maxBuffer: 4 * 1024 * 1024});
  assert.equal(output.status, 0, output.stderr?.toString());
  assert.equal(sha(output.stdout), patch.original_sha256);
  let code = output.stdout.toString();
  for (const r of patch.replacements) {
    assert.equal(r.count, 1); assert.equal(code.split(r.find).length - 1, r.count);
    code = code.replace(r.find, r.replace);
  }
  assert.equal(sha(Buffer.from(code)), patch.patched_sha256);
  new Script(code);
});

test('one trusted contained touch cancels compatibility click before exactly one action', () => {
  const f = fixture();
  assert.equal(f.button.registrations.length, 6);
  assert.ok(f.button.registrations.every(r => r.options.passive === false));
  const endEvent = tap(f);
  assert.equal(endEvent.defaultPrevented, true); assert.equal(f.calls(), 1);
  assert.equal(getEventListeners(f.button.ownerDocument, 'touchstart').length, 0);
  tap(f); assert.equal(f.calls(), 1);
});

test('descendant hit and the exact distance/time boundaries remain valid', () => {
  const f = fixture(); f.button.hit = f.button.child;
  fire(f.button, 'touchstart');
  const endEvent = fire(f.button, 'touchend', {at: 850, touch: point(7, 68, 60)});
  assert.equal(endEvent.defaultPrevented, true); assert.equal(f.calls(), 1);
});

test('untrusted, uncancelable, refused cancellation and already-cancelled gestures never activate', () => {
  for (const options of [{trusted: false}, {cancelable: false}, {refusesCancellation: true}, {preCancelled: true}]) {
    const f = fixture(); tap(f, options); assert.equal(f.calls(), 0);
  }
  const f = fixture(); fire(f.button, 'touchstart', {trusted: false});
  fire(f.button, 'touchend', {at: 150}); assert.equal(f.calls(), 0);
});

test('cancel, context menu and pointercancel irrevocably invalidate a pending touch', () => {
  for (const name of ['touchcancel', 'pointercancel', 'contextmenu']) {
    const f = fixture(); fire(f.button, 'touchstart'); fire(f.button, name, {at: 120});
    fire(f.button, 'touchend', {at: 150}); assert.equal(f.calls(), 0);
  }
});

test('drag out and back, excessive motion, elapsed time and identifier changes fail closed', () => {
  for (const moved of [point(7, 130, 60), point(7, 69, 60), point(8)]) {
    const f = fixture(); fire(f.button, 'touchstart');
    fire(f.button, 'touchmove', {at: 120, touch: moved});
    fire(f.button, 'touchmove', {at: 130});
    fire(f.button, 'touchend', {at: 150}); assert.equal(f.calls(), 0);
  }
  for (const options of [{at: 851}, {at: 99}, {touch: point(8)}, {touch: point(7, NaN, 60)}]) {
    const f = fixture(); tap(f, options); assert.equal(f.calls(), 0);
  }
});

test('any observed multi-touch or changed-touch ambiguity invalidates the gesture', () => {
  const f = fixture(); fire(f.button, 'touchstart');
  assert.equal(getEventListeners(f.button.ownerDocument, 'touchstart').length, 1);
  fire(f.button, 'touchmove', {at: 120, touches: [point(), point(8)]});
  fire(f.button, 'touchend', {at: 150}); assert.equal(f.calls(), 0);
  for (const options of [{touches: [point(8)]}, {changedTouches: [point(), point(8)]}]) {
    const current = fixture(); tap(current, options); assert.equal(current.calls(), 0);
  }
});

test('disconnected, disabled, covered or moved buttons never cancel or activate', () => {
  for (const change of [b => { b.isConnected = false; }, b => { b.disabled = true; },
                         b => { b.hit = {}; }, b => { b.rect = {left: 200, top: 40, right: 300, bottom: 80}; },
                         b => { b.inert = true; }, b => { b.hidden = true; }, b => { b.layers = [b.modal, {}]; }]) {
    const f = fixture(); fire(f.button, 'touchstart'); change(f.button);
    const e = fire(f.button, 'touchend', {at: 150});
    assert.equal(e.defaultPrevented, false); assert.equal(f.calls(), 0);
  }
});

test('a second finger starting elsewhere cancels permanently even after that finger ends', () => {
  const f = fixture(); fire(f.button, 'touchstart');
  const outside = new Event('touchstart');
  Object.defineProperties(outside, {isTrusted: {value: true}, touches: {value: [point(), point(8)]}});
  f.button.ownerDocument.dispatchEvent(outside);
  assert.equal(getEventListeners(f.button.ownerDocument, 'touchstart').length, 0);
  const e = fire(f.button, 'touchend', {at: 150, touches: []});
  assert.equal(e.defaultPrevented, false); assert.equal(f.calls(), 0);
});

test('cleanup is idempotent, removes every element listener and disables pending activation', () => {
  const f = fixture(); fire(f.button, 'touchstart'); f.cleanup(); f.cleanup();
  assert.equal(f.button.registrations.length, 0);
  assert.equal(getEventListeners(f.button.ownerDocument, 'touchstart').length, 0);
  fire(f.button, 'touchend', {at: 150}); assert.equal(f.calls(), 0);
});

function footerHost(initial) {
  const slots = []; let index = 0; let pending = []; let current;
  const button = new Button(); const effects = [];
  const react = {
    useRef(value) { const i = index++; return slots[i] ??= {current: value}; },
    useCallback(fn) { const i = index++; return slots[i] ??= fn; },
    useLayoutEffect(fn, deps) {
      const i = index++; const old = slots[i];
      if (!old || deps.some((d, n) => d !== old.deps[n])) {
        pending.push(() => { old?.cleanup?.(); slots[i] = {deps, cleanup: fn()}; effects[i] = slots[i]; });
      }
    },
  };
  const jsx = (type, props) => ({type, props});
  const renderFooter = runInNewContext(replacement + '\nEditorFooter;', {
    react, react_jsx_runtime: {jsx, jsxs: jsx}, ModelsSection_module_css_default: {},
  });
  button.addEventListener('click', e => { if (!button.disabled) current.props.onClick(e); });
  function render(props) {
    index = 0; pending = []; const tree = renderFooter({t: x => x, ...props});
    current = tree.props.children[0]; button.disabled = !!current.props.disabled;
    if (current.props.ref) current.props.ref.current = button;
    pending.forEach(fn => fn());
  }
  render(initial);
  return {button, render, cleanup() { effects.forEach(e => e?.cleanup?.()); }};
}

test('React owner uses latest callback, shares one touch/click latch and cleans up', () => {
  let old = 0, latest = 0;
  const h = footerHost({touchCancel: true, cancelLabelKey: 'onboardingLater', onCancel: () => old++});
  fire(h.button, 'touchstart');
  h.render({touchCancel: true, cancelLabelKey: 'onboardingLater', onCancel: () => latest++});
  fire(h.button, 'touchend', {at: 150});
  h.button.dispatchEvent(new Event('click')); // keyboard/AX/compat path reaches the same latch.
  assert.equal(old, 0); assert.equal(latest, 1);
  h.cleanup(); assert.equal(h.button.registrations.length, 1); // only the harness click delegate.
});

test('keyboard/AX/mouse onClick still activates opt-in once; unrelated footers stay unchanged', () => {
  let count = 0;
  const h = footerHost({touchCancel: true, cancelLabelKey: 'onboardingLater', onCancel: () => count++});
  h.button.dispatchEvent(new Event('click')); h.button.dispatchEvent(new Event('click'));
  assert.equal(count, 1); h.cleanup();
  for (const props of [{touchCancel: false, cancelLabelKey: 'onboardingLater'}, {touchCancel: true, cancelLabelKey: 'cancel'}]) {
    let calls = 0; const normal = footerHost({...props, onCancel: () => calls++});
    tap({button: normal.button}); assert.equal(calls, 0);
    normal.button.dispatchEvent(new Event('click')); normal.button.dispatchEvent(new Event('click'));
    assert.equal(calls, 2); normal.cleanup();
  }
});
