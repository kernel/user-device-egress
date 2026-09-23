# Original foreground implementation plan

Historical design plan, retained for implementation rationale. The foreground app is implemented, and a separate background app has since passed initial locked-phone tests. For the current state, see [demo setup](ios-demo.md), [measured results](ios-background-results.md), and [remaining work](ios-background-follow-up.md). The sequencing and estimates below describe the original plan, not outstanding implementation work.

## Goal and scope

Prove that a real Kernel browser can use a physical iPhone's internet connection through our existing relay, with website TLS intact and an explicit Stop control.

Foreground-only operation is a technical milestone, **not the intended product experience**. Once routing works, investigate [background continuation](ios-background-follow-up.md). The implementation now includes a real screenshot feed and phone-managed Kernel resources, following the updated demo request. General browsing, automatic reconnection, and an always-on exit node remain out of scope.

Keep the existing test-host allowlist, authentication, connection bounds, and private-network blocking. Leave Let's Encrypt and the working Mac app in place.

## Recommended implementation

```text
Kernel browser → relay HTTPS endpoint → SSH reverse-forwarded stream
               → in-process iPhone CONNECT handler → public test website
```

Use a native SwiftUI iOS app with a small embedded Go networking library. The library opens an outbound SSH connection and requests the tenant's existing loopback forwarding port. Serve the CONNECT handler directly on the returned remote listener; no phone-side listening port is necessary.

Destination sockets must be opened locally by the iPhone, not through SSH's `Client.Dial`, which would move egress back to the relay. Also, SSH forwarded connections do not implement socket deadlines in the [current Go implementation](https://github.com/golang/crypto/blob/master/ssh/tcpip.go). Add and test explicit channel timeout/cancellation handling; do not assume the existing HTTP header timeout and `SetDeadline` calls still enforce limits on these streams.

The implementation follows this architecture; on-device/network gates below remain to be validated:

| Component | Reuse or change |
| --- | --- |
| Lightsail, TLS, tenant enrollment | Reuse; allocate a separate iPhone tenant. Do not reuse an active Mac tenant. |
| `cmd/mac-proxy/main.go` | Extract its handler and safety checks into a shared Go package; preserve Mac behavior and tests. |
| `/usr/bin/ssh` and `ssh-keygen` | Replace on iOS with `golang.org/x/crypto/ssh` and in-process key handling. |
| `cmd/mac-session/main.go` | Reuse concepts, not its subprocess/pipe/process-group implementation. |
| Swift app lifecycle | New iOS target; explicit start/stop, Keychain, import/export, status, and cancellation. |

