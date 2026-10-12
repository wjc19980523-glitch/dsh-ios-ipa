#!/usr/bin/env python3
"""Read the pinned package or emit a guest-side installer for test clones.

Never changes root.tar.gz, its digest, or fakefs data from the host OS.
All guest filesystem changes go through Node inside the actual guest.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/SessionLifecycle.bundle'
INSTALLER = r'''
import {createHash,randomBytes} from 'node:crypto';
import {lstat,mkdir,open,readFile,rename} from 'node:fs/promises';
import {dirname} from 'node:path';
const payload=JSON.parse(Buffer.from('__PAYLOAD__','base64').toString('utf8'));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const changes=[];
for(const file of payload.manifest.files){
 const bytes=Buffer.from(payload.files[file.source],'base64');
 if(sha(bytes)!==file.sha256)throw new Error('resource digest mismatch');
 let current;
 try{const stat=await lstat(file.target);if(!stat.isFile()||stat.nlink!==1)throw new Error('unsafe system resource');current=await readFile(file.target);}
 catch(error){if(error.code!=='ENOENT')throw error;}
 if(current&&sha(current)!==file.sha256)throw new Error('unknown system resource');
 if(!current)changes.push({target:file.target,bytes,mode:0o644});
}
for(const patch of payload.manifest.patches){
 const stat=await lstat(patch.target);if(!stat.isFile()||stat.nlink!==1)throw new Error('unsafe system package');
 const current=await readFile(patch.target);
 if(sha(current)===patch.patched_sha256)continue;
 if(sha(current)!==patch.original_sha256)throw new Error('unknown system package');
 let text=current.toString('utf8');
 for(const replacement of patch.replacements){
  if(text.split(replacement.find).length-1!==replacement.count)throw new Error('replacement count mismatch');
  text=text.split(replacement.find).join(replacement.replace);
 }
 const bytes=Buffer.from(text,'utf8');if(sha(bytes)!==patch.patched_sha256)throw new Error('patched digest mismatch');
 changes.push({target:patch.target,bytes,mode:stat.mode&0o777});
}
if(payload.guest_test)changes.push({target:'/tmp/dsh-session-lease-test.mjs',bytes:Buffer.from(payload.guest_test,'base64'),mode:0o644});
// Preflight above finishes before the first write. Resources are installed
// before the package's import becomes visible, using normal guest file APIs.
for(const change of changes){
 await mkdir(dirname(change.target),{recursive:true});
 const temporary=change.target+'.session-lease-test-'+randomBytes(6).toString('hex');
 const file=await open(temporary,'wx',change.mode);
 try{await file.writeFile(change.bytes);await file.sync();}finally{await file.close();}
 await rename(temporary,change.target);
 if(sha(await readFile(change.target))!==sha(change.bytes))throw new Error('installed digest mismatch');
}
console.log('SESSION_LEASE_PATCH_INSTALLED');
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--include-guest-test', action='store_true')
    parser.add_argument('--tarball', type=Path)
    parser.add_argument('--extract-original', type=Path)
    options = parser.parse_args()
    manifest = json.loads((BUNDLE / 'manifest.json').read_text(encoding='utf-8'))
    assert manifest['schema'] == 1
    if options.extract_original:
        assert options.tarball and not options.output
        target = PurePosixPath(manifest['patches'][0]['target'].lstrip('/'))
        with tarfile.open(options.tarball, 'r:gz') as archive:
            matches = [member for member in archive if PurePosixPath(member.name) == target]
            assert len(matches) == 1 and matches[0].isfile(), 'missing unique package source'
            data = archive.extractfile(matches[0]).read()
        assert hashlib.sha256(data).hexdigest() == manifest['patches'][0]['original_sha256']
        options.extract_original.parent.mkdir(parents=True, exist_ok=True)
        options.extract_original.write_bytes(data)
        print('SESSION_LEASE_ORIGINAL_SOURCE_VERIFIED')
        return
    assert options.output, 'choose --output FILE or --tarball ... --extract-original ...'
    payload = {'manifest': manifest, 'files': {}}
    for item in manifest['files']:
        name = item['source']
        assert '/' not in name and '\\' not in name
        data = (BUNDLE / name).read_bytes()
        assert hashlib.sha256(data).hexdigest() == item['sha256']
        payload['files'][name] = base64.b64encode(data).decode('ascii')
    if options.include_guest_test:
        payload['guest_test'] = base64.b64encode((ROOT / 'tests/session-lease-guest-test.mjs').read_bytes()).decode('ascii')
    encoded = base64.b64encode(json.dumps(payload, ensure_ascii=False).encode('utf-8')).decode('ascii')
    # The CLI bootstrap accepts a small argv buffer. Deliver the installer as
    # stdin data, never as a shell/Node argument or a new pipe-reading process.
    options.output.write_text(INSTALLER.replace('__PAYLOAD__', encoded), encoding='utf-8')
    print('node --input-type=module -')


if __name__ == '__main__':
    main()
