# DSH iOS — 1.1.0 (Build 31)

This repository is a **fork of [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios)**.
Thank you to Everett and the upstream contributors for the original iOS integration,
and to DeepSeek Harness, iSH / iSH-ARM64, Alpine Linux and the other dependencies.
This fork is maintained at [wjc19980523-glitch/dsh-ios-ipa](https://github.com/wjc19980523-glitch/dsh-ios-ipa).

[中文说明](README.zh.md) · [Changes](CHANGELOG.md) · [Cloud builds](docs/cloud-build.md) ·
[Signing and installation](docs/install-sign.md) · [FAQ](docs/faq.md)

DSH embeds an Alpine Linux guest and DeepSeek Harness in an iPad/iPhone app.
The Agent, shell and sessions run on the device; model inference uses the configured online API.
**The iOS app is compiled on cloud macOS/Xcode through GitHub Actions. The IPA is unsigned;
you must sign it yourself before installation.** iOS/iPadOS 16 or later is required.

> **Status:** Build 31 is a Hotfix test candidate, not a stable release. Its P0 message-chain
> tests, two native upgrade tests, device archive and IPA integrity gates passed.
> Physical iPad validation remains pending. Old malformed session history is not repaired.

## Changes in this fork

- Chinese UI by default on a fresh guest configuration; existing language preferences are preserved.
- Session-scoped task history and status (`job_history`, `job_status`) and clearer Activity states.
- Read-only development preflight, including a clear indication that native iOS builds require macOS/Xcode.
- Large workspace file export (`workspace_export`): chunked transfer, hash verification and native save confirmation,
  up to 512 MiB per file subject to storage and lifecycle limits. Legacy 8 MiB file tools remain available.
- Harness authentication, startup/lifecycle handling, diagnostics and related regression coverage.
- Build 31 fixes the `output.render(args, value)` contract so tool arguments are not emitted as text results.

See [CHANGELOG.md](CHANGELOG.md) for the 1.0.16 → 1.1.0 transition and validation boundaries.

## Known limitations

- **The iPad Linux guest cannot compile a native iOS app locally.** It has no Xcode or iPhoneOS SDK.
- **In-app one-click cloud builds are unfinished.** The modules under `experimental/cloud-build/` are unintegrated drafts,
  excluded from Build 31. Maintainer-driven GitHub Actions builds are a separate capability.
- iOS may suspend or terminate the app; task history does not guarantee background execution or process recovery.
- Sharing the repository does not supply model credentials, Apple signing credentials or an immediately installable IPA.

## Quick start

1. Open the [successful Build 31 run](https://github.com/wjc19980523-glitch/dsh-ios-ipa/actions/runs/39781925031)
   and download `DSH-Build31-unsigned-hotfix-candidate` from Artifacts while it remains available.
2. Extract the ZIP and verify the IPA SHA256 against [the release metadata](releases/1.1.0-build31.json).
3. Follow [the signing and installation steps](docs/install-sign.md): use your own signing account/tool,
   connect and trust the device, sign/install, then enable Developer Mode if required.
4. For an upgrade, back up data and preserve the existing app and signing identity. Configure your own model key in DSH.

The download is an unsigned test candidate with a retention deadline, not a permanent GitHub Release.
See [cloud-build.md](docs/cloud-build.md) for the two workflows and fixed RootFS availability constraints.

## Clone and build from source

```bash
git clone https://github.com/wjc19980523-glitch/dsh-ios-ipa.git
cd dsh-ios-ipa
```

Native compilation requires macOS, a suitable Xcode installation and the emulator toolchain.
Use the cloud workflow or follow [the local Mac build steps](docs/install-sign.md#3-使用自己的-mac-从源码构建).
The checked-in signing settings contain no developer certificate or account credentials;
your local signing profile must match the enabled entitlements.

The original screenshots and walkthrough in `docs/` are upstream reference material, not Build 31 acceptance evidence.

## How it works

```
┌─ DSH.app ────────────────────────────────────────────────────────┐
│  DSHRootViewController ──► WKWebView ──► http://127.0.0.1:3080    │
│         │                                        ▲                │
│  DSHHarness  (port pick · readiness probe · restart · health)     │
│         │  ISHShellExecutor                      │ loopback       │
│  ┌──────▼──── iSH-ARM64 emulator (Alpine 3.21 aarch64) ───────┐   │
│  │  /usr/local/bin/dsh-serve                                  │   │
│  │    → node --expose-internals @deepseek-ai/dsh web          │   │
│  │        --host 127.0.0.1 --port N  ─────────────────────────┘   │
│  └────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

- **Emulator.** iSH-ARM64 is a userspace Linux emulator (Asbestos threaded-code
  interpreter with an AArch64 guest backend). The guest's sockets are
  pass-through host sockets, so the loopback port dsh listens on is reachable
  from the app's web view (and Safari).
- **Guest image.** `scripts/build-rootfs.sh` builds `root.tar.gz` **on the Mac
  inside the same emulator**: Alpine minirootfs → `apk add nodejs npm …` → the
  pinned npm tree from `rootfs/staging` (installed on the host for
  linux/arm64/musl) → `node-pty` rebuilt for musl → overlay → exported with
  `unfakefsify`. `rootfs/overlay` holds the entry point `dsh-serve`, the guest
  self test, and `cordis.patch.yml` — the dsh profile layer that turns off the
  per-command sandbox (the whole guest already *is* the sandbox) and defines
  the `guest-ask` permission preset.
- **Supervisor.** `DSHHarness` picks a free loopback port, launches `dsh-serve`
  through `ISHShellExecutor`, polls until HTTP answers, restarts on crashes and
  publishes state to the UI. `DSHRootUpgrader` compares the bundled image's
  SHA-256 with the imported root on every launch and migrates user data when it
  changes.

### Changes made to the emulator (`ish-arm64`, vendored fork of OpenMinis/ish-arm64)

| Change | Why |
|---|---|
| `FCVTL/FCVTL2`, `FCVTN/FCVTN2`, `FCVTXN/FCVTXN2` and vector fixed-point `SCVTF/UCVTF/FCVTZS/FCVTZU #fbits` gadgets | libvips (used by `sharp`, dsh's image-attachment plugin) traps on them |
| `FMOV (scalar, immediate)` decoder fix | imm8 bit 6 was not inverted for constants such as `2.25` or `31.0` — every guest program computed wrong values |
| `waitpid()` no longer returns `EINTR` when its 1 s bounded wait merely times out | broke gcc/g++ (`failed to get exit status`), node-gyp, anything waiting on a child > 1 s |
| Streaming `fetch()` polyfill (`app/RootfsPatch.bundle`) returning real `Response` objects | LLM streaming (SSE) via undici needs WebAssembly, which jitless V8 lacks |
| `ISHShellExecutor` returns shell exit codes and drains pipes after exit; `ContainerURL()` falls back without an app group; deployment target 15.0 | app integration |

The vendored copy records its upstream commit in [`ish-arm64/UPSTREAM.md`](ish-arm64/UPSTREAM.md); the fixes are self-contained and welcome upstream.

## Tests

```bash
make test               # unattended on this Mac: emulator + rootfs + XCTest/XCUITest on the simulator
make test-device-unit   # unit + guest-integration tests on the connected iPad
make test-device        # + UI tests on the iPad (enable Settings ▸ Developer ▸ UI Automation first)
```

| Suite | Covers | Runs on |
|---|---|---|
| `tests/emu-test.sh` | the new NEON gadgets and the FMOV fix (C test compiled with gcc *inside* the guest), the `waitpid` regression, the fetch polyfill (host node, 11 checks) | macOS |
| `tests/rootfs-test.sh` | imports `root.tar.gz` like the app does, guest self test (node-pty/koffi/ripgrep/sharp), profile patch, **headless LLM round trip through a mock DeepSeek SSE server**, every bridge tool driven through a real agent turn against a stub bridge, `dsh-serve` reachable over loopback | macOS |
| `DSHTests` (XCTest, hosted in the app) | port allocator, log ring, readiness probe, harness state machine (fake launcher + local HTTP server); host bridge auth/gating/limits; the confirmation gate (background → refuse, no stacking, always answers); every capability route (refused when switched off, refused before the framework is touched, validated before the user is asked, empty Health answers always explain themselves); guest integration: real server answers, `dsh-selftest`, node/dsh versions, root-image bookkeeping, **whole agent turns calling `device_info` and `health_query` through the bridge against an in-app mock model** | simulator / device |
| `DSHUITests` (XCUITest) | app boots to the DeepSeek Harness UI, port in the bar, server-log sheet, terminal sheet, landscape layout, the Capabilities screen's switches | simulator / device |

For Build 31, the verified Hotfix gates are 13 message-chain tests, two native upgrade tests,
unsigned device compilation and IPA integrity. Unchanged host regression evidence was reused.
This does not claim a fresh full-suite or physical-device pass. See [cloud build evidence](docs/cloud-build.md).

## Project layout

```
DSH.xcodeproj   generated Xcode project (targets DSH, DSHTests, DSHUITests; scheme DSH)
app/            Objective-C sources, AppDSH.xcconfig, Info.plist, assets, launch screen, privacy manifest
rootfs/         overlay baked into the guest image + pinned npm manifest (staging/package.json)
scripts/        build-rootfs.sh · gen-xcode-project.rb
tests/          emu-test.sh · rootfs-test.sh · mock-deepseek.mjs · fetch-polyfill-test.mjs
                emu/ (guest C tests) · DSHTests/ · DSHUITests/
docs/           screenshots
build/          generated: root.tar.gz, work dirs, xcresult bundles (git-ignored)
ish-arm64/      the emulator (vendored, see its UPSTREAM.md)
site/           inherited upstream website sources (not this fork's download authority)
```

`DSH.xcodeproj` is generated by `scripts/gen-xcode-project.rb`
(`make project`); re-run it after adding or removing source files. All build
settings live in `app/AppDSH.xcconfig`; the bundle id is `com.xnuapp.dsh`
(change `DSH_BUNDLE_ID_PREFIX` for your own builds).

## iOS capabilities (host bridge)

The app runs a loopback HTTP listener that dsh tools inside the guest call to
reach iOS capabilities. Shipping today:

| Tool | What it does | Gate |
|---|---|---|
| `device_info`, `device_power` | model, iOS version, locale, battery, heat | no further gate |
| `calendar_query`, `reminders_query` | your events and reminders | switch + iOS permission |
| `health_query` | steps/distance/energy, heart rate, sleep, workouts | switch + iOS permission |
| `location_query` | one fix, with its accuracy — never tracking | switch + iOS permission |
| `contacts_search` | look up a person by name (no way to list everyone) | switch + iOS permission |
| `notify` | a notification when a long task finishes, 10/hour | switch + iOS permission |
| `file_import` | you pick a file and hand it to the agent | the picker is the consent |
| `calendar_create_event`, `reminders_create` | adds an event or reminder | **asks every time** |
| `file_export` | saves a file out of DSH | **asks every time** |
| `photo_import` | one photo, chosen by you in the system picker | switch (the picker is the gate) |
| `share` | offers text to the iOS share sheet | switch + confirmation each time |
| `shortcut_run` | runs one of your shortcuts | **asks every time** |

Photos and the share sheet are implemented using the system picker/sheet and
the same native gates as the other capabilities. There is deliberately **no clipboard
capability at all**: reading one that came from another app makes iOS interrupt
the user every single time, and writing was dropped with it rather than leave a
tool whose worst case is "the agent silently replaced what you were about to
paste".

Anything that changes something asks first, and the alert names the actual
effect ("Add this reminder? “buy milk”, due Friday, in Home") rather than the
capability. A confirmation that nobody answers is refused rather than left
hanging, a call that arrives while DSH is in the background is refused instead
of queueing a dialog you cannot see, and a burst of calls cannot stack alerts.

Everything ships **on**, and any of it can be switched off in **⋯ ▸
Capabilities**. The switch being on does not mean data flows: a read still waits
on iOS's own permission dialog, raised the first time the agent asks, and a write
still asks every single time. The switch takes effect on the agent's next tool
call, including mid-turn. A call made before either gate is open comes back as a
recoverable `permission_denied` telling the model what the user has to do, rather
than hanging the turn on a dialog.

Apple Health has a wrinkle worth knowing: iOS never tells an app whether *read*
access was declined, so an empty result and a declined category look identical.
Health answers therefore carry a note saying so, and the tool is told to relay
it instead of concluding you took no steps this month.

Everything the agent does is recorded — every capability call, every
confirmation you answered, and every tool it ran inside the guest, including
the ones that never touch iOS. **⋯ ▸ Activity** shows the timeline; each switch
says when it was last used; and the bar lights up when something on the device
has just been read. Arguments appear as one-line summaries and the contents a
read returned are never recorded, so the record is safe to keep and to share.

DSH also removes two devices iSH itself gives the guest — `/dev/clipboard` and
`/dev/location` — because they reach the pasteboard and CoreLocation without
passing any of this.

Capabilities are gated by the app, not by the guest: a random per-launch bearer
token keeps *other apps* out, while a per-capability switch (and, for sensitive
ones, a native confirmation) is what keeps the *agent* honest — it runs as root
in the guest and can read any secret we put there. Every call is logged to
*Server Log*.

See [docs/host-bridge.md](docs/host-bridge.md) for the protocol, the security
model and the capability/permission matrix, and [docs/roadmap.md](docs/roadmap.md)
for what is built and what comes next.
The machine-readable capability/tool inventory is [docs/capabilities.json](docs/capabilities.json);
the script tests fail when either side drifts from it.

## FAQ

See [the FAQ](docs/faq.md) for signing, local versus cloud compilation, task/export limits,
model credentials, test certificates and unfinished cloud-build integration.

## Contributing

Issues and pull requests are welcome. Please run `make test` before opening a
PR (needs an Apple Silicon Mac with Xcode); emulator changes should come with a
case in `tests/emu/neon_convert_test.c` or `tests/emu-test.sh`. Bumping the
bundled dsh: edit `rootfs/staging/package.json`, run `make rootfs`, then
`make test-rootfs`.

## Credits

- [everettjf/dsh-ios](https://github.com/everettjf/dsh-ios) — original project and upstream implementation.

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — the agent harness (MIT).
- [iSH](https://github.com/ish-app/ish) and [iSH-ARM64](https://github.com/OpenMinis/ish-arm64) — the emulator this app is built on (GPLv3).
- [libarchive](https://github.com/libarchive/libarchive), [hterm](https://chromium.googlesource.com/apps/libapps/), [Alpine Linux](https://alpinelinux.org).

## License

**GPL-3.0.** DSH compiles and statically links the GPLv3 iSH / iSH-ARM64
emulator, so the whole app is GPLv3; iSH's additional App Store terms in
[`ish-arm64/LICENSE.IOS`](ish-arm64/LICENSE.IOS) apply as well. Full text in
[LICENSE](LICENSE); third-party notices (libarchive, hterm, DeepSeek Harness,
Alpine packages) in [第三方声明 / Third-party notices](docs/third-party-notices.md).

Not affiliated with DeepSeek or the iSH project.