The Go SSH library supports remote listeners through [`Client.Listen`](https://pkg.go.dev/golang.org/x/crypto/ssh#Client.Listen). [`gomobile bind`](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile) produces an Apple XCFramework and Objective-C bindings callable from Swift. Pin tested Go, `x/mobile`, and `x/crypto` versions; do not make builds depend on moving `latest` versions.

Choose this first because the proxy safety logic already exists in Go. Time-box framework integration to half a day. If it fails on the supported Xcode/device combination, reassess a native implementation using [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh), which supports reverse forwarding. That alternative requires porting and retesting the proxy, not merely changing an import.

## Sequence and verification gates

### 1. Prove the on-device networking core

Create a separate iOS app target with iOS 26 minimum deployment, preparing for the later background experiment. Build a minimal XCFramework and run it on a physical iPhone. Expose only a narrow start/stop/events interface, keeping networking off the main thread.

Prerequisites: a supported physical iPhone with Developer Mode enabled, working Xcode signing, and an operator able to enroll a dedicated test public key. Use development installation initially; TestFlight and App Store distribution are separate gates.

Verify an authenticated SSH connection with the manifest's pinned host key, a successful remote-listener request, and a harmless HTTPS request from the phone. Wrong host keys must fail. Implement handshake deadlines, connection-loss detection, and cancellation of every accepted stream; closing only the listener is insufficient.

**Gate:** real-device handshake and reverse-forwarding work without a shell, subprocess helpers, a VPN configuration, or changed relay permissions.

### 2. Add enrollment and the foreground session

Generate an Ed25519 key on the phone and store it in the app's Keychain. Scan an admin-issued, single-use QR invitation; exchange the public key over trusted HTTPS for the relay manifest and pinned SSH host key. No file transfer is needed. Do not send a device private key to the relay or the development Mac.

Add consent, Start/Stop, connection status, route-check results, and byte counters. Generate a fresh proxy password per session. For the updated self-contained demo, store a dedicated developer Kernel API key in the phone's Keychain and call Kernel directly. Do not export session credentials or private keys. This replaces the original operator-Mac verifier approach; production authorization must move behind a scoped backend.

Stop on entering the background for this milestone, on explicit Stop, and on detected network changes. Do not stop merely because a temporary system panel makes the scene inactive. Relaunch starts stopped; no automatic resume. Record abrupt termination separately from graceful cancellation.

**Gate:** repeatable enrollment and three start/stop cycles with fresh credentials and no stale session reuse.

### 3. Attach a Kernel browser and verify the route

The iOS app performs browser creation, IP comparison, screenshot polling, and cleanup itself. Leave `scripts/verify-kernel.py` as the Mac verifier: its direct `curl` measures the **operator Mac's** IP and is not a valid iPhone baseline.

Create a temporary Kernel custom proxy and browser using the API. Visit both current IP-check services with cache-busting requests. Compare each result with a recent direct phone observation for the same service/address family. Show the actual browser screenshots with capture timestamps and phone byte counters. Do not use Safari as the baseline, or treat IP equality alone as proof when Mac and phone share Wi-Fi.

Keep the proxy attached while testing Stop: both fresh browser requests and an active stream must fail rather than switch to another exit. Delete the browser before the custom proxy in all cleanup paths. Keep test credentials and resource IDs out of public reports.

**Gate:** successful foreground requests on Wi-Fi and cellular, plus observed failure after Stop. Report any carrier-dependent mismatch as unresolved, not a successful verification.

### 4. Exercise mobile-network assumptions

The current helper forces `tcp4`, accepts only IPv4 results, and uses a literal IPv4 relay address. Audit those assumptions before claiming cellular compatibility. Apple requires [IPv6-only network support](https://developer.apple.com/support/ipv6/) and documents [system-assisted NAT64 address synthesis](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/UnderstandingandPreparingfortheIPv6Transition/UnderstandingandPreparingfortheIPv6Transition.html).

Test the actual Go dialer on IPv6-only/NAT64 rather than assuming it inherits native URL-loading behavior. If necessary, use an Apple-system resolver/dialer bridge; assess relay DNS/IPv6 changes separately rather than silently changing the deployment. Preserve destination filtering, including translated private-address cases, if NAT64 support requires expanding accepted address ranges.

Run with Wi-Fi disabled for the cellular case. Record VPN/Private Relay settings, OS version, and carrier; do not promise an identical Safari IP or a stable carrier IP. Also test Wi-Fi loss, airplane mode, backgrounding, lock, and force-quit, without an attached debugger.

**Gate:** a small results matrix stating exactly which networks work, how each disconnect behaves, and remaining gaps. Then proceed to the background experiment.

## Deliverable and effort

A runnable iOS target, reproducible framework build, shared proxy tests, phone-managed browser verification, and a short redacted test report. Keep Mac tests passing. Initial estimate: 3–5 engineering days with a provisioned physical phone; framework or NAT64 problems can extend this.

The existing Kernel upstream-proxy certificate-verification caveat still applies. This demo does not resolve it or establish App Store approval, production isolation, or merchant checkout improvement.

**Next verification unit:** exercise repeated Start/Stop, lock/background, force-quit recovery, and cellular separately; the first foreground iPhone Air run is user-confirmed.
