#!/usr/bin/env python3
"""Execute generated installers against mapped, real private host files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/SessionLifecycle.bundle'
OPTIONS = argparse.ArgumentParser(add_help=False)
OPTIONS.add_argument('--node', default='node')
ARGS, REST = OPTIONS.parse_known_args()
sys.argv = [sys.argv[0]] + REST

FS_IMPORT = "import {lstat,mkdir,open,readFile,rename} from 'node:fs/promises';"
MAPPED_FS = r'''
import {lstat as hostLstat,mkdir as hostMkdir,open as hostOpen,readFile as hostReadFile,rename as hostRename} from 'node:fs/promises';
import {join as hostJoin} from 'node:path';
const fixtureRoot=process.env.DSH_INSTALLER_TEST_ROOT;
if(!fixtureRoot)throw new Error('test-owned mapping root required');
const mapped=target=>{
 if(typeof target!=='string'||!target.startsWith('/')||target.split('/').includes('..'))throw new Error('invalid test target');
 return hostJoin(fixtureRoot,...target.split('/').filter(Boolean));
};
const lstat=(target,...args)=>hostLstat(mapped(target),...args);
const mkdir=(target,...args)=>hostMkdir(mapped(target),...args);
const open=(target,...args)=>hostOpen(mapped(target),...args);
const readFile=(target,...args)=>hostReadFile(mapped(target),...args);
const rename=(source,target,...args)=>hostRename(mapped(source),mapped(target),...args);
'''


class Installers(unittest.TestCase):
    def execute(self, mode):
        manifest = json.loads((BUNDLE / 'manifest.json').read_text(encoding='utf-8'))
        patch = manifest['patches'][0]
        original = (BUNDLE / patch['original_source']['source']).read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), patch['original_sha256'])
        with tempfile.TemporaryDirectory(prefix='dsh-installer-real-host-') as temporary:
            owned = Path(temporary)
            mapped_root = owned / 'mapped'
            destination = mapped_root / patch['target'].lstrip('/')
            destination.parent.mkdir(parents=True)
            destination.write_bytes(original)
            generated = owned / 'installer.mjs'
            command = [sys.executable, str(ROOT / 'tests/session-lease-prepare.py'), '--output', str(generated)]
            if mode == 'native':
                command.append('--include-guest-test')
            elif mode == 'prepared':
                command.append('--include-prepared-test')
            build = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stderr)
            source = generated.read_text(encoding='utf-8')
            self.assertEqual(source.count(FS_IMPORT), 1)
            generated.write_text(source.replace(FS_IMPORT, MAPPED_FS), encoding='utf-8')
            environment = os.environ.copy()
            environment['DSH_INSTALLER_TEST_ROOT'] = str(mapped_root)
            executed = subprocess.run([ARGS.node, str(generated)], cwd=ROOT, env=environment,
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(executed.returncode, 0, executed.stderr)
            self.assertEqual(executed.stdout.strip(), 'SESSION_LEASE_PATCH_INSTALLED')
            self.assertEqual(hashlib.sha256(destination.read_bytes()).hexdigest(), patch['patched_sha256'])
            for resource in manifest['files']:
                actual = mapped_root / resource['target'].lstrip('/')
                self.assertEqual(hashlib.sha256(actual.read_bytes()).hexdigest(), resource['sha256'])
            native = mapped_root / 'tmp/dsh-session-lease-test.mjs'
            prepared = mapped_root / 'tmp/dsh-session-prepared-test.mjs'
            self.assertEqual(native.exists(), mode == 'native')
            self.assertEqual(prepared.exists(), mode == 'prepared')
            if native.exists():
                self.assertEqual(native.read_bytes(), (ROOT / 'tests/session-lease-guest-test.mjs').read_bytes())
            if prepared.exists():
                self.assertEqual(prepared.read_bytes(), (ROOT / 'tests/session-lease-prepared-guest-test.mjs').read_bytes())
            self.assertFalse((mapped_root / 'undefined').exists())

    def test_original_rootfs_install_has_no_test_payload(self):
        self.execute('original')

    def test_native_guest_payload_is_installed_at_its_fixed_target(self):
        self.execute('native')

    def test_prepared_guest_payload_is_installed_at_its_independent_fixed_target(self):
        self.execute('prepared')


if __name__ == '__main__':
    unittest.main()
