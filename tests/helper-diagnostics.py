#!/usr/bin/env python3
"""Bounded, allowlisted failed-test evidence; never copy command/output text.

Temporary fixtures live until unittest has recorded the final assertion result.
Export failures add a cleanup error without replacing the original test failure.
"""
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
import uuid

MAX_SOURCE_BYTES = 128 * 1024
MAX_BUNDLE_BYTES = 1024 * 1024
MAX_RUN_BYTES = 16 * 1024 * 1024
MAX_BUNDLES = 64
MAX_ROWS = 128
MAX_FIXTURES = 16
MAX_JOB_TRACKING_ENTRIES = 16
OMIT = object()


def enum(*values): return frozenset(values)


STATUS = enum('not-requested', 'unconfirmed', 'confirmed', 'ps-nonzero', 'malformed-row',
    'os-error', 'timeout', 'not-collected', 'completed', 'failed', 'timed-out', 'tool-unavailable',
    'permission-denied', 'tool-or-output-unavailable', 'no-sanitized-frames', 'macOS-only',
    'skipped-identity-unconfirmed', 'skipped-budget-exhausted', 'matched', 'changed-or-unavailable',
    'running', 'nonzero-exit', 'budget-exhausted', 'observations-recorded', 'unavailable',
    'skipped-process-tree-unavailable', 'skipped-leader-identity-changed',
    'skipped-leader-identity-unconfirmed', 'no-node-processes', 'observer-error')
ERROR = enum('OSError', 'PermissionError', 'FileNotFoundError', 'TimeoutExpired', 'ChildProcessError',
    'ObserverCleanupFailure', 'Unconfirmed', 'ValueError', 'RuntimeError', 'TypeError',
    'pids-read-failed', 'pids-debug-type-unavailable', 'original-process-ended-before-attach',
    'macOS-only; no fabricated sample')
NUM = 'number'
BOOL = 'bool'
PROCESS = dict(pid=NUM, ppid=NUM, pgid=NUM, state='process-state')
QUERY = dict(status=STATUS, rows_seen=NUM, matched_rows=NUM, return_code=NUM, errno=NUM,
             malformed_kind=enum('field-count', 'numeric-field', 'state-field', 'value-error'),
             state_length=NUM, state_is_ascii=BOOL, state_has_question_mark=BOOL, darwin_unknown_state_rows=NUM)
TOOL = dict(tool=enum('ps-identity', 'ps-group', 'ps-tree', 'lsof', 'sample', 'lldb'),
    purpose=enum('identity-check', 'initial-identity', 'leader-before-tree', 'leader-after-tree',
        'supervised-group', 'host-descriptors', 'host-all-threads', 'guest-process-tree',
        'guest-descriptors', 'guest-all-threads', 'guest-snapshot'), pid=NUM,
    limit_seconds=NUM, remaining_seconds=NUM, allocated_timeout_seconds=NUM,
    monotonic_start_seconds=NUM, monotonic_end_seconds=NUM, elapsed_seconds=NUM,
    status=STATUS, return_code=NUM, errno=NUM)
TIMING = dict(tool_observations=[TOOL], observation_started_monotonic_seconds=NUM,
    observation_deadline_monotonic_seconds=NUM, observation_ended_monotonic_seconds=NUM,
    observation_elapsed_seconds=NUM)
SAMPLE = dict(label=enum('initial', '75-seconds'), observer_pid=NUM, observer_pgid=NUM,
    exit_status=NUM, forced_cleanup=BOOL, cleanup_reason=enum('observer-cleanup-deadline', 'observer-wait-error'),
    cleanup_errors=[dict(operation=enum('wait', 'signal-group', 'reap', 'inspect-group'), errno=NUM, error=ERROR)],
    residual_processes=[PROCESS], residual_query=QUERY, cleanup_confirmed=BOOL)
RESULT = dict(host_pid=NUM, wait_status=NUM, exit_kind=enum('exited', 'signaled', 'unknown'),
    exit_code=NUM, signal=NUM, timed_out=BOOL, elapsed_seconds=NUM, completed_before_deadline=BOOL,
    helper_exit_status=NUM, reader_processes=NUM, runner_error=ERROR, descendants_at_exit=[PROCESS],
    residual_processes=[PROCESS], pipe_eof=BOOL, business_output=BOOL,
    timeout_kind=enum('business-output-then-timeout', 'no-business-output-timeout'),
    process_group_queries=dict(descendants_at_exit=QUERY, before_cleanup=QUERY, residual_processes=QUERY),
    observer_wait_interruptions=NUM, signal_errors=[dict(target=enum('group', 'leader'), signal=NUM, errno=NUM)],
    samples=[SAMPLE])
