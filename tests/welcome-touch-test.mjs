// Tests execute the actual shipped manifest/helper/store. Node controls the
// dependencies and isTrusted flags; real WK input and Host persistence are
// separate mandatory validation. No candidate helper implementation is copied.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {Script,runInNewContext} from 'node:vm';
import {getEventListeners} from 'node:events';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const sha=x=>createHash('sha256').update(x).digest('hex');
const actualManifest=JSON.parse(readFileSync(resolve(root,'app/OnboardingInteraction.bundle/manifest.json')));
assert.equal(actualManifest.patches.length,1);
const actualPatch=actualManifest.patches[0];
assert.equal(actualPatch.replacements.length,5);
assert.equal(actualPatch.original_source.source,'onboarding-client-original.js');
const original=readFileSync(resolve(root,'app/OnboardingInteraction.bundle',actualPatch.original_source.source));
assert.equal(original.length,186641);
assert.equal(sha(original),'7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa');
function apply(text,replacements){
  for(const r of replacements){assert.equal(r.count,1);assert.equal(text.split(r.find).length-1,1);text=text.replace(r.find,r.replace);}
  return text;
}
const patched=apply(original.toString(),actualPatch.replacements);
assert.equal(sha(Buffer.from(patched)),actualPatch.patched_sha256);
assert.equal(actualPatch.patched_sha256,'d4f3634c7483237ad9627b0a4b06f6b5b04d538a5d96b304841afe09078bf9d5');
new Script(patched);
const segment=(source,start,end)=>{
  const i=source.indexOf(start);assert.ok(i>=0);const j=source.indexOf(end,i+start.length);
  assert.ok(j>i);return source.slice(i,j);
};
const helper=source=>segment(source,'// BEGIN DSH_WELCOME_TOUCH_BINDER','// END DSH_WELCOME_TOUCH_BINDER');
const component=(source,name)=>segment(source,`\t\tfunction ${name}(props) {`,'\n\t\t//#endregion');
const shippedHelper=helper(patched);
const {createWelcomeAttemptGate,bindWelcomeTouch}=runInNewContext(shippedHelper+
  '\n({createWelcomeAttemptGate:dshCreateWelcomeAttemptGate,bindWelcomeTouch:dshBindWelcomeTouch});');
const originalStore=segment(original.toString(),'var WelcomeNoticeStore = class {','\n\t\t//#endregion');
const candidateStore=segment(patched,'var WelcomeNoticeStore = class {','\n\t\t//#endregion');
const touchOnly=structuredClone(actualManifest);
touchOnly.patches[0].replacements.pop();
const control=apply(original.toString(),touchOnly.patches[0].replacements);
touchOnly.patches[0].patched_sha256=sha(Buffer.from(control));
assert.equal(touchOnly.patches[0].patched_sha256,'c7b1fbd4b95a222f57ef8c565d6cde730281e746f63696871f0a014ec63b4d6b');
const manifests={'touch-only':touchOnly,'touch-plus-store':actualManifest};
const clients={'touch-only':control,'touch-plus-store':patched};

// Transaction and actual Store behavior (25).
{
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
};

function gateFixture(operation) {
  let calls = 0, finished = 0, rejected = 0;
  const state = {status: 'ready', acknowledged: false};
  const gate = createWelcomeAttemptGate({
    getState: () => state,
    acknowledge: () => {calls++; return operation?.(calls) ?? false;},
    finish: () => {finished++;},
    onRejected: () => {rejected++;},
  });
  return {gate, state, calls: () => calls, finished: () => finished, rejected: () => rejected};
}

function storeFixture(code = originalStore) {
  let snapshot = {mode: 'host', status: 'ready', value: {}};
  let calls = 0;
  let behavior = async () => false;
  const listeners = new Set();
  const history = [];
  const scope = {
    getSnapshot: () => snapshot,
    subscribe(listener) {listeners.add(listener); return () => listeners.delete(listener);},
    async set(field, value) {
      calls++;
      assert.equal(field, 'welcomeNoticeVersion');
      assert.equal(value, '2026-09-28.1');
      return await behavior();
    },
  };
  const Store = runInNewContext(code + '\nWelcomeNoticeStore;', {
    WELCOME_NOTICE_ACK_FIELD: 'welcomeNoticeVersion',
    WELCOME_NOTICE_VERSION: '2026-09-28.1',
    _deepseek_ai_dsh_client_store: {createSnapshotStore(initial) {
      let current = {...initial};
      return {getSnapshot: () => current, update(change) {
        const next = {...current}; change(next); current = next; history.push({...next});
      }};
    }},
  });
  const store = new Store(scope);
  store.load();
  return {
    store, scope, calls: () => calls, history: () => history.map(state => ({...state})),
    behavior(fn) {behavior = fn;},
    publish(next) {snapshot = {...snapshot, ...next}; for (const fn of listeners) fn();},
    snapshot: () => store.store.getSnapshot(),
  };
}

test('touch fallback and compatibility click share exactly one pending write', async () => {
  const d = deferred(), f = gateFixture(() => d.promise), token = f.gate.newGesture();
  const touch = f.gate.activate(token);
  assert.equal(f.calls(), 1); assert.equal(f.gate.snapshot().inFlight, true);
  assert.equal(await f.gate.activate(token), false);
  assert.equal(f.finished(), 0);
  d.resolve(true); assert.equal(await touch, true);
  assert.equal(f.calls(), 1); assert.equal(f.finished(), 1);
});

test('false result keeps notice; late compatibility click cannot retry that gesture', async () => {
  const f = gateFixture(), token = f.gate.newGesture();
  assert.equal(await f.gate.activate(token), false);
  assert.equal(await f.gate.activate(token), false);
  assert.equal(f.calls(), 1); assert.equal(f.finished(), 0);
  assert.equal(f.gate.snapshot().inFlight, false);
});

