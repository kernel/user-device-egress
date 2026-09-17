# Developer notes

Start with [README.md](README.md) for setup. No live cloud resources are touched by these local checks:

```bash
go test -race ./...
go vet ./...
./tests/relay.sh
python3 -m unittest discover -s tests -p 'test_*.py'
xcodebuild test -project MacEgress/MacEgress.xcodeproj -scheme MacEgress \
  -destination 'platform=macOS' -only-testing:MacEgressTests
```

The optional Swift `liveStartStop` test runs only when the test process receives `MAC_EGRESS_LIVE_MANIFEST` and `MAC_EGRESS_LIVE_KEY`; prefix them with `TEST_RUNNER_` when invoking `xcodebuild`. UI automation could not initialize on the development Mac; manual UI checks remain.

## iOS development

```bash
./scripts/build-ios-core.sh
xcodebuild test -project iOSEgress/iOSEgress.xcodeproj -scheme iOSEgress \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:iOSEgressTests
```

The generated static XCFramework stays under ignored `.local/ios/`; rebuild it after Go changes. Go dependencies/tool versions are pinned in `go.mod`. Swift tests use a fake HTTP transport: they cover bridge validation, proxy/browser requests, cleanup order, lost-create-response recovery, and consent gating without creating cloud resources. Go tests cover the shared CONNECT policy and the deadline adapter required by SSH streams. Follow [the demo guide](docs/ios-demo.md) for real-device verification; simulator success isn't phone-egress evidence.

## Live checks

Use an enrolled test device with no other active session. These helper tests stop their own sessions but do not revoke the device or create Kernel resources:

```bash
python3 tests/live-app-session.py /path/to/MacEgress.app/Contents/MacOS \
  .local/device1.json .local/device1
```

`tests/AppModelSmoke.swift` is a standalone fallback for Xcode test-service failures. Compile it with `DeviceConnection.swift` and `SharingModel.swift`; place the built `mac-session` and `mac-proxy` beside its executable. Run with manifest and private-key paths.

For a terminal-only sharing session, use a new directory; Ctrl-C stops it:

```bash
./scripts/start-tenant.sh .local/device1.json .local/device1 .local/session1
```

The terminal helper leaves its private session files on disk. `tests/live-tenant.py --help` describes the two-session isolation checks. Its `--revoke` option permanently retires the first tenant.

## Device pairing

For an already provisioned relay, deploy the new HTTPS pairing port and install the service once:

```bash
./scripts/relay.sh deploy mac-egress-relay
./scripts/pairing.sh install mac-egress-relay
```

Generate an invitation using AWS/admin access on the Mac, not on the phone:

```bash
./scripts/pairing.sh issue mac-egress-relay iphone1 .local/pairing-iphone1
open .local/pairing-iphone1/pairing.png
```

Use a fresh device name and output directory. The script selects a free tenant port and generates the QR locally using macOS frameworks. **Keep the QR and `invitation.json` private**; they authorize one device enrollment for 10 minutes. Unclaimed expired invitations release their reservation; enrolled/revoked ports stay reserved. The existing `tenant.sh revoke` command retires a paired device. Replacing a phone requires a new enrollment, not copying its private key.

Pairing adds HTTPS port 443 with the existing trusted relay certificate. HAProxy restricts the path/method and rate-limits requests. A loopback-only Go service runs as `relaypair`; its sole sudo permission invokes `relay-pair redeem`. The root helper validates the token/key, holds the existing tenant lock, journals consumption before provisioning, and calls the existing isolated-tenant setup. There is no public invitation-creation endpoint, shell input, or AWS credential on the phone. Token hashes—not bearer tokens—are stored on the relay. Same-key retries return the existing enrollment; another key cannot reuse the code. Interrupted provisioning fails closed and needs administrator reconciliation rather than blindly repeating privileged changes.

For a **disposable** live check, issue a separate invitation, generate a local Ed25519 test key, then run:

```bash
python3 tests/live-pairing.py .local/pairing-test/invitation.json \
  .local/test-device.pub .local/test-device.json
./scripts/tenant.sh revoke mac-egress-relay testdevice
```

This creates one tenant and tests trusted HTTPS, same-device retries, and second-device rejection. No Kernel resources are created. A failed test may still have enrolled its device; check `tenant.sh list` before cleanup. The root helper's limited sudo boundary is not a claim of hardened hostile-tenant isolation.

## Relay maintenance

An admin SSH timeout after changing networks usually means the source allowlist is stale. Update only that parameter; tenant tunnels use separate ports:

```bash
admin_ip=$(curl -4 --noproxy '*' -fsS https://checkip.amazonaws.com/)
./scripts/relay.sh deploy mac-egress-relay SshCidr="$admin_ip/32"
```

```bash
./scripts/relay.sh outputs mac-egress-relay
./scripts/relay-ssh.sh mac-egress-relay sudo /usr/local/sbin/relay-health
# Extend capacity, preserving existing reservations:
./scripts/relay.sh deploy mac-egress-relay TenantPortEnd=20024 TunnelPortEnd=40024
./scripts/tenant.sh init mac-egress-relay
```

Public TLS port N maps to loopback N+10000 and dedicated SSH N+20000. Admin SSH is source-restricted; port 80 serves certificate validation and 443 serves device pairing when installed. Keep the AWS-managed `lightsail-connect` source enabled for authenticated SSH host-key discovery.

After tenant initialization, use `tenant.sh init`, not `configure-relay.sh`. It supports end-range expansion, not shrinking or changing the first port/IP. A different instance image/plan needs a migration. `verify-relay.sh` expects the first and last tenant ports to be inactive.

Certificate renewal and hourly health checks use systemd; external alerting is not configured. To test renewal without replacing the live certificate:

```bash
./scripts/relay-ssh.sh mac-egress-relay sudo /snap/bin/certbot renew \
  --cert-name relay --dry-run --run-deploy-hooks --no-random-sleep-on-renew
```

## Lifecycle details worth preserving

- Device manifest/key live in Keychain; imported originals are not deleted. Passphrase-protected keys are unsupported. Temporary app session directories are 0700, private files 0600.
- The app sends secrets through a control pipe. EOF, Stop, or child failure ends sharing. The proxy watches its parent; the app kills the supervisor's process group after a crash. Simultaneously force-killing both app and supervisor is not a tested cleanup guarantee.
- Per-device SSH services disable PAM so their children stay in the service cgroup and are terminated on revocation. Keep host-key pinning, destination validation, and forwarding restrictions intact.
- The Kernel verifier's CLI password argument is briefly visible to local processes. Interrupted API creation may leave resources without a recorded ID; reconcile by the unique name in `result.json`. Never delete a proxy before its browser.
