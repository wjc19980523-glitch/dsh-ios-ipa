#!/usr/bin/env python3
"""Execute the generated web installer against real, private host fixture files.

This checks test-infrastructure installation, not ARM/native transport behavior.
Only the generated payload's targets are mapped into an owned temp directory.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('web_prepare', ROOT / 'tests/web-fetch-prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--original', required=True, type=Path)
    parser.add_argument('--node', default='node')
    args = parser.parse_args()
    passed = 0
    assert prepare.replace_once('prefix anchor suffix', 'anchor', 'new') == 'prefix new suffix'
    passed += 1
    for broken in ['no such match', 'anchor anchor']:
        try:
            prepare.replace_once(broken, 'anchor', 'new')
        except AssertionError:
            passed += 1
        else:
            raise AssertionError('test installer accepted a missing or duplicate template anchor')
    with tempfile.TemporaryDirectory(prefix='dsh-web-install-selftest-') as temporary:
        directory = Path(temporary)
        script_path = directory / 'installer.mjs'
        completed = subprocess.run([sys.executable, str(ROOT / 'tests/web-fetch-prepare.py'),
            '--output', str(script_path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert completed.returncode == 0, completed.stdout
        script = script_path.read_text(encoding='utf-8')
        match = re.search(r"const payload=JSON.parse\(Buffer.from\('([A-Za-z0-9+/=]+)','base64'\)", script)
        assert match, 'missing unique encoded installer payload'
        payload = json.loads(base64.b64decode(match[1]))
        expected_fixtures = {
            '/tmp/dsh-web-test/tests/web-fetch-transport-test.mjs',
            '/tmp/dsh-web-test/tests/fixtures/web-transport/test-key.pem',
            '/tmp/dsh-web-test/tests/fixtures/web-transport/test-cert.pem',
            '/tmp/dsh-web-test/app/WebFetchTransport.bundle/manifest.json',
            '/tmp/dsh-web-test/app/WebFetchTransport.bundle/web-fetch-transport.mjs',
        }
        assert {item['target'] for item in payload['fixtures']} == expected_fixtures
        assert len(payload['fixtures']) == 5
        assert script.count('for(const fixture of payload.fixtures)') == 1
        assert "target:'/tmp/dsh-session-lease-test.mjs'" not in script
        assert 'guest_test_target' not in script
        passed += 1
        # The session generator keeps the original guest target and a separate
        # prepared target; neither may silently break the web adapter's anchor.
        session_spec = importlib.util.spec_from_file_location('session_prepare', ROOT / 'tests/session-lease-prepare.py')
        session = importlib.util.module_from_spec(session_spec)
        session_spec.loader.exec_module(session)
        assert session.INSTALLER.count("if(payload.guest_test)changes.push({target:'/tmp/dsh-session-lease-test.mjs'") == 1
        assert session.INSTALLER.count("target:'/tmp/dsh-session-prepared-test.mjs'") == 1
        passed += 1
        original = args.original.read_bytes()
        assert hashlib.sha256(original).hexdigest() == payload['manifest']['patches'][0]['original_sha256']
        install_root = directory / 'private-root'
        mapped = lambda target: install_root.joinpath(*PurePosixPath(target).parts[1:]).as_posix()
        expected = {}
        for item in payload['manifest']['files']:
            item['target'] = mapped(item['target'])
            expected[item['target']] = base64.b64decode(payload['files'][item['source']])
        for item in payload['fixtures']:
            item['target'] = mapped(item['target'])
            expected[item['target']] = base64.b64decode(item['base64'])
        for patch in payload['manifest']['patches']:
            patch['target'] = mapped(patch['target'])
            package = Path(patch['target'])
            package.parent.mkdir(parents=True)
            package.write_bytes(original)
            expected[package.with_name('dsh-original-test.js').as_posix()] = original
        source_copy = mapped('/tmp/dsh-web-test/original-web-provider.js')
        expected[source_copy] = original
        encoded = base64.b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode()
        script = prepare.replace_once(script, match[1], encoded)
        script = prepare.replace_once(script, "target:'/tmp/dsh-web-test/original-web-provider.js'", 'target:' + json.dumps(source_copy))
        completed = subprocess.run([args.node, '--input-type=module', '-'], input=script,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert completed.returncode == 0, completed.stdout
        assert completed.stdout.splitlines().count('WEB_FETCH_PATCH_INSTALLED') == 1
        passed += 1
        for target, data in expected.items():
            assert Path(target).read_bytes() == data, 'generated installer omitted or changed a fixture'
        for patch in payload['manifest']['patches']:
            assert hashlib.sha256(Path(patch['target']).read_bytes()).hexdigest() == patch['patched_sha256']
        assert len(expected) == 8
        passed += 1
        # A second execution must preserve the already-patched module, yet still
        # install all test fixtures and finish normally.
        for fixture in payload['fixtures']:
            Path(fixture['target']).unlink()
        completed = subprocess.run([args.node, '--input-type=module', '-'], input=script,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert completed.returncode == 0, completed.stdout
        for fixture in payload['fixtures']:
            assert Path(fixture['target']).read_bytes() == expected[fixture['target']]
        passed += 1
    print(f'web fetch installer selftest: {passed}/{passed} passed; real private host files; ARM execution not claimed')


if __name__ == '__main__':
    main()
