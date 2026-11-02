#!/usr/bin/env python3
"""Pin client declaration and Bot resources against the original bridge manifest."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/JobTracking.bundle'
PREFIX = '/usr/local/lib/dsh-plugins/dsh-host-bridge/'


def manifest():
    original = (ROOT / 'rootfs/overlay' / PREFIX.lstrip('/') / 'package.json').read_text(encoding='utf-8')
    find = '"main": "index.js"'
    replacement = '''"main": "index.js",
  "exports": { ".": "./index.js", "./client": "./multi-bot-client.js" },
  "dsh": { "client": { "platform": "web", "inject": [
    "@deepseek-ai/dsh-client-ui-sidebar", "@deepseek-ai/dsh-client-ui-workspace",
    "@deepseek-ai/dsh-client-ui-session"
  ], "external": ["react"] } }'''
    assert original.count(find) == 1
    patched = original.replace(find, replacement)
    json.loads(patched)
    sha = lambda value: hashlib.sha256(value).hexdigest()
    return {'schema': 1, 'files': [
        {'source': name, 'target': PREFIX + name, 'sha256': sha((BUNDLE / name).read_bytes())}
        for name in ('multi-bot-store.mjs', 'multi-bot.mjs', 'multi-bot-client.js')
    ], 'patches': [{'target': PREFIX + 'package.json', 'original_sha256': sha(original.encode()),
                   'patched_sha256': sha(patched.encode()), 'replacements': [{'find': find, 'replace': replacement, 'count': 1}]}]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--write-manifest', action='store_true')
    args = parser.parse_args()
    encoded = json.dumps(manifest(), ensure_ascii=False, indent=2) + '\n'
    path = BUNDLE / 'multi-bot-manifest.json'
    if args.write_manifest:
        path.write_bytes(encoded.encode())
    else:
        assert path.read_text(encoding='utf-8') == encoded, 'stale multi-bot manifest'
    print('MULTI_BOT_MANIFEST_VERIFIED')
