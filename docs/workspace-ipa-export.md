# Workspace export and cloud IPA workflow

Development branch: `feature/workspace-ipa-export`, based on `78e8500`.
The existing signed/unsigned Build 29 handoff is historical, not evidence that
this new feature works on an iPad. Build 30 is reserved for this feature.

## Gate A: workspace to Native Files export

The `file_export_from_workspace` tool takes `path` and an optional `name`.
It never asks the model to read, encode, or emit the file contents. The trusted
Guest module resolves the current session's `header.cwd` beneath DSH_WORKSPACE
(production `/root/workspace`), verifies every path component, refuses symlinks,
hard links, hidden/sensitive files and nonregular objects, and holds an inode-
checked file descriptor. iSH's `O_NOFOLLOW` is not assumed to enforce this: the
lstat/open/fstat identity checks are mandatory before the first read.

The module hashes fixed-size reads and uploads raw bytes to an explicitly
registered binary Host Bridge route. There is no Native access to a Linux path.
The Native source string is consent metadata; it is never an NSURL to read.
The original 8 MiB Base64 tools `file_import` and `file_export` remain available.
Their JSON transport ceiling remains 12 MiB. A pre-existing legacy export bug
that treated an unanswered picker as saved is corrected without changing its API.

Protocol (all requests require the existing per-launch bearer token and the
independent `files.export.workspace` capability):

| Route | Method | Meaning |
| --- | --- | --- |
| `/v1/files/workspace-export/start` | POST JSON | Bind request/scope, source/workspace, name, bytes and SHA256; asynchronously ask consent |
| `/v1/files/workspace-export/chunk` | PUT octet-stream | Append only at the expected offset with the expected chunk SHA256 |
| `/v1/files/workspace-export/status` | GET | Query the actual current state |
| `/v1/files/workspace-export/finish` | POST | Verify whole SHA256, fsync and atomically commit; asynchronously show Files export |
| `/v1/files/workspace-export/cancel` | POST | Cancel this export, preserving the Guest source |

Session IDs are 256-bit random values, sent only in headers, bound to the
trusted session scope. A duplicate start with the same request ID must have
identical metadata; it cannot obtain a second confirmation. A repeated last
chunk with identical offset/size/SHA acknowledges the prior write instead of
writing twice. Other offsets fail closed. No session credentials, GitHub token
or binary data enter bridge activity logs or model output.

Limits: 512 MiB per file; 128 KiB per binary request; one active export;
32 MiB Native disk reserve; five minutes without transfer progress; thirty
minutes total; sixteen bounded Native result records; bounded private Guest
checkpoints. These limits do not enlarge the old JSON interface. Initial hash
and transfer keep memory bounded; the Native hash covers the exact received
bytes. Size and fd metadata are checked again before finalization.

States are `pending_confirmation`, `receiving`, `ready`, `saving`, `saved`,
`cancelled`, `expired`, and `failed`. Only the real document-picker delegate's
nonempty export destination callback can produce `saved:true`. Presenting a
picker, receiving HTTP 200, uploading all bytes, or requesting cancellation is
not successful saving. UI is main-thread-only and uses the active scene. The
Native source remains alive until UIKit has completed dismissal, including
cancellation/expiry. Late callbacks cannot overwrite a prior terminal state.

Native staging belongs to this service, uses unique private directories and
exclusive files, and is cleared on failure/expiry or app restart. Guest source
files and completed downloaded IPAs are never deleted by cancelling export.
An app restart does not pretend to restore an old picker or assert a save whose
callback was not observed; a new Native session needs consent again. Checkpoints
never store bearer tokens or Native session credentials.

Security boundary: the Host Bridge token authenticates the Guest, not individual
root processes within the Guest. The trusted tool enforces filesystem provenance;
Native independently enforces metadata policy, scope, limits, consent and hashes.
It does not cryptographically attest that another root process has not copied
private data into an otherwise allowed workspace file. This feature does not
turn the existing root Agent environment into a filesystem sandbox.