HOST_PROCESS = dict(**PROCESS, identity_status=STATUS, descriptor_status=STATUS,
    descriptor_exit_status=NUM, sample_status=STATUS, sample_exit_status=NUM, observer_error=ERROR,
    descriptors=['descriptor'], **TIMING)
OBSERVER = dict(host_pid=NUM, host_pgid=NUM, sample_exit_status=NUM, sample_error=ERROR,
    lldb_exit_status=NUM, lldb_error=ERROR, host_processes=[HOST_PROCESS],
    mode=enum('host-only'),
    sample_status=STATUS, process_tree_status=STATUS, process_tree=[PROCESS], process_tree_error=ERROR,
    process_tree_reason=enum('group-query-platform-unavailable', 'group-process-query-failed',
        'invalid-process-row', 'invalid-process-state'), sample_budget_seconds=NUM,
    non_node_processes_skipped=NUM, host_observation_status=STATUS, **TIMING)
LOCK = dict(address=NUM, owner_pthread=NUM)
OWNER = dict(guest_pid=NUM, thread_id=NUM)
LIFECYCLE = {key: NUM for key in ('admission_enabled', 'lifecycle_state', 'lifecycle_generation',
    'active_operations', 'paused_fileless_operations', 'open_connections', 'tracking_overflows',
    'sqlite_busy_observations', 'sqlite_error_observations', 'last_sqlite_result')}
LIFECYCLE.update(operations=[dict(id=NUM, started_monotonic_ns=NUM, nesting_depth=NUM, owner=OWNER)],
    connections=[dict(connection_id=NUM, mode=NUM, cached_autocommit=NUM, cached_result=NUM,
        recovery_required=NUM, recovery_result=NUM, started_monotonic_ns=NUM, observed_monotonic_ns=NUM, owner=OWNER)],
    native_flocks=[dict(id=NUM, host_fd=NUM, mode=NUM, started_monotonic_ns=NUM, owner=OWNER)])
WAIT = dict(address=NUM, waiters=NUM, notify_pipe=[NUM], real_fd=NUM, type=NUM, flags=NUM,
    refcount=NUM, pid=NUM, tgid=NUM, blocking=NUM, exiting=NUM, zombie=NUM, lock=LOCK, poll_lock=LOCK)
TASK = {key: NUM for key in ('pid', 'tgid', 'thread', 'threadid', 'blocking', 'exiting', 'zombie',
    'exit_code', 'did_exec', 'last_unblocked_ns', 'waiting_cond', 'waiting_lock', 'task_address', 'cpu_pc')}
TASK.update(futex_pipe=[NUM], general_lock=LOCK, waiting_cond_lock=LOCK, waiting_lock_state=LOCK,
    group=dict(doing_group_exit=NUM, group_exit_code=NUM, last_progress_ns=NUM, leader_pid=NUM, lock=LOCK))
FD = dict(guest_fd=NUM, address=NUM, real_fd=NUM, type=NUM, flags=NUM, refcount=NUM,
    lock=LOCK, poll_lock=LOCK, socket=dict(domain=NUM, type=NUM, protocol=NUM, unix_peer=NUM),
    poll=dict(address=NUM, waiters=NUM, notify_pipe=[NUM], lock=LOCK), tty=dict(address=NUM, lock=LOCK))
STATE = dict(host_pid=NUM, stopped_read_only=BOOL,
    threads=[dict(host_tid=NUM, index=NUM, guest_pid_from_thread_name=NUM,
        frames=[dict(pc=NUM, line=NUM)], wait_objects=[WAIT])], tasks=[TASK], lifecycle=LIFECYCLE,
    locks=[dict(host_tid=NUM, **LOCK)], errors=[ERROR],
    pids_read=dict(address=NUM, bytes=NUM, error_code=NUM, error_type=NUM),
    fd_tables=[dict(address=NUM, guest_pid=NUM, size=NUM, lock=LOCK, truncated=BOOL, fds=[FD])])


