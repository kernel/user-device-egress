# User-device egress for Kernel browsers

Let a Kernel cloud browser use a Mac or iPhone's internet connection. The shared AWS relay carries the tunnel; the user's device is the website-facing exit point.

```text
Kernel browser → HTTPS relay → reverse SSH tunnel → user device → website
```

**Demonstrated on iPhone Air:** five-minute locked-phone runs passed on Wi-Fi and cellular, including 60/60 matching-IP requests in each run. A separate bursty run survived a 60-second pause; the cellular baseline without continued processing had no successful background requests. [Results and caveats →](docs/ios-background-results.md)

This is a routing prototype, not evidence of improved checkout success. Website TLS stays end to end; no root CA or system proxy change is required.

## Choose a demo

| App | Demonstrates | Setup |
| --- | --- | --- |
| `MacEgress/` | Menu-bar sharing, verified exit IP, Start/Stop | [Mac](docs/mac-demo.md) |
| `iOSEgress/` | Foreground phone egress with a cloud-browser screenshot feed | [iPhone](docs/ios-demo.md) |
| `iOSEgressBackground/` | Finite locked-phone jobs using `BGContinuedProcessingTask` | [Background lab](docs/ios-background-demo.md) |

`infra/` and `scripts/` provision the Lightsail relay and enroll devices. `mobile/`, `cmd/`, and `internal/connectproxy/` contain the shared networking core. [Architecture and sequence diagram](docs/how-it-works.md).

## Setup

Requires Xcode (tested with 26.5), Go 1.26+, and a Kernel account. Relay operators also need AWS CLI v2 credentials, jq, SSH, and curl. Run commands from the repository root.

### 1. Create a relay

Creates a billable Lightsail VM in your configured AWS account. No hostname needed; TLS setup accepts Let's Encrypt's terms and enables automatic renewal.

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity
admin_ip=$(curl -4 --noproxy '*' -fsS https://checkip.amazonaws.com/)

./scripts/relay.sh deploy mac-egress-relay SshCidr="$admin_ip/32"
./scripts/configure-relay.sh mac-egress-relay
./scripts/verify-relay.sh mac-egress-relay
./scripts/tenant.sh init mac-egress-relay
```

Already provisioned? Skip this step. Do not rerun foundation configuration after tenant initialization; see [maintenance](DEVELOPMENT.md#relay-maintenance).

### 2. Run an app

Follow the setup guide above. iPhone demos use a single-use pairing QR and a dedicated demo Kernel API key. This is developer setup: a consumer integration would register devices through its backend and keep Kernel credentials server-side.

## Limits

Test HTTPS hosts only; private destinations blocked; 32 concurrent connections with a two-minute limit each. Relay administrators can see proxy credentials and metadata, not website TLS contents. General browsing, automatic reconnection, hardened hostile-tenant isolation, and a production installer are out of scope.

Background results cover one device and one run per reported condition—not guaranteed runtime or App Store acceptance. A server-enforced session lease and broader failure testing remain [follow-up work](docs/ios-background-follow-up.md).

The previously identified Kernel upstream HTTPS-proxy certificate-verification gap remains a production blocker: a trusted relay certificate alone does not establish that Kernel authenticates it.

[Tests, maintenance, and teardown](DEVELOPMENT.md) · [Roadmap](PLAN.md)
