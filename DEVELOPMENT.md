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

Public TLS port N maps to loopback N+10000 and dedicated SSH N+20000. Admin SSH is source-restricted; port 80 serves certificate validation. Keep the AWS-managed `lightsail-connect` source enabled for authenticated SSH host-key discovery.

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