def project(value, schema, limited):
    if value is None: return None
    if schema == NUM:
        return value if type(value) in (int, float) and abs(value) <= 2 ** 127 and math.isfinite(value) else OMIT
    if schema == BOOL: return value if type(value) is bool else OMIT
    if isinstance(schema, frozenset): return value if isinstance(value, str) and value in schema else OMIT
    if schema == 'process-state':
        return value if isinstance(value, str) and re.fullmatch(
            r'(?:[RSDTtZXxIWKP][<>NlsL+0-9-]{0,15}|[RUSITH?](?:<|N)?X?E?V?L?s?\+?)', value) else OMIT
    if schema == 'descriptor':
        return value if isinstance(value, str) and (re.fullmatch(r'(?:p\d{1,12}|f(?:\d{1,12}|cwd|txt|rtd)|a[rwu ])', value)
            or value in {'tREG', 'tDIR', 'tCHR', 'tFIFO', 'tIPv4', 'tIPv6', 'tunix', 'tsock', 'tPIPE',
                         'tKQUEUE', 'tPSXSEM', 'tPSXSHM', 'tLINK', 'tunknown'}) else OMIT
    if isinstance(schema, dict) and isinstance(value, dict):
        clean = {key: item for key, child in schema.items() if key in value
                 and (item := project(value[key], child, limited)) is not OMIT}
        # Counts establish whether sanitized frames existed without retaining
        # any free-form function, image, filename or variable text.
        for source_key, count_key in (('sample_frames', 'sanitized_frame_count'), ('frames', 'frame_count')):
            if isinstance(value.get(source_key), list) and (schema is OBSERVER or schema is HOST_PROCESS or 'frames' in schema):
                frames = value[source_key]
                clean[count_key] = len(frames)
                clean['function_frame_count'] = sum(isinstance(row, dict) and isinstance(row.get('function'), str)
                                                     and bool(row['function']) for row in frames)
        return clean
    if isinstance(schema, list) and isinstance(value, list):
        if len(value) > MAX_ROWS: limited[0] = True
        return [clean for item in value[:MAX_ROWS] if (clean := project(item, schema[0], limited)) is not OMIT]
    return OMIT


class ExportBudget:
    def __init__(self): self.bundles, self.bytes = 0, 0


DEFAULT_BUDGET = ExportBudget()


def job_tracking_subroot(root, expected=None):
    """Select one owned wrapper directory; never recursively search for JSON."""
    if expected is not None:
        expected = Path(expected)
        if expected.is_absolute() or '..' in expected.parts or not re.fullmatch(
                r'cilogs-verify/job-tracking\.[A-Za-z0-9]{6}', expected.as_posix()):
            raise ValueError('invalid-job-tracking-source')
    container = root / 'cilogs-verify'
    if container.is_symlink() or not container.is_dir():
        raise ValueError('invalid-job-tracking-source')
    candidates = []
    with os.scandir(container) as entries:
        for index, entry in enumerate(entries):
            if index >= MAX_JOB_TRACKING_ENTRIES:
                raise RuntimeError('job-tracking-source-count-limit')
            if re.fullmatch(r'job-tracking\.[A-Za-z0-9]{6}', entry.name):
                if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                    raise ValueError('invalid-job-tracking-source')
                candidates.append(Path('cilogs-verify') / entry.name)
    if len(candidates) != 1 or (expected is not None and candidates[0] != expected):
        raise ValueError('job-tracking-source-not-unique-or-changed')
    return candidates[0]


