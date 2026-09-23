# Goal and next steps

Let a user start a cloud-browser task that uses their device's internet connection, continues when they leave the iPhone app, and stops sharing reliably.

## Demonstrated

- Mac egress through a shared Lightsail relay, with verified IP and revocation checks.
- Foreground iPhone egress with QR pairing and a cloud-browser screenshot feed.
- Five-minute locked-phone diagnostics on Wi-Fi and cellular; cellular requests also resumed after a 60-second pause. The cellular no-task baseline had no successful background requests.

These are routing and feasibility results, not improved checkout success or production reliability. [Results and scope](docs/ios-background-results.md).

## Next

1. Repeat matched background tests and verify cancellation, force-quit, and network-loss behavior.
2. Add backend-owned onboarding, scoped credentials, agent progress, and an external session lease.
3. Resolve distribution and security gaps before expanding to general browsing or a merchant trial.

The Mac track still needs second-device, manual lifecycle, and signed/notarized distribution checks. Defer TLS interception and high availability.

[Setup](README.md) · [Background follow-up](docs/ios-background-follow-up.md) · [Developer notes](DEVELOPMENT.md)
