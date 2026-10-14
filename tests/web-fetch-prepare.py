#!/usr/bin/env python3
"""Prepare real transport tests in a private imported guest; never mutate root.tar.gz."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/WebFetchTransport.bundle'


def replace_once(source, anchor, replacement):
    count = source.count(anchor)
    assert count == 1, f'web test installer template anchor must occur once, got {count}'
    return source.replace(anchor, replacement)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tarball', type=Path)
    parser.add_argument('--extract-fixtures', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    manifest = json.loads((BUNDLE / 'manifest.json').read_text(encoding='utf-8'))
    if args.extract_fixtures:
        assert args.tarball and not args.output
        wanted = {
            manifest['patches'][0]['target'].lstrip('/'): 'web-provider.js',
            'usr/local/lib/node_modules/ipaddr.js/lib/ipaddr.js': 'ipaddr.cjs',
        }
        found = {}
        with tarfile.open(args.tarball, 'r:gz') as archive:
            for member in archive:
                name = str(PurePosixPath(member.name))
                if name in wanted:
                    assert member.isfile() and name not in found
                    found[name] = archive.extractfile(member).read()
        assert set(found) == set(wanted)
        args.extract_fixtures.mkdir(parents=True, exist_ok=True)
        for name, output in wanted.items():
            (args.extract_fixtures / output).write_bytes(found[name])
        assert hashlib.sha256(found[manifest['patches'][0]['target'].lstrip('/')]).hexdigest() == manifest['patches'][0]['original_sha256']
        print('WEB_FETCH_ORIGINAL_FIXTURES_VERIFIED')
        return
    assert args.output and not args.tarball
    spec = importlib.util.spec_from_file_location('session_prepare', ROOT / 'tests/session-lease-prepare.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    installer = replace_once(module.INSTALLER,
        "if(payload.guest_test)changes.push({target:'/tmp/dsh-session-lease-test.mjs',bytes:Buffer.from(payload.guest_test,'base64'),mode:0o644});",
        "for(const fixture of payload.fixtures)changes.push({target:fixture.target,bytes:Buffer.from(fixture.base64,'base64'),mode:0o644});")
    installer = replace_once(installer, "console.log('SESSION_LEASE_PATCH_INSTALLED');", "console.log('WEB_FETCH_PATCH_INSTALLED');")
    # Save the byte-verified original in its own package directory only in this
    # private test root, so its real dependency resolution remains unchanged.
    installer = replace_once(installer, "const current=await readFile(patch.target);", "const current=await readFile(patch.target);\n"
        "if(sha(current)===patch.original_sha256){changes.push({target:patch.target.replace(/index\\.js$/, 'dsh-original-test.js'),bytes:current,mode:0o644});"
        "changes.push({target:'/tmp/dsh-web-test/original-web-provider.js',bytes:current,mode:0o644});}")
    payload = {'manifest': manifest, 'files': {}, 'fixtures': []}
    for item in manifest['files']:
        data = (BUNDLE / item['source']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == item['sha256']
        payload['files'][item['source']] = base64.b64encode(data).decode()
    fixtures = {
        ROOT / 'tests/web-fetch-transport-test.mjs': '/tmp/dsh-web-test/tests/web-fetch-transport-test.mjs',
        ROOT / 'tests/fixtures/web-transport/test-key.pem': '/tmp/dsh-web-test/tests/fixtures/web-transport/test-key.pem',
        ROOT / 'tests/fixtures/web-transport/test-cert.pem': '/tmp/dsh-web-test/tests/fixtures/web-transport/test-cert.pem',
        BUNDLE / 'manifest.json': '/tmp/dsh-web-test/app/WebFetchTransport.bundle/manifest.json',
        BUNDLE / 'web-fetch-transport.mjs': '/tmp/dsh-web-test/app/WebFetchTransport.bundle/web-fetch-transport.mjs',
    }
    for source, target in fixtures.items():
        payload['fixtures'].append({'target': target, 'base64': base64.b64encode(source.read_bytes()).decode()})
    encoded = base64.b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode()
    args.output.write_text(replace_once(installer, '__PAYLOAD__', encoded), encoding='utf-8', newline='\n')
    print('node --expose-internals --input-type=module')


if __name__ == '__main__':
    main()