## Gate B: GitHub Actions (separate stage)

Independent `cloud-build.mjs` / `cloud-artifact.mjs` modules and tests are being
prepared. They are not registered or included in Gate A's installer manifest.
The actual image contains Node/curl/git/BusyBox unzip, but not Python or gh;
production must use pure Node and authenticated official REST APIs.

Existing run 39235244295 / artifact 12178731394 was fetched read-only and verified.
The regression fixture `tests/fixtures/cloud-build/TapGame_unsigned.ipa` is
45,306 bytes, SHA256
`e07179577a9272ca04898eb91e47730c18b5cb60490097091c2a0e2d1ecf1c4d`.
Its provenance is adjacent to the fixture. The fixture is never signed or run.
Local Codex gh credentials are not evidence of authorization inside the DSH Guest.

The user authorized only the `feature/workspace-ipa-export` push, Gate A macOS
validation and one unsigned Build 30 after all gates pass on 2026-10-19.
This does not authorize Gate B activation, signing, installation, a Release or
stable-branch changes. A request with an uncertain dispatch outcome must retain
`dispatch_unknown` and never automatically dispatch again.

## CI acceptance gates

A cache miss restores the exact original RootFS from verified Build 29 artifact
12145352465 (successful run 39148238106), rather than rebuilding a changing
Alpine image. The read-only restore checks official provenance, all archive CRCs,
fixed outer/IPA hashes and the existing RootFS size/hash before publication.
An expired or unavailable original fails closed; the image pin is never relaxed.

After real simulator XCTest execution, a separate gate requires each of the 46
new tests and five original confirmation tests to occur exactly once as Success
in the actual xcresult database, with no skip or expected failure. Before IPA
packaging, another gate checks Build 30 identity, unsigned arm64 device code,
both Native classes, all 13 bundled resources and the unchanged RootFS. Portable
tests of these gate readers are controls, not evidence of Native execution.

## Historical Gate A validation and remaining device acceptance

Gate A local results (WSL Ubuntu): export 34/34, packaged Harness runtime
60/60, script contracts 10/10, XCTest runner offline contracts 14/14. All have
zero final failures/skips. These last fourteen tests verify runner failure
propagation, not UIKit execution. Forty-six additional Native XCTest methods
are written (store 15, binary socket 4, picker 19, confirmation 8), awaiting
macOS execution. The prior five confirmation tests remain.

The POSIX suites were also mistakenly invoked with native Windows Node/Python;
those attempts failed on POSIX paths/symlink permissions and the Python3/bash
environment. The Linux reruns above are the applicable results. No path
protection was relaxed to accommodate Windows.

The original Gate A logs are maintainer-local evidence, not repository downloads.
For the Build 31 candidate and its narrower verified gates, see
[the release record](../releases/1.1.0-build31.json) and [cloud build guide](cloud-build.md).
Linux Node tests exercise real file descriptors, binary HTTP transfers, hostile
paths, source mutation, lost acknowledgements, cancellation and checkpoints.
The UI protocol fixture is not an iPad Files save. Native XCTest source covers
the actual store, socket ingress, picker delegate and lifecycle transitions.
Windows has no Xcode/UIKit SDK; Native compilation/XCTest is pending authorized
macOS CI. Device saving, Files visibility and external signer recognition remain
manual checks even after CI succeeds. Never report these stages interchangeably.

Device check when a verified IPA is available: cover-install with data preserved;
use the existing TapGame IPA, call the new tool, inspect source/name/size, allow,
choose a Files destination and confirm the file really exists. Verify its SHA256
when possible, then import it into the user's signer. Also test denying consent,
cancelling Files, disabling the capability, a file above 8 MiB and foreground/
background interruption. No app uninstall, data reset, signing or installation
is automatically performed by this feature.
