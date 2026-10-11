"""LLDB command: stopped-process reads only. No expression evaluation/calls."""
import json
import os
from pathlib import Path
import re
import lldb


def child(value, name):
    return value.GetChildMemberWithName(name)


def number(value, signed=False):
    if not value.IsValid() or value.GetError().Fail(): return None
    return value.GetValueAsSigned() if signed else value.GetValueAsUnsigned()


def fields(value, names):
    return {name: number(child(value, name), name in ('real_fd', 'host_fd', 'cached_result',
             'cached_autocommit', 'recovery_result', 'pid', 'tgid')) for name in names.split()}


def address(value):
    return value.GetLoadAddress() if value.IsValid() else None


def lock(value):
    return dict(address=address(value), owner_pthread=number(child(value, 'owner')))


def global_value(target, name):
    values = target.FindGlobalVariables(name, 20)
    for value in values:
        if value.GetName() == name and value.IsValid(): return value
    return target.FindFirstGlobalVariable(name)


def numeric_array(value):
    return [number(value.GetChildAtIndex(i), True) for i in range(value.GetNumChildren())]


def snapshot(debugger, command, execution_context, command_result, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    result = dict(host_pid=process.GetProcessID(), stopped_read_only=True, threads=[], tasks=[],
                  lifecycle={}, locks=[], errors=[])
    try:
        for thread in process:
            name = thread.GetName() or ''
            guest_pid = re.search(r'-(\d+)$', name)
            row = dict(host_tid=thread.GetThreadID(), index=thread.GetIndexID(), frames=[],
                       guest_pid_from_thread_name=int(guest_pid[1]) if guest_pid else None)
            for frame in thread:
                entry = frame.GetLineEntry()
                function = frame.GetFunctionName() or '<unknown>'
                # Symbol names are code, never print frame arguments or summaries.
                row['frames'].append(dict(function=function, pc=frame.GetPC(),
                    file=entry.GetFileSpec().GetFilename(), line=entry.GetLine()))
                for value in frame.GetVariables(True, True, False, True):
                    typename = value.GetType().GetName() or ''
                    if typename in ('lock_t *', 'struct lock *') and number(value):
                        result['locks'].append(dict(host_tid=thread.GetThreadID(), frame=function,
                            variable=value.GetName(), **lock(value.Dereference())))
                    if typename in ('struct poll *', 'struct fd *', 'struct task *', 'struct tty *') and number(value):
                        obj = value.Dereference()
                        detail = dict(variable=value.GetName(), type=typename, address=number(value))
                        if typename == 'struct poll *':
                            detail.update(fields(obj, 'waiters'))
                            detail['notify_pipe'] = numeric_array(child(obj, 'notify_pipe'))
                            detail['lock'] = lock(child(obj, 'lock'))
                        elif typename == 'struct fd *':
                            detail.update(fields(obj, 'real_fd type flags refcount'))
                            detail['lock'] = lock(child(obj, 'lock'))
                            detail['poll_lock'] = lock(child(obj, 'poll_lock'))
                        elif typename == 'struct task *':
                            detail.update(fields(obj, 'pid tgid blocking exiting zombie'))
                        else:
                            detail['lock'] = lock(child(obj, 'lock'))
                        row.setdefault('wait_objects', []).append(detail)
            result['threads'].append(row)

        # Bulk-read pointer slots rather than 32768 individual debugger requests.
        pids = global_value(target, 'pids')
        element_type = pids.GetType().GetArrayElementType()
        stride = element_type.GetByteSize()
        offset = next((element_type.GetFieldAtIndex(i).GetOffsetInBytes()
                       for i in range(element_type.GetNumberOfFields())
                       if element_type.GetFieldAtIndex(i).GetName() == 'task'), None)
        if stride and offset is not None:
            error = lldb.SBError()
            memory = process.ReadMemory(address(pids), pids.GetType().GetByteSize(), error)
            result['pids_read'] = dict(address=address(pids), bytes=pids.GetType().GetByteSize(),
                                       error_code=error.GetError(), error_type=error.GetType())
            if error.Fail(): result['errors'].append('pids-read-failed')
            else:
                pointer_size = target.GetAddressByteSize()
                byteorder = 'little' if target.GetByteOrder() == lldb.eByteOrderLittle else 'big'
                for i in range(len(memory) // stride):
                    slot = i * stride + offset
                    if not int.from_bytes(memory[slot:slot + pointer_size], byteorder): continue
                    record = pids.GetChildAtIndex(i)
                    task = child(record, 'task').Dereference()
                    row = fields(task, 'pid tgid thread threadid blocking exiting zombie exit_code did_exec last_unblocked_ns waiting_cond waiting_lock')
                    row['task_address'] = address(task)
                    row['cpu_pc'] = number(child(child(task, 'cpu'), 'pc'))
                    row['futex_pipe'] = numeric_array(child(task, 'futex_pipe'))
                    row['general_lock'] = lock(child(task, 'general_lock'))
                    row['waiting_cond_lock'] = lock(child(task, 'waiting_cond_lock'))
                    waiting = child(task, 'waiting_lock')
                    if number(waiting): row['waiting_lock_state'] = lock(waiting.Dereference())
                    group = child(task, 'group').Dereference()
                    row['group'] = fields(group, 'doing_group_exit group_exit_code last_progress_ns')
                    row['group']['lock'] = lock(child(group, 'lock'))
                    row['group']['leader_pid'] = number(child(child(group, 'leader').Dereference(), 'pid'), True)
                    result['tasks'].append(row)
        else: result['errors'].append('pids-debug-type-unavailable')

        # Read descriptor metadata only, never buffers, socket addresses, paths,
        # tty input, guest argv or credentials. Shared tables are sampled once.
        tables = set()
        result['fd_tables'] = []
        for row in result['tasks']:
            task_type = target.FindFirstType('struct task')
            task = target.CreateValueFromAddress('sample_task', lldb.SBAddress(row['task_address'], target), task_type)
            table_ptr = child(task, 'files')
            if not number(table_ptr) or number(table_ptr) in tables: continue
            tables.add(number(table_ptr))
            table = table_ptr.Dereference()
            size = number(child(table, 'size')) or 0
            description = dict(address=number(table_ptr), guest_pid=row['pid'], size=size,
                               lock=lock(child(table, 'lock')), fds=[])
            pointers = child(table, 'files')
            if size > 4096:
                description['truncated'] = True
                size = 4096
            for index in range(size):
                ptr = pointers.GetChildAtIndex(index, lldb.eNoDynamicValues, True)
                if not number(ptr): continue
                fd = ptr.Dereference()
                item = dict(guest_fd=index, address=number(ptr), **fields(fd, 'real_fd type flags refcount'))
                item['lock'] = lock(child(fd, 'lock'))
                item['poll_lock'] = lock(child(fd, 'poll_lock'))
                ops = number(child(fd, 'ops'))
                item['ops'] = target.ResolveLoadAddress(ops or 0).GetSymbol().GetName()
                if item['ops'] and 'socket' in item['ops']:
                    item['socket'] = fields(child(fd, 'socket'), 'domain type protocol unix_peer')
                elif item['ops'] and 'epoll' in item['ops']:
                    poll = child(child(fd, 'epollfd'), 'poll')
                    if number(poll):
                        obj = poll.Dereference()
                        item['poll'] = dict(address=number(poll), **fields(obj, 'waiters'),
                                            notify_pipe=numeric_array(child(obj, 'notify_pipe')),
                                            lock=lock(child(obj, 'lock')))
                elif item['ops'] and 'tty' in item['ops']:
                    tty = child(fd, 'tty')
                    if number(tty):
                        item['tty'] = dict(address=number(tty), lock=lock(child(tty.Dereference(), 'lock')))
                description['fds'].append(item)
            result['fd_tables'].append(description)

        for name in ('admission_enabled', 'lifecycle_state', 'lifecycle_generation', 'active_operations',
                     'paused_fileless_operations', 'open_connections', 'tracking_overflows',
                     'sqlite_busy_observations', 'sqlite_error_observations', 'last_sqlite_result'):
            result['lifecycle'][name] = number(global_value(target, name))
        for name, active, selected in (
            ('operations', 'used', 'id started_monotonic_ns nesting_depth'),
            ('connections', 'used', 'connection_id mode cached_autocommit cached_result recovery_required recovery_result started_monotonic_ns observed_monotonic_ns'),
            ('native_flocks', 'key', 'id host_fd mode started_monotonic_ns')):
            array = global_value(target, name)
            rows = []
            for i in range(array.GetNumChildren()):
                item = array.GetChildAtIndex(i)
                if not number(child(item, active)): continue
                value = child(item, 'value')
                row = fields(value, selected)
                row['owner'] = fields(child(value, 'owner'), 'guest_pid thread_id')
                rows.append(row)
            result['lifecycle'][name] = rows
        for name in ('pids_lock', 'futex_lock', 'peer_lock'):
            value = global_value(target, name)
            if value.IsValid(): result['locks'].append(dict(global_name=name, **lock(value)))
    except Exception as error:
        result['errors'].append(type(error).__name__)
    finally:
        Path(os.environ['DSH_LLDB_SNAPSHOT']).write_text(json.dumps(result, indent=2) + '\n')
        # No calls into the inferior and no mutex acquisition. Resume promptly.
        if process.IsValid(): process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add -f guest_snapshot.snapshot dsh-guest-snapshot')
