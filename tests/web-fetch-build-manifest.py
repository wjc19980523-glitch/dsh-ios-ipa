"""Generate the exact version-pinned web-fetch transport patch, without rootfs changes."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'app/WebFetchTransport.bundle'
TARGET = '/usr/local/lib/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js'


def build(source):
    original = source.decode('utf-8')
    changes = []
    patched = original

    def replace(find, replacement):
        nonlocal patched
        assert patched.count(find) == 1, (find[:100], patched.count(find))
        patched = patched.replace(find, replacement)
        changes.append({'find': find, 'replace': replacement, 'count': 1})

    replace('import z from "@deepseek-ai/schemastery";',
            'import { requestPinned as dshRequestPinned, requestVia as dshRequestVia } from "/usr/local/share/dsh/web-fetch-transport.mjs";\n'
            'import z from "@deepseek-ai/schemastery";')
    start = original.index('async function requestPinned(url, addresses, headers, signal) {')
    end = original.index('\n/**', start)
    replace(original[start:end],
            'async function requestPinned(url, addresses, headers, signal) {\n'
            '\treturn dshRequestPinned(url, addresses, headers, signal);\n}')
    start = original.index('async function requestVia(dispatcher, url, headers, signal) {')
    end = original.index('\n/**', start)
    replace(original[start:end],
            'async function requestVia(proxy, url, headers, signal) {\n'
            '\treturn dshRequestVia(proxy, url, headers, signal);\n}')
    replace('''* Fetch through the dispatcher the proxy policy already installed, letting the proxy resolve the
* origin.
*
* No address set is pinned because none exists to pin: the proxy performs the lookup, and a
* connection pinned to a locally resolved address would reach the origin directly and defeat the
* proxy. The dispatcher is the process-wide one, so hops share its connection pool and no caller
* closes it.
*
* @param dispatcher - the route's dispatcher, from `proxyRouteFor`.''', '''* Fetch through the proxy URL selected by the existing installed policy, letting the proxy
* resolve the origin. A request-scoped native HTTP CONNECT tunnel preserves that route on
* jitless Node without invoking Undici's WebAssembly HTTP parser.
*
* No local origin address is pinned: the proxy owns origin resolution. The request disposer
* closes this request's tunnel and agents, never the policy's shared dispatcher.
*
* @param proxy - the route's configured proxy URL, from `proxyRouteFor`.''')
    replace('publicHttpNetwork.requestVia(route.dispatcher, url, headers, signal)',
            'publicHttpNetwork.requestVia(route.proxy, url, headers, signal)')
    resource = (BUNDLE / 'web-fetch-transport.mjs').read_bytes()
    return {
        'schema': 1,
        'name': 'jitless-public-web-fetch-transport-v1',
        'rootfs_sha256': 'd3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0',
        'patches': [{
            'target': TARGET,
            'original_sha256': hashlib.sha256(source).hexdigest(),
            'patched_sha256': hashlib.sha256(patched.encode()).hexdigest(),
            'replacements': changes,
        }],
        'files': [{
            'source': 'web-fetch-transport.mjs',
            'target': '/usr/local/share/dsh/web-fetch-transport.mjs',
            'sha256': hashlib.sha256(resource).hexdigest(),
        }],
    }, patched


if __name__ == '__main__':
    source = Path(sys.argv[1]).read_bytes()
    # Bundled npm files are LF; never normalize an installed guest source before
    # checking its hash. The generator accepts only the pinned shipped revision.
    assert hashlib.sha256(source).hexdigest() == '489fef91b0c11c063029ea7aed27b312817570b9c3177aeaa44983b9a25aedcd', 'unrecognized package source'
    manifest, patched = build(source)
    (BUNDLE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print('web transport manifest generated:', manifest['patches'][0]['patched_sha256'])