test('fresh explicit gesture can retry false result, with one durable completion', async () => {
  const f = gateFixture(n => n === 2);
  const first = f.gate.newGesture(); await f.gate.activate(first);
  const second = f.gate.newGesture();
  assert.equal(await f.gate.activate(second), true);
  await f.gate.activate(first); await f.gate.activate(second);
  await f.gate.activate(f.gate.newGesture());
  assert.equal(f.calls(), 2); assert.equal(f.finished(), 1);
});

test('rejected promise is handled; old token is consumed; new gesture retries', async () => {
  const f = gateFixture(n => n === 1 ? Promise.reject(new Error('sensitive fixture path')) : true);
  const first = f.gate.newGesture();
  assert.equal(await f.gate.activate(first), false);
  assert.equal(f.rejected(), 1); assert.equal(f.gate.snapshot().inFlight, false);
  await f.gate.activate(first); assert.equal(f.calls(), 1);
  assert.equal(await f.gate.activate(f.gate.newGesture()), true);
  assert.equal(f.calls(), 2); assert.equal(f.finished(), 1);
});

test('synchronous acknowledge throw is also handled without permanent latch', async () => {
  const f = gateFixture(n => {if (n === 1) throw new Error('fixture'); return true;});
  assert.equal(await f.gate.activate(f.gate.newGesture()), false);
  assert.equal(f.rejected(), 1);
  assert.equal(await f.gate.activate(f.gate.newGesture()), true);
});

test('busy-period second gesture is consumed and never queued as automatic retry', async () => {
  const d = deferred(), f = gateFixture(() => d.promise);
  const first = f.gate.newGesture(); const pending = f.gate.activate(first);
  const second = f.gate.newGesture(); await f.gate.activate(second);
  d.resolve(false); await pending;
  await f.gate.activate(second); await f.gate.activate(first);
  assert.equal(f.calls(), 1); assert.equal(f.finished(), 0);
});

test('old compatibility click cannot steal a new gesture while its request is pending', async () => {
  const d = deferred(), f = gateFixture(n => n === 1 ? false : d.promise);
  const first = f.gate.newGesture(); await f.gate.activate(first);
  const second = f.gate.newGesture(); const pending = f.gate.activate(second);
  await f.gate.activate(first); assert.equal(f.calls(), 2);
  d.resolve(true); await pending; assert.equal(f.finished(), 1);
});

test('disposal prevents stale completion without pretending to cancel Host mutation', async () => {
  const d = deferred(), f = gateFixture(() => d.promise);
  const pending = f.gate.activate(f.gate.newGesture());
  f.gate.dispose(); d.resolve(true);
  assert.equal(await pending, false); assert.equal(f.calls(), 1);
  assert.equal(f.finished(), 0); assert.equal(f.gate.snapshot().inFlight, false);
  await f.gate.activate(f.gate.newGesture()); assert.equal(f.calls(), 1);
});

test('only exact true can complete, never a truthy response object or string', async () => {
  for (const value of [false, undefined, 0, 1, 'true', {ok: true}]) {
    const f = gateFixture(() => value);
    assert.equal(await f.gate.activate(f.gate.newGesture()), false);
    assert.equal(f.finished(), 0);
  }
});

test('loading, saving, idle and acknowledged snapshots do not submit a new write', async () => {
  for (const status of ['loading', 'saving', 'idle']) {
    const f = gateFixture(() => true); f.state.status = status;
    const token = f.gate.newGesture(); await f.gate.activate(token);
    f.state.status = 'ready'; await f.gate.activate(token);
    assert.equal(f.calls(), 0);
  }
  const f = gateFixture(() => true); f.state.acknowledged = true;
  await f.gate.activate(f.gate.newGesture()); assert.equal(f.calls(), 0);
});

test('arbitrary objects and tokens from another gate cannot authorize an attempt', async () => {
  const first = gateFixture(() => true), second = gateFixture(() => true);
  for (const token of [{}, null, undefined, second.gate.newGesture()]) {
    assert.equal(await first.gate.activate(token), false);
  }
  assert.equal(first.calls(), 0);
});

test('actual original store returns false/error on refused write and remains retryable', async () => {
  const f = storeFixture();
  assert.equal(await f.store.acknowledge(), false);
  assert.equal(f.snapshot().status, 'error'); assert.equal(f.snapshot().acknowledged, false);
  f.behavior(async () => {f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}}); return true;});
  assert.equal(await f.store.acknowledge(), true);
  assert.equal(f.calls(), 2); assert.equal(f.snapshot().status, 'ready');
});

test('actual original reject branch proves finally resets flag but can leave snapshot saving', async () => {
  const f = storeFixture();
  f.behavior(async () => {f.publish({value: {}}); throw new Error('fixture');});
  await assert.rejects(f.store.acknowledge(), /fixture/);
  assert.equal(f.store.saving, false);
  assert.equal(f.snapshot().status, 'saving');
  assert.equal(f.snapshot().error, null); assert.equal(f.snapshot().acknowledged, false);
});

test('candidate set-rejection settlement returns false/error then allows explicit retry', async () => {
  const f = storeFixture(candidateStore);
  f.behavior(async () => {f.publish({value: {}}); throw new Error('sensitive fixture path');});
  assert.equal(await f.store.acknowledge(), false);
  assert.equal(f.store.saving, false); assert.equal(f.snapshot().status, 'error');
  assert.equal(f.snapshot().error, 'the acknowledgement could not be confirmed');
  f.behavior(async () => {f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}}); return true;});
  assert.equal(await f.store.acknowledge(), true);
  assert.equal(f.snapshot().acknowledged, true); assert.equal(f.calls(), 2);
});

