"""Exact additions to the pinned package; the canonical resource is immutable."""


def append_prepared_patches(replace):
    replace('import z from "@deepseek-ai/schemastery";',
            'import { beginDecodedSnapshot, rememberDecodedSnapshot, invalidatePreparedCheckpoint, invalidatePreparedPath, retirePreparedCheckpoint, retireUnadoptedCheckpoint, adoptDecodedCheckpoint, checkpointFromDecoded, verifyDecodedCheckpoint, verifyPreparedCheckpoint, assertCheckpointNotPoisoned } from "/usr/local/share/dsh/session-checkpoint-core.mjs";\n'
            'import z from "@deepseek-ai/schemastery";')
    replace('\t\tthis.lease = lease;\n\t}',
            '\t\tthis.lease = lease;\n\t\tif (access === "write" && state.primed !== void 0) adoptDecodedCheckpoint(storage, this, state.primed, true);\n\t}')
    replace('\t\tconst source = await this.storage.readStoredLog(path, this.id, signal);',
            '\t\tconst source = await this.storage.readStoredLog(path, this.id, signal);\n\t\tif (this.access === "write") adoptDecodedCheckpoint(this.storage, this, source);')
    replace('\t\t\tthis.dshClosingAdmitted = true;\n\t\t\ttry {',
            '\t\t\tthis.dshClosingAdmitted = true;\n\t\t\ttry {\n\t\t\tretirePreparedCheckpoint(this.storage, this);')
    replace('\t\tif (batch.length === 0) return;\n\t\tawait this.ensureLease();',
            '\t\tif (batch.length === 0) return;\n\t\tinvalidatePreparedCheckpoint(this.storage, this.id);\n\t\tawait this.ensureLease();')
    replace('\t\t\tif (this.state.materialized) return;\n\t\t\tawait this.ensureLease();',
            '\t\t\tif (this.state.materialized) return;\n\t\t\tinvalidatePreparedCheckpoint(this.storage, this.id);\n\t\t\tawait this.ensureLease();')
    replace('\t\t\t\tbytes,\n\t\t\t\tidentity: after\n',
            '\t\t\t\tbytes,\n\t\t\t\tidentity: after,\n\t\t\t\tdshCompleteStable: true\n')
    replace('\t\tconst current = await readStableJsonlFile(selected.sourcePath, signal);\n\t\treturn this.decodeStoredLog(selected.sourcePath, id, current.bytes, fileRevision(current.identity), signal);',
            '\t\tconst dshContext = beginDecodedSnapshot(this, id, selected.sourcePath);\n'
            '\t\tconst current = await readStableJsonlFile(selected.sourcePath, signal);\n'
            '\t\treturn this.decodeStoredLog(selected.sourcePath, id, current.bytes, fileRevision(current.identity), signal, current, dshContext);')
    replace('\t\tconst { bytes, identity } = await readStableJsonlFile(path, signal);\n\t\treturn this.decodeStoredLog(path, expectedId, bytes, fileRevision(identity), signal);',
            '\t\tconst dshContext = beginDecodedSnapshot(this, expectedId, path);\n'
            '\t\tconst snapshot = await readStableJsonlFile(path, signal);\n'
            '\t\treturn this.decodeStoredLog(path, expectedId, snapshot.bytes, fileRevision(snapshot.identity), signal, snapshot, dshContext);')
    replace('\tasync decodeStoredLog(path, expectedId, buffer, revision, signal) {',
            '\tasync decodeStoredLog(path, expectedId, buffer, revision, signal, dshSnapshot, dshContext) {')
    replace('\t\tthis.memoizeStoredLog(expectedId, stored);\n\t\treturn stored;',
            '\t\tif (dshContext !== void 0) rememberDecodedSnapshot(stored, path, buffer, dshSnapshot, dshContext);\n\t\tthis.memoizeStoredLog(expectedId, stored);\n\t\treturn stored;')
    for signature, id_expression in (
            ('async persistBatch(header, events, isMaterialized, inheritedEventCount)', 'header.id'),
            ('async persistHeader(header, inheritedEventCount)', 'header.id'),
            ('async truncateTornTail(header, truncateTo)', 'header.id'),
            ('async publishStoredMigration(id, stored)', 'id'),
            ('async materialize(meta, inheritedEventCount, events)', 'meta.id'),
            ('async materializePosix(project, dir, finalPath, id, content)', 'id'),
            ('async materializeWin32(project, dir, finalPath, id, content)', 'id'),
            ('async appendLines(meta, events)', 'meta.id'),
            ('async repair(meta, offset)', 'meta.id')):
        replace('\t' + signature + ' {', '\t' + signature + ' {\n\t\tinvalidatePreparedCheckpoint(this, ' + id_expression + ');')
    replace('\tasync rollbackAppend(path, size) {',
            '\tasync rollbackAppend(path, size) {\n\t\tinvalidatePreparedPath(this, path);')
    replace('\tasync writeSyncedTempFile(finalPath, content) {',
            '\tasync writeSyncedTempFile(finalPath, content) {\n\t\tinvalidatePreparedPath(this, finalPath);')
    replace('\treleaseHandle(handle, materialized) {\n\t\tthis.tracker.release(handle, materialized);',
            '\treleaseHandle(handle, materialized) {\n\t\tretirePreparedCheckpoint(this, handle);\n\t\tthis.tracker.release(handle, materialized);')
    replace('\t\t\tthis.tracker.releaseClaim(id);',
            '\t\t\tretireUnadoptedCheckpoint(this, id);\n\t\t\tthis.tracker.releaseClaim(id);')
    replace('\t\t\tpeak_writer_transitions: 0, transition_ms: 0\n',
            '\t\t\tpeak_writer_transitions: 0, transition_ms: 0,\n\t\t\tprepared_verified_count: 0, background_full_decode_count: 0, raw_verified_bytes: 0\n')
    replace('\t\t\t\tif (writer.dshCheckpoint !== void 0) {\n',
            '''\t\t\t\tif (writer.dshCheckpoint !== void 0) {
\t\t\t\t\tassertCheckpointNotPoisoned(writer);
\t\t\t\t\tif (writer.lease !== void 0) {
\t\t\t\t\t\tconst verified = await this.dshLifecycleTimed("checkpoint_hash_ms", () => verifyPreparedCheckpoint(this, writer));
\t\t\t\t\t\tif (verified === void 0) {
\t\t\t\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\t\t\t\tthis.dshLifecycleDiagnostics.background_full_decode_count += 1;
\t\t\t\t\t\t\tconst stored = await this.dshLifecycleTimed("checkpoint_read_ms", () => this.requireStoredLog(writer.id));
\t\t\t\t\t\t\tverifyDecodedCheckpoint(this, writer, stored, writer.dshCheckpoint);
\t\t\t\t\t\t\twriter.dshCheckpoint = checkpointFromDecoded(this, writer, stored);
\t\t\t\t\t\t\tthis.dshLifecycleDiagnostics.raw_verified_bytes += writer.dshCheckpoint.bytes ?? 0;
\t\t\t\t\t\t} else {
\t\t\t\t\t\t\tthis.dshLifecycleDiagnostics.prepared_verified_count += 1;
\t\t\t\t\t\t\tthis.dshLifecycleDiagnostics.raw_verified_bytes += verified.bytes ?? 0;
\t\t\t\t\t\t}
\t\t\t\t\t}
''')
    replace('''\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\tconst stored = await this.dshLifecycleTimed("checkpoint_read_ms", () => this.requireStoredLog(writer.id));
\t\t\t\tif (stored.events.length !== writer.state.cursor) {
\t\t\t\t\tconst error = new Error("session checkpoint changed");
\t\t\t\t\terror.code = "DSH_SESSION_CHECKPOINT_CHANGED";
\t\t\t\t\tthrow error;
\t\t\t\t}
\t\t\t\tconst checkpoint = this.dshLifecycleFingerprint(stored);
\t\t\t\twriter.dshCheckpoint = checkpoint;''', '''\t\t\t\tlet checkpoint = await this.dshLifecycleTimed("checkpoint_hash_ms", () => verifyPreparedCheckpoint(this, writer));
\t\t\t\tif (checkpoint !== void 0) {
\t\t\t\t\tthis.dshLifecycleDiagnostics.prepared_verified_count += 1;
\t\t\t\t} else {
\t\t\t\t\tthis.coldLogMemo.delete(writer.id);
\t\t\t\t\tthis.dshLifecycleDiagnostics.background_full_decode_count += 1;
\t\t\t\t\tconst stored = await this.dshLifecycleTimed("checkpoint_read_ms", () => this.requireStoredLog(writer.id));
\t\t\t\t\tif (stored.events.length !== writer.state.cursor) throw Object.assign(new Error("session checkpoint changed"), { code: "DSH_SESSION_CHECKPOINT_CHANGED" });
\t\t\t\t\tcheckpoint = checkpointFromDecoded(this, writer, stored);
\t\t\t\t}
\t\t\t\tthis.dshLifecycleDiagnostics.raw_verified_bytes += checkpoint.bytes ?? 0;
\t\t\t\twriter.dshCheckpoint = checkpoint;''')
    replace('''\t\t\t\tif (this.dshLifecycleFingerprint(stored) !== writer.dshCheckpoint) {
\t\t\t\t\tconst error = new Error("session checkpoint changed");
\t\t\t\t\terror.code = "DSH_SESSION_CHECKPOINT_CHANGED";
\t\t\t\t\tthrow error;
\t\t\t\t}''', '\t\t\t\tverifyDecodedCheckpoint(this, writer, stored, writer.dshCheckpoint);')
    replace('\t\t\t\t\twriter.dshCheckpoint = this.dshLifecycleFingerprint(await this.dshLifecycleTimed("checkpoint_read_ms", () => this.requireStoredLog(writer.id)));',
            '\t\t\t\t\twriter.dshCheckpoint = checkpointFromDecoded(this, writer, await this.dshLifecycleTimed("checkpoint_read_ms", () => this.requireStoredLog(writer.id)));')
