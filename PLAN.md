# Goal and next steps

Let a user explicitly share their Mac's internet connection with a Kernel browser, verify its exit IP, and stop sharing reliably.

## Proven

- Stable Lightsail endpoint with automatic TLS renewal and restricted per-device tunnels.
- A real Kernel browser matches the Mac's public IP; fresh requests fail after revocation.
- The Swift app model verifies egress and traffic counters, then stops and removes session credentials.
- Helper tests cover Stop, loss of the app's control pipe, and child failure.

## Next

1. Finish manual app testing: import/Keychain, Start/Stop, Quit/force-quit, sleep, and network changes.
2. Test installation and the complete flow on a second Mac; sign and notarize for distribution.
3. Expand beyond test hosts and check browser traffic bypasses before a merchant trial.
4. Compare one representative merchant flow against existing routing, controlling browser/profile state and stopping before payment.

Routing is the current result. Improved checkout success is still a hypothesis.

## iOS track

The [foreground iPhone demo](docs/ios-demo.md) now includes QR pairing, phone-managed Kernel resources, and real browser screenshots. An initial end-to-end run is user-confirmed on iPhone Air; the [remaining network/lifecycle checks](docs/ios-foreground-plan.md) are still open. Foreground-only operation is a technical milestone, not the intended product experience. The separately scoped [BGContinuedProcessingTask experiment](docs/ios-background-follow-up.md) is not implemented.

Defer TLS interception, production consumer onboarding, and high availability.

Setup: [README.md](README.md). Tests and maintenance: [DEVELOPMENT.md](DEVELOPMENT.md).