test('candidate never acknowledges an old or missing version after mutation failure', async () => {
  for (const version of [undefined, '', '2026-09-28', '2026-09-28.0']) {
    const f = storeFixture(candidateStore);
    f.behavior(async () => {
      f.publish({value: {welcomeNoticeVersion: version}}); throw new Error('fixture');
    });
    assert.equal(await f.store.acknowledge(), false);
    assert.equal(f.snapshot().acknowledged, false); assert.equal(f.snapshot().status, 'error');
  }
});

test('rejected write fails closed even when held scope already shows the exact version', async () => {
  const f = storeFixture(candidateStore);
  f.behavior(async () => {
    f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}});
    throw new Error('response lost after independent mirror publication');
  });
  assert.equal(await f.store.acknowledge(), false);
  assert.equal(f.snapshot().acknowledged, false); assert.equal(f.calls(), 1);
  assert.equal(f.snapshot().status, 'error'); assert.equal(f.store.saving, false);
  assert.equal(f.snapshot().error, 'the acknowledgement could not be confirmed');
  assert.ok(f.history().every(state => state.acknowledged === false));
});

test('held exact-version then rejected pending gesture never finishes; next explicit gesture retries', async () => {
  const f = storeFixture(candidateStore), d = deferred(); let complete = 0;
  f.behavior(() => d.promise);
  const gate = createWelcomeAttemptGate({getState: f.snapshot,
    acknowledge: () => f.store.acknowledge(), finish: () => {complete++;}});
  const first = gate.newGesture(), pending = gate.activate(first);
  assert.equal(f.store.saving, true); assert.equal(f.calls(), 1);
  f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}});
  assert.equal(f.snapshot().status, 'saving'); assert.equal(complete, 0);
  d.reject(new Error('unconfirmed Host write may later roll back'));
  assert.equal(await pending, false);
  assert.equal(f.store.saving, false); assert.equal(f.snapshot().status, 'error');
  assert.equal(f.snapshot().acknowledged, false); assert.equal(complete, 0);
  assert.ok(f.history().every(state => state.acknowledged === false));
  f.publish({value: {}}); // Controlled rollback after the rejected operation.
  assert.equal(await gate.activate(first), false);
  assert.equal(f.calls(), 1); assert.equal(complete, 0);
  f.behavior(async () => {f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}}); return true;});
  const second = gate.newGesture();
  assert.equal(await gate.activate(second), true); await gate.activate(second);
  assert.equal(f.calls(), 2); assert.equal(complete, 1); assert.equal(f.snapshot().acknowledged, true);
});

test('a later independent scope publication retains the original subscription semantics after rejection', async () => {
  const f = storeFixture(candidateStore);
  f.behavior(async () => {throw new Error('fixture');});
  assert.equal(await f.store.acknowledge(), false);
  assert.equal(f.snapshot().status, 'error'); assert.equal(f.snapshot().acknowledged, false);
  f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}});
  assert.equal(f.snapshot().status, 'ready'); assert.equal(f.snapshot().acknowledged, true);
  assert.equal(f.calls(), 1); // No automatic write or retry was introduced.
});

test('gate plus candidate actual store: rejected tap, late click, new tap persist once each', async () => {
  const f = storeFixture(candidateStore); let complete = 0;
  f.behavior(async () => {throw new Error('fixture');});
  const gate = createWelcomeAttemptGate({getState: f.snapshot,
    acknowledge: () => f.store.acknowledge(), finish: () => {complete++;}});
  const first = gate.newGesture(); await gate.activate(first);
  assert.equal(f.snapshot().status, 'error');
  await gate.activate(first); assert.equal(f.calls(), 1); assert.equal(complete, 0);
  f.behavior(async () => {f.publish({value: {welcomeNoticeVersion: '2026-09-28.1'}}); return true;});
  const second = gate.newGesture(); await gate.activate(second); await gate.activate(second);
  assert.equal(f.calls(), 2); assert.equal(complete, 1);
});

test('memory mode remains the existing process-local path and never writes Host', async () => {
  const f = storeFixture(candidateStore); f.publish({mode: 'memory'});
  assert.equal(await f.store.acknowledge(), true);
  assert.equal(f.calls(), 0); assert.equal(f.snapshot().acknowledged, true);
});

test('pending operation has no artificial timeout, retry, or optimistic completion', async () => {
  const d = deferred(), f = gateFixture(() => d.promise), token = f.gate.newGesture();
  const pending = f.gate.activate(token);
  for (let i = 0; i < 50; i++) await Promise.resolve();
  assert.equal(f.calls(), 1); assert.equal(f.finished(), 0);
  assert.equal(f.gate.snapshot().inFlight, true);
  d.resolve(false); assert.equal(await pending, false);
});

test('snapshot getter throw is safely reported and never authorizes persistence', async () => {
  let calls=0,reports=0;
  const gate=createWelcomeAttemptGate({getState:()=>{throw Error('fixture');},
    acknowledge:()=>{calls++;return true;},finish:()=>assert.fail('must not finish'),
    onRejected:()=>{reports++;}});
  const token=gate.newGesture();assert.equal(await gate.activate(token),false);
  await gate.activate(token);assert.equal(calls,0);assert.equal(reports,1);
  assert.equal(gate.snapshot().inFlight,false);
});

test('throwing error reporter cannot escape the ignored UI Promise', async () => {
  const gate=createWelcomeAttemptGate({getState:()=>({status:'ready',acknowledged:false}),
    acknowledge:()=>{throw Error('fixture');},finish:()=>assert.fail('must not finish'),
    onRejected:()=>{throw Error('reporter fixture');}});
  assert.equal(await gate.activate(gate.newGesture()),false);
  assert.equal(gate.snapshot().inFlight,false);
});

test('finish exception never repeats the already confirmed durable mutation', async () => {
  let writes=0,finishes=0,reports=0;
  const gate=createWelcomeAttemptGate({getState:()=>({status:'ready',acknowledged:false}),
    acknowledge:()=>{writes++;return true;},finish:()=>{finishes++;throw Error('fixture');},
    onRejected:()=>{reports++;}});
  assert.equal(await gate.activate(gate.newGesture()),false);
  await gate.activate(gate.newGesture());
  assert.equal(writes,1);assert.equal(finishes,1);assert.equal(reports,1);
  assert.equal(gate.snapshot().completed,true); // Durable result, not proof UI closed.
});

