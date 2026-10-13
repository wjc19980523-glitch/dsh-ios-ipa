Only local automated transport tests use this certificate and private key.
They contain no account credential and are never installed by the app's
production WebFetchTransport bundle or added to production trusted CAs.

SAN: web-transport.test, proxy.web-transport.test, 127.0.0.1.
The test runner explicitly sets NODE_EXTRA_CA_CERTS only for the fixture process.
A separate child removes that variable and proves the same certificate is refused.
