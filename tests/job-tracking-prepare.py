#!/usr/bin/env python3
"""Pin the bridge patch and prepare local fixtures from the existing image only."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/JobTracking.bundle'
TARGET = '/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js'
ACTIVITY = '''function installActivityReporter(ctx) {
  const pending = [];
  let timer = null, flushing = false;
  const flush = async () => {
    timer = null;
    if (flushing || !pending.length) return;
    flushing = true;
    const batch = pending.splice(0, 50);
    try { await call('/v1/activity', { method: 'POST', body: { events: batch } }); } catch {}
    finally { flushing = false; if (pending.length) schedule(); }
  };
  const schedule = () => { if (timer === null) { timer = setTimeout(flush, 400); timer.unref?.(); } };
  installTaskActivity(ctx, event => {
    if (pending.length >= 200) pending.shift();
    pending.push(event); schedule();
  });
  ctx.effect(() => () => { if (timer !== null) clearTimeout(timer); pending.length = 0; });
}

'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tarball', type=Path, default=ROOT / 'build/root.tar.gz')
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--assets-only', action='store_true')
    parser.add_argument('--write-manifest', action='store_true')
    args = parser.parse_args()
    original = None
    with tarfile.open(args.tarball, 'r|gz') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            if name == TARGET.lstrip('/'):
                assert original is None and member.isfile()
                original = archive.extractfile(member).read()
            if args.fixtures and not args.assets_only and name.startswith('usr/local/lib/node_modules/') and member.isfile() and name.endswith(('.js', '.mjs', '.cjs', '.json', '.yml')):
                path = PurePosixPath(name.removeprefix('usr/local/lib/'))
                assert '..' not in path.parts
                destination = args.fixtures.joinpath(*path.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.extractfile(member).read())
    assert original is not None
    text = original.decode('utf-8')
    start = text.index('function installActivityReporter(ctx) {')
    end = text.index('export function apply(ctx)', start)
    replacements = [
        {'find': 'import { defineTool } from "@deepseek-ai/dsh-tools";', 'replace': 'import { defineTool } from "@deepseek-ai/dsh-tools";\nimport {installJobTracking,installTaskActivity} from "./job-tracking.mjs";', 'count': 1},
        {'find': 'export const inject = ["tools"];', 'replace': 'export const inject = ["tools", "jobs"];', 'count': 1},
        {'find': text[start:end], 'replace': ACTIVITY, 'count': 1},
        {'find': '  installActivityReporter(ctx);', 'replace': '  installJobTracking(ctx, defineTool);\n  installActivityReporter(ctx);', 'count': 1},
    ]
    patched = text
    for replacement in replacements:
        assert patched.count(replacement['find']) == replacement['count']
        patched = patched.replace(replacement['find'], replacement['replace'])
    sha = lambda data: hashlib.sha256(data).hexdigest()
    resources = ('development-tools.mjs', 'job-tracking.mjs', 'job-ledger.mjs')
    manifest = {'schema': 1, 'files': [{'source': name, 'target': TARGET.rsplit('/', 1)[0] + '/' + name,
        'sha256': sha((BUNDLE / name).read_bytes()),
        **({'previous_sha256': ['e4c9c3061680436bd042dd322615d3c9f9e13704c2b728fbf68407b7edd034e1']} if name == 'job-tracking.mjs' else {})} for name in resources],
        'patches': [{'target': TARGET, 'original_sha256': sha(original), 'patched_sha256': sha(patched.encode()),
                     'replacements': replacements}]}
    encoded = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
    if args.write_manifest:
        (BUNDLE / 'manifest.json').write_text(encoded, encoding='utf-8')
    else:
        assert (BUNDLE / 'manifest.json').read_text(encoding='utf-8') == encoded, 'stale job tracking manifest'
    if args.fixtures:
        args.fixtures.mkdir(parents=True, exist_ok=True)
        (args.fixtures / 'bridge-patched.mjs').write_text(patched, encoding='utf-8')
        for name in resources:
            (args.fixtures / name).write_bytes((BUNDLE / name).read_bytes())
    print('JOB_TRACKING_PINNED_AND_PREPARED')

if __name__ == '__main__':
    main()