def export_case(source_root, destination_root, bash_version, case_id, invocation, budget=None, *, relative_root=None):
    """Export only known JSON roles; return a manifest path, never source paths.

    Per invocation: <=14 sources, 128KiB/source and 1MiB emitted. Per process:
    <=64 invocations and 16MiB. A caller shares ExportBudget across its suite.
    Every invocation directory is exclusive; existing evidence is never replaced.
    """
    if not re.fullmatch(r'\d{1,4}(?:\.\d{1,4}){1,3}|not-applicable', bash_version):
        raise ValueError('invalid-bash-version')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]{0,179}', case_id) or type(invocation) is not int or not 0 < invocation <= MAX_FIXTURES:
        raise ValueError('invalid-case-identity')
    budget = budget if budget is not None else DEFAULT_BUDGET
    if budget.bundles >= MAX_BUNDLES: raise RuntimeError('diagnostic-count-limit')
    # TemporaryDirectory is trusted. macOS commonly places it under the system
    # /var -> /private/var alias; normalize that root without rejecting aliases
    # above it. Only components *inside* this fixture must not be symlinks.
    root = Path(source_root).resolve(strict=True)
    if relative_root is not None:
        # Keep the outer fixture as the trust anchor. Do not resolve a selected
        # child root and accidentally accept an internal symlink as trusted.
        root = root / job_tracking_subroot(root, relative_root)
    roles = [('result', 'result.json', RESULT), ('helper-result', 'guest-diagnostics/wrong-token/result.json', RESULT),
             ('observer', 'observer.json', OBSERVER), ('guest-state', 'guest-state.json', STATE),
             ('sample-observer', 'sample/observer.json', OBSERVER), ('sample-guest-state', 'sample/guest-state.json', STATE)]
    for label in ('initial', '75-seconds'):
        roles.extend([(label + '-observer', 'guest-diagnostics/wrong-token/' + label + '/observer.json', OBSERVER),
                      (label + '-guest-state', 'guest-diagnostics/wrong-token/' + label + '/guest-state.json', STATE),
                      ('host-' + label + '-observer', label + '/observer.json', OBSERVER),
                      ('host-' + label + '-guest-state', label + '/guest-state.json', STATE)])
    records, files = [], {}
    for role, relative, schema in roles:
        source = root / relative
        record = dict(role=role, status='missing')
        records.append(record)
        try:
            # Reject symlinks and non-regular files; bound the actual read as well.
            components = [source]
            parent = source.parent
            while parent != root:
                components.append(parent)
                parent = parent.parent
            if any(component.is_symlink() for component in components):
                record['status'] = 'non-regular'; continue
            if not stat.S_ISREG(source.stat().st_mode): record['status'] = 'non-regular'; continue
            flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
            with os.fdopen(os.open(source, flags), 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode): record['status'] = 'non-regular'; continue
                data = stream.read(MAX_SOURCE_BYTES + 1)
            record['source_bytes'] = len(data)
            if len(data) > MAX_SOURCE_BYTES:
                record['status'] = 'source-byte-limit'; continue
            record['source_sha256'] = hashlib.sha256(data).hexdigest()
            limited = [False]
            clean = project(json.loads(data), schema, limited)
            if not isinstance(clean, dict): record['status'] = 'invalid-shape'; continue
            payload = (json.dumps(clean, indent=2, allow_nan=False) + '\n').encode()
            files[role + '.json'] = payload
            record.update(status='projected', projection_limited=limited[0],
                exported_bytes=len(payload), exported_sha256=hashlib.sha256(payload).hexdigest())
        except FileNotFoundError: pass
        except (ValueError, UnicodeError, RecursionError): record['status'] = 'invalid-json'
        except OSError as error: record.update(status='read-error', errno=error.errno)
    manifest = dict(schema=1, bash_version=bash_version, case_id=case_id, invocation=invocation,
        source_layout='job-tracking-wrapper' if relative_root is not None else 'root',
        source_roles=records, excludes=['commands', 'stdin', 'environment', 'output', 'raw-samples', 'symbol-text'])
    files['manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    total = sum(map(len, files.values()))
    if total > MAX_BUNDLE_BYTES or budget.bytes + total > MAX_RUN_BYTES:
        raise RuntimeError('diagnostic-byte-limit')
    destination = Path(destination_root) / ('bash-' + bash_version) / case_id / ('invocation-%02d-' % invocation + uuid.uuid4().hex)
    destination.mkdir(parents=True, exist_ok=False)
    # Account before writes: even a partial failed export consumes the quota.
    budget.bundles += 1
    budget.bytes += total
    for name, payload in files.items():
        with (destination / name).open('xb') as stream: stream.write(payload)
    return destination / 'manifest.json'


class DiagnosticCaseMixin:
    """Use temporary_directory() for fixtures to retain post-return failures.

    Set diagnostics_root, diagnostics_bash_version and shared diagnostics_budget
    on the concrete unittest class. No original exception text is exported.
    """
    diagnostics_root = Path('cilogs-verify/helper-failures')
    diagnostics_bash_version = 'not-applicable'
    diagnostics_budget = DEFAULT_BUDGET

    def setUp(self):
        super().setUp()
        self._diagnostic_fixtures = []
        self._diagnostic_subroots = {}
        self.addCleanup(self._finish_diagnostics)

    @contextmanager
    def temporary_directory(self, **kwargs):
        if len(self._diagnostic_fixtures) >= MAX_FIXTURES: raise RuntimeError('fixture-count-limit')
        fixture = tempfile.TemporaryDirectory(**kwargs)
        self._diagnostic_fixtures.append(fixture)
        yield fixture.name

    def retain_job_tracking_diagnostics(self, fixture_root):
        """Register the wrapper's one fixed-layout source before assertions."""
        fixture = next((item for item in self._diagnostic_fixtures
                        if Path(item.name) == Path(fixture_root)), None)
        if fixture is None or fixture.name in self._diagnostic_subroots:
            raise ValueError('unowned-or-already-registered-diagnostic-fixture')
        relative = job_tracking_subroot(Path(fixture.name).resolve(strict=True))
        self._diagnostic_subroots[fixture.name] = relative

    def _finish_diagnostics(self):
        result = self._outcome.result
        failed = any(test is self or getattr(test, 'test_case', None) is self
                     for test, _ in result.failures + result.errors)
        export_errors = []
        try:
            if failed:
                for invocation, fixture in enumerate(self._diagnostic_fixtures, 1):
                    try:
                        export_case(fixture.name, self.diagnostics_root, self.diagnostics_bash_version,
                            self.__class__.__name__ + '.' + self._testMethodName, invocation, self.diagnostics_budget,
                            relative_root=self._diagnostic_subroots.get(fixture.name))
                    except Exception:
                        # Do not copy arbitrary exception messages/paths or replace
                        # the failure already recorded by unittest.
                        export_errors.append(invocation)
        finally:
            for fixture in self._diagnostic_fixtures:
                try: fixture.cleanup()
                except Exception: export_errors.append('cleanup')
        if export_errors: raise RuntimeError('failed-test-diagnostic-export-failed')
