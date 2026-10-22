# Unfinished cloud-build prototype

These modules and their tests preserve local work that is **not integrated** into DSH 1.1.0 Build 31.
They are outside `app/JobTracking.bundle` so Xcode cannot copy them as shipped resources.
No tools or UI entry points register them in the app. Passing isolated tests does not establish
an end-to-end cloud build feature, signing support, or device installation.

POSIX-host checks (Node 22+, from the repository root):

```bash
NODE_EXTRA_CA_CERTS="$PWD/tests/fixtures/web-transport/test-cert.pem" \
  node --test tests/cloud-artifact-test.mjs tests/cloud-build-test.mjs
```

These use controlled local fixtures, not user credentials or a production workflow dispatch.
For the currently supported maintainer-driven build, see [cloud-build.md](../../docs/cloud-build.md).