test('discarded gesture cannot write but does not permanently latch the whole component', async () => {
  const f=gateFixture(async()=>true),token=f.gate.newGesture();f.gate.discard(token);
  assert.equal(await f.gate.activate(token),false);assert.equal(f.calls(),0);
  assert.equal(await f.gate.activate(f.gate.newGesture()),true);assert.equal(f.calls(),1);
});

}
// Actual native-listener behavior with controlled provenance (20).
{
// Native EventTarget dispatches the actual candidate listeners. Coordinates,
// isTrusted and platform provenance are controlled fixtures, NOT WebKit proof.
class Button extends EventTarget {
  isConnected = true; disabled = false; inert = false; hidden = false;
  rect = {left: 20, top: 40, right: 120, bottom: 80};
  child = {}; modal = {}; registrations = [];
  ownerDocument = Object.assign(new EventTarget(), {
    elementFromPoint: () => this.hit ?? this,
    querySelectorAll: () => this.layers ?? [this.modal],
  });
  getBoundingClientRect() {return this.rect;}
  contains(target) {return target === this.child;}
  closest(selector) {return selector === '[inert], [hidden]' ?
    (this.inert || this.hidden ? {} : null) : this.modal;}
  addEventListener(type, listener, options) {
    this.registrations.push({type, listener, options}); super.addEventListener(type, listener, options);
  }
  removeEventListener(type, listener) {
    this.registrations = this.registrations.filter(x => x.type !== type || x.listener !== listener);
    super.removeEventListener(type, listener);
  }
}
const point = (identifier=7, clientX=60, clientY=60) => ({identifier, clientX, clientY});
function event(type, values={}) {
  const e = new Event(type, {cancelable: values.cancelable ?? true});
  const props = {isTrusted: true, timeStamp: 100, button: 0, ...values};
  delete props.cancelable;
  for (const [key,value] of Object.entries(props)) Object.defineProperty(e,key,{value,configurable:true});
  if (values.preCancelled) e.preventDefault();
  if (values.refusesCancellation) e.preventDefault = () => {};
  return e;
}
function fire(button,type,values={}) {
  const e = event(type,{touches:type==='touchend'?[]:[point()],changedTouches:[point()],...values});
  button.dispatchEvent(e); return e;
}
function fixture(operation=async()=>false) {
  const button = new Button(); let calls=0,complete=0;
  const state={status:'ready',acknowledged:false};
  const binding=bindWelcomeTouch(button,{
    getState:()=>state, acknowledge:()=>{calls++;return operation(calls);},finish:()=>{complete++;},
  });
  return {button,binding,state,calls:()=>calls,complete:()=>complete};
}
async function settle() {for(let i=0;i<5;i++)await Promise.resolve();}
async function tap(f, end={}) {
  fire(f.button,'touchstart'); const e=fire(f.button,'touchend',{timeStamp:150,...end});
  await settle(); return e;
}
const click = (f,values={}) => f.binding.onClick(event('click',values));

test('one valid touch falls back once and cancels default before acknowledgement',async()=>{
  const f=fixture(); const e=await tap(f);
  assert.equal(e.defaultPrevented,true); assert.equal(f.calls(),1); assert.equal(f.complete(),0);
  assert.equal(getEventListeners(f.button.ownerDocument,'touchstart').length,0);
});

test('known touch click after immediate false or reject never writes twice; next tap retries',async()=>{
  for(const operation of [async()=>false,async()=>{throw Error('fixture');}]){
    const f=fixture(operation); await tap(f);
    await click(f,{pointerType:'touch',pointerId:23});
    await click(f,{sourceCapabilities:{firesTouchEvents:true}});
    assert.equal(f.calls(),1); await tap(f); assert.equal(f.calls(),2);
  }
});

test('anonymous click-only activation after failed touch stays available without guessing detail zero',async()=>{
  const f=fixture(); await tap(f);
  await click(f,{detail:0}); await click(f,{detail:1});
  assert.equal(f.calls(),3); assert.equal(f.binding.inspect().ambiguousClicks,2);
  // These are separate controlled click-only activations. This does NOT prove
  // a real browser will suppress anonymous compatibility clicks on touchend.
});

test('specified non-pointing AX click pair remains available after failed touch',async()=>{
  const f=fixture(n=>n===2); await tap(f);
  assert.equal(await click(f,{pointerId:-1,pointerType:'',detail:0}),true);
  assert.equal(f.calls(),2); assert.equal(f.complete(),1);
});

test('trusted click-only legacy AX path is preserved before any touch',async()=>{
  const f=fixture(async()=>true);
  assert.equal(await click(f,{detail:0}),true);
  assert.equal(f.calls(),1); assert.equal(f.complete(),1);
});

test('keyboard Enter held repeats consume one token and fresh press retries after failure',async()=>{
  const f=fixture(); await tap(f);
  fire(f.button,'keydown',{key:'Enter',repeat:false});
  await click(f,{pointerId:-1,pointerType:''});
  fire(f.button,'keydown',{key:'Enter',repeat:true});
  await click(f,{pointerId:-1,pointerType:''}); assert.equal(f.calls(),2);
  fire(f.button,'keyup',{key:'Enter'});
  fire(f.button,'keydown',{key:'Enter',repeat:false});
  await click(f,{pointerId:-1,pointerType:''}); assert.equal(f.calls(),3);
});

test('Space native keyup then click uses the same new explicit key token',async()=>{
  const f=fixture(); await tap(f);
  fire(f.button,'keydown',{key:' ',repeat:false}); fire(f.button,'keyup',{key:' '});
  await click(f,{pointerId:-1,pointerType:''}); assert.equal(f.calls(),2);
});

test('mouse/pen native click after failed touch keeps the original activation path',async()=>{
  for(const pointerType of ['mouse','pen']){
    const f=fixture();await tap(f);
    const values={pointerType,pointerId:1,clientX:60,clientY:60};
    fire(f.button,'pointerdown',values);fire(f.button,'pointerup',values);
    await click(f,values);assert.equal(f.calls(),2);
  }
});

test('touch or click from untrusted script cannot write',async()=>{
  const f=fixture();fire(f.button,'touchstart',{isTrusted:false});fire(f.button,'touchend');
  await click(f,{isTrusted:false,pointerId:-1,pointerType:''});assert.equal(f.calls(),0);
});

test('uncancelable, already canceled or refused-cancellation touchend never writes',async()=>{
  for(const options of [{cancelable:false},{preCancelled:true},{refusesCancellation:true}]){
    const f=fixture();await tap(f,options);await click(f,{pointerType:'touch'});assert.equal(f.calls(),0);
  }
});

test('drag out and back, over 8px, identifier switch, long press and nonfinite input are rejected',async()=>{
  for(const changed of [point(7,130,60),point(7,69,60),point(8),point(7,NaN,60)]){
    const f=fixture();fire(f.button,'touchstart');
    fire(f.button,'touchmove',{changedTouches:[changed],touches:[changed]});
    fire(f.button,'touchmove');fire(f.button,'touchend',{timeStamp:150});
    await click(f,{pointerType:'touch'});assert.equal(f.calls(),0);
  }
  for(const timeStamp of [99,851,NaN]){
    const f=fixture();await tap(f,{timeStamp});assert.equal(f.calls(),0);
  }
});

test('touchcancel pointercancel contextmenu and focus loss invalidate the pending gesture',async()=>{
  for(const type of ['touchcancel','pointercancel','contextmenu','blur']){
    const f=fixture();fire(f.button,'touchstart');fire(f.button,type);fire(f.button,'touchend',{timeStamp:150});
    await click(f,{pointerType:'touch'});assert.equal(f.calls(),0);
  }
});

test('extra finger elsewhere cancels even after it lifts; multi-touch start never arms',async()=>{
  const f=fixture();fire(f.button,'touchstart');
  f.button.ownerDocument.dispatchEvent(event('touchstart',{touches:[point(),point(8)]}));
  fire(f.button,'touchend',{timeStamp:150});await click(f,{pointerType:'touch'});assert.equal(f.calls(),0);
  const g=fixture();fire(g.button,'touchstart',{touches:[point(),point(8)]});
  fire(g.button,'touchend');await click(g,{pointerType:'touch'});assert.equal(g.calls(),0);
});

test('disabled disconnected inert hidden covered or moved target cannot acknowledge',async()=>{
  for(const change of [b=>{b.disabled=true;},b=>{b.isConnected=false;},b=>{b.inert=true;},
    b=>{b.hidden=true;},b=>{b.layers=[b.modal,{}];},b=>{b.hit={};},
    b=>{b.rect={left:200,top:40,right:300,bottom:80};}]){
    const f=fixture();fire(f.button,'touchstart');change(f.button);
    fire(f.button,'touchend',{timeStamp:150});await settle();assert.equal(f.calls(),0);
  }
});

test('descendant hit and exact 8px/750ms boundaries are accepted',async()=>{
  const f=fixture();f.button.hit=f.button.child;
  await tap(f,{timeStamp:850,changedTouches:[point(7,68,60)]});assert.equal(f.calls(),1);
});

test('touch-generated click before valid touchend cannot acknowledge prematurely',async()=>{
  const f=fixture();fire(f.button,'touchstart');await click(f,{pointerType:'touch'});
  assert.equal(f.calls(),0);fire(f.button,'touchend',{timeStamp:150});await settle();assert.equal(f.calls(),1);
});

test('React synthetic event uses native event provenance',async()=>{
  const f=fixture();await tap(f);
  await f.binding.onClick({nativeEvent:event('click',{pointerType:'touch'}),isTrusted:false});
  assert.equal(f.calls(),1);
});

test('cleanup detaches every button/document listener and is idempotent',async()=>{
  const f=fixture();fire(f.button,'touchstart');assert.equal(f.button.registrations.length,9);
  f.binding.cleanup();f.binding.cleanup();assert.equal(f.button.registrations.length,0);
  assert.equal(getEventListeners(f.button.ownerDocument,'touchstart').length,0);
  fire(f.button,'touchend');await click(f,{pointerId:-1,pointerType:''});assert.equal(f.calls(),0);
});

test('pending save does not close early and an extra real tap is never queued after false',async()=>{
  let resolve;const promise=new Promise(r=>{resolve=r;});const f=fixture(()=>promise);
  await tap(f);await tap(f);assert.equal(f.calls(),1);assert.equal(f.complete(),0);
  resolve(false);await settle();await click(f,{pointerType:'touch'});assert.equal(f.calls(),1);
});

test('known compatibility click from an invalid touch remains rejected after the gesture ends',async()=>{
  const f=fixture();fire(f.button,'touchstart');
  fire(f.button,'touchmove',{touches:[point(7,140,60)],changedTouches:[point(7,140,60)]});
  fire(f.button,'touchend',{timeStamp:150});
  await click(f,{pointerType:'touch',pointerId:23});assert.equal(f.calls(),0);
});

}
// Canonical and actual React owner behavior (10).
{
class Button extends EventTarget {
  isConnected=true;disabled=false;child={};modal={};registrations=[];
  ownerDocument=Object.assign(new EventTarget(),{elementFromPoint:()=>this,
    querySelectorAll:()=>[this.modal]});
  closest(selector){return selector==='[inert], [hidden]'?null:this.modal;}
  getBoundingClientRect(){return {left:20,top:40,right:120,bottom:80};}
  contains(x){return x===this.child;}
  addEventListener(type,fn,options){this.registrations.push({type,fn});super.addEventListener(type,fn,options);}
  removeEventListener(type,fn){this.registrations=this.registrations.filter(x=>x.type!==type||x.fn!==fn);super.removeEventListener(type,fn);}
}
function event(type,props={}){
  const e=new Event(type,{cancelable:true});
  for(const [k,v]of Object.entries({isTrusted:true,timeStamp:100,...props}))Object.defineProperty(e,k,{value:v});
  return e;
}
function fire(button,type,props={}){
  const point={identifier:7,clientX:60,clientY:60};
  const e=event(type,{touches:type==='touchend'?[]:[point],changedTouches:[point],...props});
  button.dispatchEvent(e);return e;
}
async function settle(){for(let i=0;i<6;i++)await Promise.resolve();}
async function tap(host){fire(host.button,'touchstart');const e=fire(host.button,'touchend',{timeStamp:150});await settle();return e;}

function mount(source,name='WelcomeNotice'){
  let index=0,pending=[],previousCount=null,previousRef=null,currentProps=null;
  const slots=[],button=new Button();const Primitive=Symbol('actual-forwardRef-Button');
  const depsEqual=(a,b)=>a&&b&&a.length===b.length&&a.every((x,i)=>Object.is(x,b[i]));
  const effect=(fn,deps)=>{
    const i=index++,old=slots[i];
    if(!old||!depsEqual(old.deps,deps))pending.push(()=>{
      old?.cleanup?.();slots[i]={deps,cleanup:fn()};
    });
  };
  const react={
    useRef(value){const i=index++;return slots[i]??={current:value};},
    useCallback(fn,deps){const i=index++,old=slots[i];
      if(!old||!depsEqual(old.deps,deps))slots[i]={deps,fn};return slots[i].fn;},
    useEffect:effect,useLayoutEffect:effect,
  };
  const jsx=(type,props)=>({type,props});
  const code=name==='WelcomeNotice'?helper(source)+'\n'+component(source,name):
    segment(source,'// BEGIN DSH_OPTIONAL_CANCEL_TOUCH_BINDER','// END DSH_OPTIONAL_CANCEL_TOUCH_BINDER')+'\n'+component(source,name);
  const Component=runInNewContext(code+`\n${name};`,{react,react_jsx_runtime:{jsx,jsxs:jsx},
    _deepseek_ai_dsh_client_ui_primitives:{Button:Primitive},
    WelcomeNotice_module_css_default:{},ModelsSection_module_css_default:{},OnboardingModal:Symbol('modal')});
  function find(tree){
    if(!tree||typeof tree!=='object')return null;
    if((name==='WelcomeNotice'&&tree.type===Primitive)||(name==='EditorFooter'&&tree.type==='button'))return tree;
    const children=tree.props?.children;for(const child of Array.isArray(children)?children:[children]){
      const match=find(child);if(match)return match;
    }return null;
  }
  return {
    button,
    render(props){
      pending=[];index=0;const tree=Component(props);
      if(previousCount!==null)assert.equal(index,previousCount,'React hook count must not change across hidden/visible renders');
      previousCount=index;
      const action=find(tree);currentProps=action?.props??null;
      if(previousRef&&previousRef!==currentProps?.ref)previousRef.current=null;
      if(currentProps?.ref){currentProps.ref.current=button;previousRef=currentProps.ref;}
      button.disabled=!!currentProps?.disabled;
      for(const perform of pending)perform();
      return tree;
    },
    click(values={}){return currentProps?.onClick?.({nativeEvent:event('click',values)});},
    dispose(){for(const slot of slots)slot?.cleanup?.();if(previousRef)previousRef.current=null;},
    props:()=>currentProps,
  };
}

test('both canonical manifests reproduce bytes with exact counts and pinned original resource',()=>{
  assert.equal(original.length,186641);assert.equal(sha(original),'7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa');
  for(const [name,m]of Object.entries(manifests)){
    assert.equal(m.rootfs_sha256,'d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0');
    assert.deepEqual(m.files,[]);assert.equal(m.patches.length,1);
    const p=m.patches[0];assert.equal(p.replacements.length,name==='touch-only'?4:5);
    assert.deepEqual(p.original_source,{source:'onboarding-client-original.js',sha256:sha(original)});
    assert.deepEqual(p.previous_sha256,['b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5']);
    let current=original.toString();
    for(const r of p.replacements){assert.equal(r.count,1);assert.equal(current.split(r.find).length-1,1);current=current.replace(r.find,r.replace);}
    assert.equal(current,clients[name]);assert.equal(sha(Buffer.from(current)),p.patched_sha256);new Script(current);
  }
});

test('head three old API replacements still reproduce known Build29 bytes exactly',()=>{
  const a=manifests['touch-only'].patches[0].replacements.slice(0,3);
  const b=manifests['touch-plus-store'].patches[0].replacements.slice(0,3);
  assert.deepEqual(a,b);let previous=original.toString();
  for(const r of a)previous=previous.replace(r.find,r.replace);
  assert.equal(Buffer.byteLength(previous),191089);
  assert.equal(sha(Buffer.from(previous)),'b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5');
  for(const source of Object.values(clients)){
    assert.equal(component(source,'EditorFooter'),component(previous,'EditorFooter'));
    const old=segment(previous,'// BEGIN DSH_OPTIONAL_CANCEL_TOUCH_BINDER','// END DSH_OPTIONAL_CANCEL_TOUCH_BINDER');
    assert.equal(segment(source,'// BEGIN DSH_OPTIONAL_CANCEL_TOUCH_BINDER','// END DSH_OPTIONAL_CANCEL_TOUCH_BINDER'),old);
  }
});

test('single canonical helper marker is identical in both candidate variants and module implementation',()=>{
  const expected=helper(patched);
  for(const source of Object.values(clients)){
    assert.equal(source.split('// BEGIN DSH_WELCOME_TOUCH_BINDER').length,2);
    assert.equal(source.split('// END DSH_WELCOME_TOUCH_BINDER').length,2);
    assert.equal(helper(source),expected);
  }
  assert.equal(sha(Buffer.from(expected+'// END DSH_WELCOME_TOUCH_BINDER\n\n')),
    '6f5a9c44eb844ff6add8e49337cbfb3a203c612a6768333644e7d8f424992b06');
});

test('actual Welcome React candidate obeys hook order and native Button ref from loading to ready',()=>{
  const h=mount(clients['touch-only']);let state={status:'idle',acknowledged:false,error:null};let loads=0;
  const props={controller:{load(){loads++;},acknowledge:async()=>false},complete(){},t:x=>x,useWelcome:fn=>fn(state)};
  h.render(props);assert.equal(h.props(),null);assert.equal(loads,1);
  state={...state,status:'ready'};h.render(props);assert.equal(h.props().ref.current,h.button);
  assert.equal(h.button.registrations.length,9);
  state={...state,status:'loading'};h.render(props);assert.equal(h.button.registrations.length,0);
  h.dispose();
});

test('actual Welcome calls latest controller once per touch and closes only after true persistence',async()=>{
  const h=mount(clients['touch-only']);let writes=0,complete=0;
  const state={status:'ready',acknowledged:false,error:null};
  const props={controller:{load(){},acknowledge:async()=>{writes++;return false;}},complete:()=>{complete++;},t:x=>x,useWelcome:fn=>fn(state)};
  h.render(props);await tap(h);h.click({pointerType:'touch'});await settle();assert.equal(writes,1);assert.equal(complete,0);
  h.render({...props,controller:{load(){},acknowledge:async()=>{writes++;return true;}}});
  await tap(h);assert.equal(writes,2);assert.equal(complete,1);
  state.acknowledged=true;h.render(props);assert.equal(complete,1);assert.equal(h.button.registrations.length,0);
  h.dispose();
});

test('actual Welcome click-only AX after failed touch retains normal original activation',async()=>{
  const h=mount(clients['touch-only']);let writes=0,complete=0;
  const state={status:'ready',acknowledged:false,error:null};
  h.render({controller:{load(){},acknowledge:async()=>++writes===2},complete:()=>{complete++;},t:x=>x,useWelcome:fn=>fn(state)});
  await tap(h);h.click({detail:0});await settle();assert.equal(writes,2);assert.equal(complete,1);h.dispose();
});

test('actual Welcome pending promise never optimistically finishes and cleanup prevents stale finish',async()=>{
  const h=mount(clients['touch-plus-store']);let resolve,complete=0;
  const pending=new Promise(r=>{resolve=r;});const state={status:'ready',acknowledged:false,error:null};
  h.render({controller:{load(){},acknowledge:()=>pending},complete:()=>{complete++;},t:x=>x,useWelcome:fn=>fn(state)});
  await tap(h);assert.equal(complete,0);h.dispose();resolve(true);await settle();assert.equal(complete,0);
});

test('actual old API cancel component still completes once for touch plus compatibility click',async()=>{
  for(const source of Object.values(clients)){
    const h=mount(source,'EditorFooter');let calls=0;
    h.render({t:x=>x,touchCancel:true,cancelLabelKey:'onboardingLater',busy:false,onCancel:()=>{calls++;}});
    await tap(h);h.props().onClick();assert.equal(calls,1);h.dispose();
  }
});

test('old unrelated cancel keeps original handler and adds no touch binder',()=>{
  const h=mount(clients['touch-only'],'EditorFooter');let calls=0;
  h.render({t:x=>x,touchCancel:true,cancelLabelKey:'cancel',busy:false,onCancel:()=>{calls++;}});
  assert.equal(h.button.registrations.length,0);h.props().onClick();assert.equal(calls,1);h.dispose();
});

test('old API busy guard retains its latest state and does not permanently consume while busy',async()=>{
  const h=mount(clients['touch-only'],'EditorFooter');let calls=0;
  const props={t:x=>x,touchCancel:true,cancelLabelKey:'onboardingLater',busy:true,onCancel:()=>{calls++;}};
  h.render(props);await tap(h);assert.equal(calls,0);
  h.render({...props,busy:false});await tap(h);assert.equal(calls,1);h.dispose();
});

}
// Controlled WK-fixture footer accounting only (7).
{
const helper=shippedHelper;
const footer=readFileSync(resolve(root,'tests/fixtures/welcome-touch-footer.js'),'utf8');
const ids=['original','quick','slow','pending','resolve-false','retry-false','retry-reject','drag','cleaned'];
const point=(x=60,y=60)=>({identifier:7,clientX:x,clientY:y});
function fixture(){
  const latest=new Map(),messages=[],buttons=new Map();const modal={};
  const doc={getElementById:id=>buttons.get(id)??null,addEventListener(){},removeEventListener(){},
    querySelectorAll:()=>[modal],elementFromPoint:()=>currentHit};let currentHit=null;
  for(const id of ids){
    buttons.set('welcome-'+id,{tagName:'BUTTON',ownerDocument:doc,isConnected:true,disabled:false,
      listeners:[],onclick:null,
      addEventListener(type,fn,options){this.listeners.push({type,fn,options});},
      removeEventListener(type,fn){this.listeners=this.listeners.filter(x=>x.type!==type||x.fn!==fn);},
      closest:selector=>selector==='[inert], [hidden]'?null:modal,
      getBoundingClientRect:()=>({left:20,top:40,right:120,bottom:80}),contains:()=>false});
  }
  runInNewContext(helper+'\n'+footer,{document:doc,window:{webkit:{messageHandlers:{dshWelcomeFixture:{postMessage(value){
    const copy=JSON.parse(JSON.stringify(value));messages.push(copy);latest.set(copy.scenario,copy);
  }}}}}});
  function fire(id,type,props={}){
    const b=buttons.get('welcome-'+id);assert.ok(b);currentHit=b;let stopped=false;
    const e=new Event(type,{cancelable:true});
    for(const [key,value]of Object.entries({isTrusted:true,timeStamp:100,
      touches:type==='touchend'?[]:[point()],changedTouches:[point()],...props}))Object.defineProperty(e,key,{value});
    e.stopImmediatePropagation=()=>{stopped=true;};
    const listeners=b.listeners.filter(x=>x.type===type);
    for(const item of listeners.filter(x=>x.options?.capture))if(!stopped)item.fn(e);
    if(type==='click'&&!stopped)b.onclick?.(e);
    for(const item of listeners.filter(x=>!x.options?.capture))if(!stopped)item.fn(e);
    return e;
  }
  return {latest,messages,fire};
}
const settle=async()=>{for(let i=0;i<15;i++)await Promise.resolve();};
async function tap(f,id,at=150){f.fire(id,'touchstart');const e=f.fire(id,'touchend',{timeStamp:at});await settle();return e;}

test('footer only emits the exact bounded receipt schema and never changes WebDOM',()=>{
  assert.doesNotMatch(footer,/\.(?:innerHTML|textContent|className|style)\s*=|getBoundingClientRect|elementFromPoint|dispatchEvent|evaluateJavaScript|requestAnimationFrame/);
  const f=fixture();assert.equal(f.latest.size,8);
  const allowed=['version','scenario','touchStarts','trustedEnds','moves','cancels','naturalClicks',
    'blockedClicks','preventedEnds','uncancelableEnds','ackCalls','finishes','rejections','settled',
    'controls','status','acknowledged','disposed','ambiguousClicks'].sort();
  for(const m of f.messages){assert.deepEqual(Object.keys(m).sort(),allowed);
    for(const key of allowed.filter(x=>!['version','scenario','status','acknowledged','disposed'].includes(x)))
      assert.ok(Number.isInteger(m[key])&&m[key]>=0);
    assert.ok(['ready','saving','error'].includes(m.status));assert.equal(typeof m.acknowledged,'boolean');}
});

test('original click-only control exposes withholding without invoking acknowledgement',async()=>{
  const f=fixture();await tap(f,'original');const e=f.fire('original','click');
  assert.equal(e.defaultPrevented,true);
  const m=f.latest.get('original');assert.equal(m.trustedEnds,1);assert.equal(m.blockedClicks,1);
  assert.equal(m.naturalClicks,1);assert.equal(m.ackCalls,0);assert.equal(m.finishes,0);
});

test('controlled quick/slow touches account cancellation and strict durable completion',async()=>{
  const f=fixture();await tap(f,'quick');await tap(f,'slow',300);
  const q=f.latest.get('quick'),s=f.latest.get('slow');
  assert.equal(q.preventedEnds,1);assert.equal(q.ackCalls,1);assert.equal(q.finishes,0);assert.equal(q.status,'error');
  assert.equal(s.preventedEnds,1);assert.equal(s.ackCalls,1);assert.equal(s.finishes,1);assert.equal(s.acknowledged,true);
  assert.equal(q.naturalClicks,0);assert.equal(s.naturalClicks,0);
  // Zero here is controlled input, NOT evidence actual WK suppressed click.
});

test('pending second touch is never queued; real control action settles false; next touch retries',async()=>{
  const f=fixture();await tap(f,'pending');await tap(f,'pending');
  let m=f.latest.get('pending');assert.equal(m.ackCalls,1);assert.equal(m.status,'saving');assert.equal(m.settled,0);assert.equal(m.finishes,0);
  f.fire('resolve-false','click');await settle();m=f.latest.get('pending');
  assert.equal(m.controls,1);assert.equal(m.ackCalls,1);assert.equal(m.settled,1);assert.equal(m.status,'error');assert.equal(m.finishes,0);
  await tap(f,'pending');m=f.latest.get('pending');assert.equal(m.ackCalls,2);assert.equal(m.settled,2);assert.equal(m.finishes,1);
});

test('controlled false and real promise rejection each allow exactly the next explicit retry',async()=>{
  const f=fixture();
  for(const id of ['retry-false','retry-reject']){
    await tap(f,id);let m=f.latest.get(id);assert.equal(m.ackCalls,1);assert.equal(m.settled,1);assert.equal(m.finishes,0);assert.equal(m.status,'error');
    assert.equal(m.rejections,id==='retry-reject'?1:0);
    await tap(f,id);m=f.latest.get(id);assert.equal(m.ackCalls,2);assert.equal(m.settled,2);assert.equal(m.finishes,1);
  }
});

test('drag/cancel and detached handler produce no persistence action',async()=>{
  const f=fixture();f.fire('drag','touchstart');
  f.fire('drag','touchmove',{touches:[point(260)],changedTouches:[point(260)]});
  f.fire('drag','touchcancel');f.fire('drag','touchend',{timeStamp:150});await settle();
  let m=f.latest.get('drag');assert.equal(m.moves,1);assert.equal(m.cancels,1);assert.equal(m.ackCalls,0);assert.equal(m.finishes,0);
  await tap(f,'cleaned');f.fire('cleaned','click');await settle();m=f.latest.get('cleaned');
  assert.equal(m.disposed,true);assert.equal(m.ackCalls,0);assert.equal(m.finishes,0);
});

test('injected anonymous-click contract violation remains visible, never hidden by counting logic',async()=>{
  const f=fixture();await tap(f,'quick');f.fire('quick','click',{detail:0});await settle();
  const m=f.latest.get('quick');assert.equal(m.preventedEnds,1);assert.equal(m.naturalClicks,1);
  assert.equal(m.ackCalls,2); // Expected rejection by real-WK acceptance, not a pass.
});

}
