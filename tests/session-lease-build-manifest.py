"""Produce the exact, pinned guest package patch; no rootfs archive mutation."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/SessionLifecycle.bundle'
TARGET = '/usr/local/lib/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js'
ORIGINAL_SHA = '0845707017acc2b4a8a75eab2244fa3fd88587b8094ab32014321dce7ca1e31b'
ROOTFS_SHA = 'd3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0'


def build(source):
    assert hashlib.sha256(source).hexdigest() == ORIGINAL_SHA, 'unrecognized package source'
    replacements = []
    patched = source.decode('utf-8')

    def replace(find, replacement, count=1):
        nonlocal patched
        assert patched.count(find) == count, (find[:80], patched.count(find), count)
        patched = patched.replace(find, replacement)
        replacements.append({'find': find, 'replace': replacement, 'count': count})

    replace('import z from "@deepseek-ai/schemastery";',
            'import { SessionLifecycleAdmission, registerSessionBackend, unregisterSessionBackend } from "/usr/local/share/dsh/session-lifecycle.mjs";\n'
            'import z from "@deepseek-ai/schemastery";')
    replace('\tdraining;\n\tconstructor(storage', '\tdraining;\n\tdshCheckpoint;\n\tdshPausedEvents = [];\n\tdshClosingAdmitted = false;\n\tconstructor(storage')
    replace('''\t* unwinds first; a drain or lock-release failure still frees the in-process
\t* claim, then rejects — both failures together reject as one
\t* `AggregateError`.''', '''\t* unwinds first. A failed drain or lock release retains the in-process
\t* ownership claim and buffered events for a later close retry; lifecycle
\t* suspension never treats that failure as a released writer.''')
    replace('''\tclose() {
\t\treturn this.closing ??= (async () => {
\t\t\tlet drainFailure;
\t\t\tfor (;;) {
\t\t\t\ttry {
\t\t\t\t\tawait this.drainLive();
\t\t\t\t} catch (error) {
\t\t\t\t\tdrainFailure = error;
\t\t\t\t\tbreak;
\t\t\t\t}
\t\t\t\tawait this.chain;
\t\t\t\tif (this.buffered.length === 0) break;
\t\t\t}
\t\t\tawait this.chain;
\t\t\tconst failures = [];
\t\t\tif (drainFailure !== void 0) failures.push(drainFailure instanceof Error ? drainFailure : new Error(errorChain(drainFailure)));
\t\t\ttry {
\t\t\t\tawait this.lease?.release();
\t\t\t} catch (releaseFailure) {
\t\t\t\t/* v8 ignore next -- lock releases reject with Error */
\t\t\t\tfailures.push(releaseFailure instanceof Error ? releaseFailure : new Error(errorChain(releaseFailure)));
\t\t\t}
\t\t\tthis.storage.releaseHandle(this, this.state.materialized);
\t\t\tif (failures.length > 1) throw new AggregateError(failures, `session "${this.id}": close failed to drain and to release its write lock`);
\t\t\tif (failures[0] !== void 0) throw failures[0];
\t\t})();
\t}''', '''\tclose() {
\t\tif (this.closing !== void 0) return this.closing;
\t\tconst closing = this.storage.dshLifecycleAdmission.run(async () => {
\t\t\tthis.dshClosingAdmitted = true;
\t\t\ttry {
\t\t\tthis.buffered = this.buffered.concat(this.dshPausedEvents);
\t\t\tthis.dshPausedEvents = [];
\t\t\tfor (;;) {
\t\t\t\tawait this.drainLive();
\t\t\t\tawait this.chain;
\t\t\t\tif (this.buffered.length === 0) break;
\t\t\t}
\t\t\t// Failed drains retain both the batch and its ownership claim.
\t\t\tawait this.lease?.release();
\t\t\tthis.lease = void 0;
\t\t\tthis.storage.releaseHandle(this, this.state.materialized);
\t\t\t} finally { this.dshClosingAdmitted = false; }
\t\t});
\t\tthis.closing = closing.catch(error => {
\t\t\tthis.closing = void 0;
\t\t\tthis.storage.dshLifecycleAdmission.fail();
\t\t\tthrow error;
\t\t});
\t\treturn this.closing;
\t}''')
    replace('''\t\tthis.buffered.push(structuredClone(event));
\t\tif (this.batchTimer''', '''\t\t// A normally closing caller has already stopped its producer. Its
\t\t// admitted final batch must still drain; a paused close has no ticket.
\t\tif (this.storage.dshLifecycleAdmission.state !== "running" && !this.dshClosingAdmitted) {
\t\t\tthis.dshPausedEvents.push(structuredClone(event));
\t\t\treturn;
\t\t}
\t\tthis.buffered.push(structuredClone(event));
\t\tif (this.storage.dshLifecycleAdmission.state !== "running") return;
\t\tif (this.batchTimer''')
    replace('''\tdrainLive() {
\t\treturn this.draining ??= this.drainBuffered().finally(() => {
\t\t\tthis.draining = void 0;
\t\t});
\t}''', '''\tdrainLive() {
\t\treturn this.storage.dshLifecycleAdmission.run(() =>
\t\t\tthis.draining ??= this.drainBuffered().finally(() => {
\t\t\t\tthis.draining = void 0;
\t\t\t}));
\t}''')
    replace('''\tasync ensureLease() {
\t\tthis.lease ??= await this.storage.acquireWriteLease(this.header);
\t}''', '''\tasync ensureLease() {
\t\treturn this.storage.dshLifecycleAdmission.run(async () => {
\t\t\tif (this.lease?.dshUncertain) {
\t\t\t\tthis.storage.dshLifecycleAdmission.fail();
\t\t\t\tthrow Object.assign(new Error("session lease close state is uncertain"), { code: "DSH_SESSION_LEASE_UNCERTAIN" });
\t\t\t}
\t\t\tthis.lease ??= await this.storage.acquireWriteLease(this.header);
\t\t});
\t}''')
    replace('''\tasync run(operation, op) {
\t\tthis.assertOpen(operation);
\t\treturn this.enqueueChain(async () => {
\t\t\tthis.assertOpen(operation);
\t\t\treturn op();
\t\t});
\t}''', '''\tasync run(operation, op) {
\t\tthis.assertOpen(operation);
\t\treturn this.storage.dshLifecycleAdmission.run(() => this.enqueueChain(async () => {
\t\t\tthis.assertOpen(operation);
\t\t\treturn op();
\t\t}));
\t}''')
    replace('''\t\tif (this.released) return;
\t\tthis.released = true;
\t\t/* v8 ignore start -- native Windows coverage exercises this platform branch; Linux covers the POSIX peer */''',
            '''\t\tif (this.released) return;
\t\tif (this.dshUncertain) throw Object.assign(new Error("session lease close state is uncertain"), { code: "DSH_SESSION_LEASE_UNCERTAIN" });
\t\t// close may consume the descriptor even when it rejects. Never retry
\t\t// an uncertain descriptor, or assume that it still owns the flock.
\t\tthis.dshUncertain = true;
\t\t/* v8 ignore start -- native Windows coverage exercises this platform branch; Linux covers the POSIX peer */''')
    replace('''\t\t\tawait releaseLockHandleWin32(this.held.handle);
\t\t\treturn;''', '''\t\t\tawait releaseLockHandleWin32(this.held.handle);
\t\t\tthis.released = true;
\t\t\tthis.dshUncertain = false;
\t\t\treturn;''')
    replace('''\t\tawait this.held.handle.close();
\t}
};''', '''\t\tawait this.held.handle.close();
\t\tthis.released = true;
\t\tthis.dshUncertain = false;
\t}
};''')
    replace('\ttracker = new JsonlBackendTracker(this.name);',
            '\ttracker = new JsonlBackendTracker(this.name);\n\tdshLifecycleAdmission = new SessionLifecycleAdmission();')
    replace('''\t\tthis.tracker.install(ctx);
\t}''', '''\t\tthis.tracker.install(ctx);
\t\tthis.tracker.dshLifecycleBackend = this;
\t\tregisterSessionBackend(this);
\t}''')
    replace('''\t\t\tif (errors.length > 0) throw new AggregateError(errors, `${this.name} dispose failed`);''',
            '''\t\t\tif (errors.length > 0) throw new AggregateError(errors, `${this.name} dispose failed`);
\t\t\tunregisterSessionBackend(this.dshLifecycleBackend);''')
    replace('''\tasync create(header, options) {
\t\toptions?.signal''', '''\tasync create(header, options) {
\t\treturn this.dshLifecycleAdmission.run(() => this.dshCreateAdmitted(header, options));
\t}
\tasync dshCreateAdmitted(header, options) {
\t\toptions?.signal''')
    replace('''\tasync open(id, access, options) {
\t\toptions?.signal''', '''\tasync open(id, access, options) {
\t\tif (access === "read") return this.dshOpenAdmitted(id, access, options);
\t\treturn this.dshLifecycleAdmission.run(() => this.dshOpenAdmitted(id, access, options));
\t}
\tasync dshOpenAdmitted(id, access, options) {
\t\toptions?.signal''')
    methods = '''
\t// These hooks retain the exact logical handle owned by Agent teardown.
\tdshLifecycleBeginQuiesce() {
\t\tthis.dshLifecycleAdmission.close();
\t\tfor (const handle of this.tracker.openHandles) {
\t\t\tif (handle.batchTimer !== void 0) clearTimeout(handle.batchTimer);
\t\t\thandle.batchTimer = void 0;
\t\t}
\t}
\tdshLifecycleSnapshot() {
\t\tlet writer_count = 0, released_count = 0, pending_events = 0;
\t\tfor (const writer of this.tracker.writers.values()) {
\t\t\tif (writer === null) continue;
\t\t\twriter_count += 1;
\t\t\tif (writer.dshCheckpoint !== void 0 && writer.lease === void 0) released_count += 1;
\t\t\tpending_events += writer.buffered.length + writer.dshPausedEvents.length;
\t\t}
\t\treturn { writer_count, released_count, pending_events };
\t}
\tdshLifecycleFail() { this.dshLifecycleAdmission.fail(); }
\tdshLifecycleFingerprint(stored) {
\t\treturn createHash("sha256").update(JSON.stringify({
\t\t\theader: stored.meta, events: stored.events,
\t\t\tinheritedEventCount: stored.inheritedEventCount,
\t\t\ttornTruncateTo: stored.tornTruncateTo,
\t\t\trecoveredTail: stored.recoveredTail
\t\t})).digest("hex");
\t}
\tasync dshLifecycleSuspend() {
\t\tthis.dshLifecycleBeginQuiesce();
\t\ttry {
\t\tawait this.dshLifecycleAdmission.drain(async () => {
\t\t\tfor (const writer of [...this.tracker.writers.values()]) {
\t\t\t\tif (writer === null) continue;
\t\t\t\tif (writer.dshCheckpoint !== void 0) {
\t\t\t\t\t// A failed/abandoned resume may already own a fresh lease.
\t\t\t\t\t// Never append its retained events before checkpoint validation.
\t\t\t\t\tawait writer.lease?.release();
\t\t\t\t\twriter.lease = void 0;
\t\t\t\t\tcontinue;
\t\t\t\t}
\t\t\t\tif (this.dshLifecycleAdmission.failure) throw Object.assign(new Error("session storage has no verified checkpoint after failure"), { code: "DSH_SESSION_STORAGE_UNCERTAIN" });
\t\t\t\tawait writer.drainLive();
\t\t\t\tawait writer.chain;
\t\t\t\tif (!writer.state.materialized) {
\t\t\t\t\tawait writer.ensureLease();
\t\t\t\t\tawait this.persistHeader(writer.header, writer.state.inheritedEventCount);
\t\t\t\t\twriter.state.materialized = true;
\t\t\t\t}
\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\tconst stored = await this.requireStoredLog(writer.id);
\t\t\t\tif (stored.events.length !== writer.state.cursor) {
\t\t\t\t\tconst error = new Error("session checkpoint changed");
\t\t\t\t\terror.code = "DSH_SESSION_CHECKPOINT_CHANGED";
\t\t\t\t\tthrow error;
\t\t\t\t}
\t\t\t\tconst checkpoint = this.dshLifecycleFingerprint(stored);
\t\t\t\twriter.dshCheckpoint = checkpoint;
\t\t\t\tawait writer.lease?.release();
\t\t\t\twriter.lease = void 0;
\t\t\t}
\t\t});
\t\tthis.dshLifecycleAdmission.markQuiesced();
\t\treturn this.dshLifecycleSnapshot();
\t\t} catch (error) { this.dshLifecycleFail(); throw error; }
\t}
\tasync dshLifecycleResume() {
\t\tif (this.dshLifecycleAdmission.state === "running") return;
\t\tthis.dshLifecycleAdmission.beginResume();
\t\ttry {
\t\tawait this.dshLifecycleAdmission.drain(async () => {
\t\t\tfor (const writer of [...this.tracker.writers.values()]) {
\t\t\t\tif (writer === null) continue;
\t\t\t\tif (writer.lease?.dshUncertain) throw Object.assign(new Error("session lease close state is uncertain"), { code: "DSH_SESSION_LEASE_UNCERTAIN" });
\t\t\t\tif (writer.dshCheckpoint === void 0) {
\t\t\t\t\tif (this.dshLifecycleAdmission.failure) throw Object.assign(new Error("session storage has no verified checkpoint after failure"), { code: "DSH_SESSION_STORAGE_UNCERTAIN" });
\t\t\t\t\tcontinue;
\t\t\t\t}
\t\t\t\tawait writer.ensureLease();
\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\tconst stored = await this.requireStoredLog(writer.id);
\t\t\t\tif (this.dshLifecycleFingerprint(stored) !== writer.dshCheckpoint) {
\t\t\t\t\tconst error = new Error("session checkpoint changed");
\t\t\t\t\terror.code = "DSH_SESSION_CHECKPOINT_CHANGED";
\t\t\t\t\tthrow error;
\t\t\t\t}
\t\t\t\t// Retained events are acknowledged as running only after their
\t\t\t\t// ordered durability barrier succeeds under the reacquired lease.
\t\t\t\t// New arrivals remain isolated, so this is a bounded snapshot.
\t\t\t\twriter.buffered = writer.buffered.concat(writer.dshPausedEvents);
\t\t\t\twriter.dshPausedEvents = [];
\t\t\t\tawait writer.drainLive();
\t\t\t\tawait writer.chain;
\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\twriter.dshCheckpoint = this.dshLifecycleFingerprint(await this.requireStoredLog(writer.id));
\t\t\t}
\t\t});
\t\t} catch (error) { this.dshLifecycleFail(); throw error; }
\t}
\tdshLifecycleOpen() {
\t\tfor (const writer of this.tracker.writers.values()) {
\t\t\tif (writer?.lease?.dshUncertain) throw Object.assign(new Error("session lease close state is uncertain"), { code: "DSH_SESSION_LEASE_UNCERTAIN" });
\t\t}
\t\tfor (const writer of this.tracker.writers.values()) if (writer !== null) {
\t\t\twriter.dshCheckpoint = void 0;
\t\t\twriter.buffered = writer.buffered.concat(writer.dshPausedEvents);
\t\t\twriter.dshPausedEvents = [];
\t\t}
\t\tthis.dshLifecycleAdmission.open();
\t\t// Retained events use their original handle/chain and original seq numbers.
\t\tfor (const writer of this.tracker.writers.values()) {
\t\t\tif (writer !== null && writer.buffered.length > 0) writer.drainLive().catch(() => {
\t\t\t\tthis.ctx.logger.warn("session-persistence: retained lifecycle batch drain failed; events preserved");
\t\t\t});
\t\t}
\t}
'''
    replace('\tflush() {\n\t\treturn this.tracker.flushAll();\n\t}',
            '\tflush() {\n\t\treturn this.dshLifecycleAdmission.run(() => this.tracker.flushAll());\n\t}\n' + methods)
    output = patched.encode('utf-8')
    files = []
    for name in ('session-lifecycle.mjs', 'session-lifecycle-core.mjs'):
        data = (BUNDLE / name).read_bytes().replace(b'\r\n', b'\n')
        (BUNDLE / name).write_bytes(data)
        files.append({'source': name, 'target': '/usr/local/share/dsh/' + name,
                      'sha256': hashlib.sha256(data).hexdigest()})
    manifest = {'schema': 1, 'rootfs_sha256': ROOTFS_SHA,
                'patches': [{'target': TARGET, 'original_sha256': ORIGINAL_SHA,
                  'patched_sha256': hashlib.sha256(output).hexdigest(), 'replacements': replacements}],
                'files': files}
    (BUNDLE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return manifest, output


if __name__ == '__main__':
    source = Path(sys.argv[1]).read_bytes().replace(b'\r\n', b'\n')
    manifest, patched = build(source)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_bytes(patched)
    print(json.dumps({k: v for k, v in manifest['patches'][0].items() if k != 'replacements'}))
