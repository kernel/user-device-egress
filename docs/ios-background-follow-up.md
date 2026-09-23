# Background egress: next steps

The [initial device tests](ios-background-results.md) demonstrated five-minute locked-phone egress on Wi-Fi and cellular, plus resumption after a 60-second pause in browser work. The goal remains a **finite, user-started agent task** that can finish after the user leaves the app—not an always-on residential proxy.

## Before a broader trial

1. **Repeat and broaden testing.** Repeat each cellular comparison three times, then test another device/OS, Low Power Mode, longer pauses, and network changes. Keep conditions matched and measure battery/memory rather than inferring consumption from start-only metadata.
2. **Verify failure boundaries.** Test system-UI cancellation, Stop, force-quit, and network loss with an independent disconnect probe. Measure when existing streams close and new requests fail. Never remove a proxy from a running browser to stop traffic.
3. **Move ownership to the backend.** Replace QR/API-key setup with app-session enrollment and scoped authorization. Add authentic agent milestones, completion/cancellation signals, and an externally enforced session lease that stops forwarding and the cloud job if the phone disappears.
4. **Resolve distribution and security.** Seek Apple guidance on this exact reverse-egress use case. Address the [relay certificate-verification gap](../README.md#limits), broader destination policy, and tenant isolation before production.

## API boundaries

The experiment uses [`BGContinuedProcessingTask`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) for explicit user-initiated work, with real request-count progress, system cancellation, and fail-immediately scheduling via [`BGContinuedProcessingTaskRequest`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest). The current harness does not request GPU access, fake progress, or automatically resubmit jobs.

A successful diagnostic does not establish App Store acceptance, an execution-time guarantee, or suitability for arbitrary agent waiting. Apple documents [long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados); [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) is also relevant before considering a Network Extension.

The current longest preset is about five minutes. Longer tests require revisiting the harness's explicit deadlines; simply extending a phone timer is not a remote safety boundary.

[Run the demo](ios-background-demo.md) · [Implementation notes](../DEVELOPMENT.md#background-lab-internals)
