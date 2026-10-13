#!/usr/bin/env python3
"""Regression checks for the transport gate; output alone never proves success."""
import copy
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('web_checker', Path(__file__).with_name('check-web-fetch-guest.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = dict(phase='web-fetch-native', host_pid=123, timed_out=False, exit_kind='exited', wait_status=0,
    exit_code=0, helper_exit_status=0, reader_processes=0, signal=None, signal_errors=[],
    completed_before_deadline=True, runner_error=None, pipe_eof=True,
    descendants_at_exit=[], residual_processes=[], elapsed_seconds=3.0)
names = [f'fixture {index}' for index in range(32)] + [
    'ARM original packaged provider reproduces incompatible parser failure',
    'ARM complete patched package reads HTTPS and same-origin redirect',
    'ARM complete package rejects private destination without fixture resolver',
    'ARM complete package obeys installed proxy policy without origin DNS',
]
output = '\n'.join('PASS ' + name for name in names) + '\nweb fetch transport: 36/36 passed; real sockets/TLS; policy dependency adapters; 100 close cycles\nWEB_FETCH_ARM_GUEST_COMPLETED=1\n'
module.check(result, output)
count = 1
for key, value in [
    ('timed_out', True), ('exit_kind', 'signaled'), ('wait_status', 14), ('exit_code', 1),
    ('helper_exit_status', 142), ('reader_processes', 1), ('completed_before_deadline', False),
    ('pipe_eof', False), ('residual_processes', [123]), ('descendants_at_exit', [234]),
    ('elapsed_seconds', 90.1), ('runner_error', 'fixture'), ('signal_errors', ['fixture']),
]:
    bad = copy.deepcopy(result); bad[key] = value
    try: module.check(bad, output)
    except AssertionError: count += 1
    else: raise AssertionError(f'gate accepted invalid execution evidence: {key}')
for text in [output + 'AssertionError: failed\n', output.replace('PASS fixture 1\n', ''),
             output.replace('WEB_FETCH_ARM_GUEST_COMPLETED=1', ''), output + 'PASS fixture 0\n']:
    try: module.check(result, text)
    except AssertionError: count += 1
    else: raise AssertionError('gate accepted incomplete or failing output')
print(f'web fetch guest checker: {count}/{count} passed')
