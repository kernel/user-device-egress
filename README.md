# User-device egress for Kernel browsers

A macOS menu-bar app that lets a Kernel cloud browser use your Mac's internet connection through a shared AWS relay.

**iPhone experiment:** [foreground demo setup](docs/ios-demo.md)—QR pairing, a temporary Kernel browser, and a live screenshot feed. A foreground end-to-end run has been user-confirmed on an iPhone Air; background operation remains unproven.

```text
Kernel browser → HTTPS relay → reverse SSH tunnel → Mac → website
```

**Proven:** the browser sees the Mac's public IP (or VPN exit IP), and fresh browser requests fail after tunnel revocation. Website TLS stays intact; no root CA or system proxy change is needed.

This demonstrates routing—not improved checkout success. The prototype only allows two IP-check services and Kernel's health-check host.

[How it works: architecture and sequence diagram](docs/how-it-works.md)

![Mac Egress sharing a verified internet connection](docs/mac-egress.png)

## Contents

- `MacEgress/` — SwiftUI app: consent, Start/Stop, Keychain storage, exit IP, traffic counters.
- `iOSEgress/`, `mobile/` — foreground iPhone demo and embedded Go SSH tunnel; `internal/connectproxy/` is shared with Mac.
- `cmd/` — bundled Go proxy and session supervisor.
- `infra/` — Lightsail CloudFormation template, TLS, per-device enrollment.
- `scripts/`, `tests/` — deployment, browser verification, cleanup, and tests.

## Setup

Run commands from the repository root. Already enrolled? Skip to step 3.

- **Build:** macOS 14.6+, Xcode (tested with 26.5), Go 1.26+.
- **Relay setup:** AWS CLI v2 with CloudFormation/Lightsail credentials, jq, SSH, curl.
- **Browser test:** Python 3, Kernel CLI (tested with 0.34.0), `KERNEL_API_KEY` in your environment.

### 1. Create a relay

Creates a billable VM using your AWS environment. No hostname needed; TLS setup accepts Let's Encrypt's terms and enables automatic renewal.

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity
admin_ip=$(curl -4 --noproxy '*' -fsS https://checkip.amazonaws.com/)

./scripts/relay.sh deploy mac-egress-relay SshCidr="$admin_ip/32"
./scripts/configure-relay.sh mac-egress-relay
./scripts/verify-relay.sh mac-egress-relay
./scripts/tenant.sh init mac-egress-relay
```

If SSH isn't ready, retry configuration after boot. After changing networks, update `SshCidr` using `relay.sh deploy`. Don't rerun foundation configuration after tenant initialization.

### 2. Enroll your Mac

Generate the key **on the Mac**; give only the public key to the relay operator. Return the manifest through a trusted channel.

```bash
umask 077
mkdir -p .local
ssh-keygen -t ed25519 -N '' -f .local/device1

./scripts/tenant.sh list mac-egress-relay
./scripts/tenant.sh enroll mac-egress-relay device1 20000 \
  .local/device1.pub > .local/device1.json
```

Choose an unused name and port (default range: 20000–20009). Revoked names/ports remain reserved.

### 3. Start the app

Open `MacEgress/MacEgress.xcodeproj`. Select your signing team and **My Mac**, then **⌘R**. Keep App Sandbox off and Hardened Runtime on. Helpers are bundled; running the app requires no developer tools or cloud credentials.

Click the menu-bar network icon. Use **Choose manifest…** for `.local/device1.json` and **Choose private key…** for `.local/device1`—not `.pub`—then **Save device**. Each button shows its selected filename. Hidden files are shown automatically; Xcode debug builds open the repo's `.local` folder.

Check consent and **Start sharing**. Expect **Connecting → Verifying → Sharing**, with an exit IP matching:

```bash
curl -4 --noproxy '*' https://checkip.amazonaws.com/
```

### 4. Test a Kernel browser

Supply `KERNEL_API_KEY` securely in your shell. In the app, choose **Connection → Reveal active session files…**:

```bash
session_dir="/absolute/path/to/the/active/session"
python3 scripts/verify-kernel.py "$session_dir/manifest.json" \
  "$session_dir" .local/kernel-check1
```

This creates a proxy/browser, checks egress, and deletes the browser **before** its proxy. Use a new output directory per run. If cleanup fails, follow its `result.json`; deleting an attached proxy can enable direct egress.

For a disposable device, add `--revoke mac-egress-relay` to test disconnect. This requires AWS access and permanently retires the enrollment.

## Stop / remove

**Stop sharing** or **Quit** closes the app's tunnel and removes session credentials; the Keychain device remains. Let the browser verifier finish first—the app doesn't manage Kernel resources.

```bash
# Retire one device:
./scripts/tenant.sh revoke mac-egress-relay device1
# Remove the relay, disk, keys, and static IP without a snapshot:
./scripts/relay.sh destroy mac-egress-relay
```

## Limits

HTTPS test hosts only; private destinations blocked; 32 connections maximum, two minutes each. Shared relay administrators can see proxy credentials/metadata. No hardened hostile-tenant isolation, auto-reconnect, general browsing, or notarized installer. Network-change detection isn't instantaneous. Manual UI/lifecycle and second-Mac checks remain.

Kernel's upstream HTTPS proxy implementation currently skips relay certificate verification. The relay serves a publicly trusted certificate, but that alone does not authenticate it to Kernel; address this before production use.

[Tests and maintenance](DEVELOPMENT.md) · [Roadmap](PLAN.md)
