#!/usr/bin/env python3
"""Fail-closed gates for the explicitly scoped Build 31 test candidate."""
import argparse
from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '12e123c4a54260b84de443b1c7b334a7c798bbfa'
REQUIRED = {
    'DSHSessionLifecycleInstallerTests/testActualBuild30TrackingUpgradeChangesOnlyControllerAndPreservesUserData',
    'DSHSessionLifecycleInstallerTests/testActualBuild30TrackingUpgradeRejectsUnknownControllerWithoutWrites',
}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def scope():
    subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], cwd=ROOT, check=True)
    changed = subprocess.check_output(['git', 'diff', '--name-only', BASE, 'HEAD'], cwd=ROOT, text=True).splitlines()
    allowed = {'app/AppDSH.xcconfig', 'scripts/check-workspace-export-app.py',
               'tests/workspace-export-app-test.py', '.github/workflows/build31-hotfix.yml',
               'scripts/check-hotfix31.py', 'scripts/run-hotfix31-native.sh'}
    require(set(changed) <= allowed, 'Hotfix contains changes outside the authorized candidate scope')
    config = (ROOT / 'app/AppDSH.xcconfig').read_text()
    require(re.findall(r'^CURRENT_PROJECT_VERSION = (\d+)$', config, re.M) == ['31'], 'build must be 31')
    return {'base_commit': BASE, 'changed_files': changed,
            'production_render_and_upgrade_resources_unchanged_from_base': True}


def chain(log):
    text = log.read_text()
    counts = {key: re.findall(r'^# ' + key + r'\s+(\d+)\s*$', text, re.M)
              for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped')}
    require(counts == {'tests': ['13'], 'pass': ['13'], 'fail': ['0'], 'cancelled': ['0'], 'skipped': ['0']},
            'P0 wire-chain suite must execute all 13 tests without failures or skips')
    return {'passed': 13, 'failed': 0, 'skipped': 0, 'log_sha256': sha(log)}


def native(bundle):
    database = bundle / 'database.sqlite3'
    require(database.is_file() and not database.is_symlink(), 'missing completed XCTest database')
    require(not any(database.with_name(database.name + suffix).exists() for suffix in ('-wal', '-journal')),
            'XCTest database still has a writer journal')
    before = sha(database)
    with closing(sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        require(db.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'XCTest database integrity failure')
        require(db.execute('SELECT count(*) FROM ExpectedFailures').fetchone()[0] == 0, 'expected XCTest failures are forbidden')
        rows = db.execute('SELECT tc.identifier,tr.result,tr.skipNotice_fk FROM TestCaseRuns tr '
                          'JOIN TestCases tc ON tc.rowid=tr.testCase_fk').fetchall()
        require(len(rows) == db.execute('SELECT count(*) FROM TestCaseRuns').fetchone()[0] == 2,
                'must execute exactly the two upgrade tests')
        require({row[0] for row in rows} == REQUIRED, 'wrong or duplicate upgrade test selectors')
        require(all(row[1] == 'Success' and row[2] is None for row in rows), 'upgrade test failed or skipped')
    require(sha(database) == before, 'XCTest database changed during inspection')
    return {'passed': 2, 'failed': 0, 'skipped': 0, 'selectors': sorted(REQUIRED), 'database_sha256': before}


def ipa(path):
    spec = importlib.util.spec_from_file_location('archive_gate', ROOT / 'scripts/check-workspace-export-app.py')
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    with tempfile.TemporaryDirectory(prefix='dsh-hotfix31-verify-') as temporary:
        destination = Path(temporary)
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [entry.filename for entry in members]
            require(len(names) == len(set(names)) and 0 < len(names) < 20000, 'invalid or duplicate IPA members')
            require(sum(entry.file_size for entry in members) < 1024 * 1024 * 1024, 'oversized IPA')
            for entry in members:
                name = PurePosixPath(entry.filename)
                require(not name.is_absolute() and '..' not in name.parts and '\\' not in entry.filename
                        and name.parts[0] == 'Payload', 'unsafe IPA path')
                require(name.as_posix().rstrip('/') == entry.filename.rstrip('/'), 'noncanonical IPA path')
                mode = entry.external_attr >> 16
                require(not stat.S_ISLNK(mode) and not entry.flag_bits & 1, 'linked or encrypted IPA member')
                require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'special IPA member')
                target = destination.joinpath(*name.parts)
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(entry) as source, target.open('xb') as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)  # reading to EOF also verifies each CRC
            require(sorted(p.name for p in (destination / 'Payload').iterdir()) == ['DSH.app'], 'unexpected payload')
        inspected = gate.inspect(destination / 'Payload/DSH.app', ROOT)
    return {'ipa_sha256': sha(path), 'ipa_bytes': path.stat().st_size, 'zip_members': len(names),
            'all_member_crc_verified': True, 'archive_gate': inspected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('gate', choices=['scope', 'chain', 'native', 'ipa'])
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = {'gate': args.gate, 'accepted': False, 'github_sha': os.environ.get('GITHUB_SHA'),
               'github_run_id': os.environ.get('GITHUB_RUN_ID'), 'github_run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT')}
    try:
        receipt['evidence'] = scope() if args.gate == 'scope' else globals()[args.gate](args.input)
        receipt['accepted'] = True
    except Exception as error:
        receipt['error'] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf-8') as output:
        json.dump(receipt, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(json.dumps(receipt, ensure_ascii=False))
    return 0 if receipt['accepted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
