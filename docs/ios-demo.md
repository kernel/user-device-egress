# iPhone live demo

A foreground iOS app that opens a phone-egress tunnel, creates a temporary Kernel proxy/browser, and shows real screenshots of that browser checking its public IP. After one-time enrollment, **Start live demo** runs everything on the phone.

```text
Kernel browser → HTTPS relay → reverse SSH tunnel → iPhone → IP-check site
```

The two IP rows compare the browser with a direct request from the phone to the same site. The app alternates `checkip.amazonaws.com` and `api.ipify.org`; screenshots refresh approximately every two seconds. Only page typography is changed for readability—the IP is the website's original response.

## One-time setup

Requires Xcode 26.5 or newer, an iPhone running iOS 26+, Go 1.26+, a [provisioned relay](../README.md#1-create-a-relay), and a Kernel API key. Framework dependencies are pinned in `go.mod`; Go may download the pinned toolchain on the first build.

1. From the repo root, run `./scripts/build-ios-core.sh`. Open `iOSEgress/iOSEgress.xcodeproj`, select your signing team and physical iPhone, unlock the phone, and press **⌘R**. Rebuild the framework after changing the Go core. No VPN, root CA, Network Extension, or background capability is required.
2. On the Mac, [enable pairing and generate a QR code](../DEVELOPMENT.md#device-pairing). On the phone, tap **Setup → Scan pairing code**, allow Camera access, and scan it. Confirm **Connect**. The app registers itself and saves its connection automatically—no key files or JSON to transfer. Codes expire after 10 minutes and pair only one device; rescanning on the same phone safely retries a lost response.
3. Paste a dedicated demo Kernel API key and tap **Save setup**. The key is stored in this device's Keychain, not source code, the QR code, or the relay. If the key was already saved, it stays saved.

This is a developer demo: a phone-held Kernel key can act on its account. A distributed product needs a backend with scoped authorization; do not distribute a preconfigured build or put keys in screenshots.

For presentations, label this **demo-only setup**. The proposed consumer app would register the device through its backend using the app session, without exposing relay servers, QR pairing, or Kernel API keys. That onboarding work is separate from proving background execution.

## Demo it

1. Keep the app visible, enable the consent switch, and tap **Start live demo**. Kernel resources are temporary but billable.
2. Expect **Phone tunnel → Kernel proxy → Cloud browser → IP verified**. Watch the real screenshot feed and matching phone/browser IPs. On shared Wi-Fi, matching the Mac's IP is expected; use cellular for a distinct-phone-network test, if supported by that network.
3. Tap **Stop demo**. Sharing closes immediately; wait for cleanup to finish. A run also stops after three minutes, when the app backgrounds, or when a network change is detected.

No API key, proxy password, or private SSH key is written to Documents. Pairing sends only a public device key over certificate-verified HTTPS. The app downloads screenshots and calls Kernel's API directly; the **browser's website traffic** traverses the relay and phone.

## Cleanup and troubleshooting

- **Cleanup needed:** reopen the app and tap **Retry cloud cleanup**. A Keychain journal survives app termination. If creation's outcome is unknown, inspect the displayed unique run name in Kernel. Delete its browser **before** its proxy; only then use the manual-confirmation button. Deleting an attached proxy could enable direct egress.
- **Pairing expired:** generate a fresh code. Treat the QR/link like a password until it expires. Camera unavailable? Expand **Have a pairing link instead?** and paste the link from the private invitation file.
- **Cannot reach relay:** confirm the phone is paired and its dedicated SSH port is accessible. A developer-disk-image error saying `DeviceLocked` means unlock the iPhone and rerun from Xcode.
- **IP mismatch / network changed:** the app stops rather than claiming success. Carrier routing, VPNs, and address-family differences can change observed IPs. Start a new run on a stable network.

## What is and isn't verified

Implemented: in-process SSH/CONNECT, pinned SSH host key, QR pairing, Keychain enrollment, native foreground UI, Kernel orchestration, screenshot polling, and recovery-aware cleanup. Local Go race tests, simulator bridge/API/cleanup tests, and an iPhone-target build pass. Live relay tests verified enrollment, same-key retries, and rejection of another device using the same code; the disposable test tenant was revoked.

**A foreground end-to-end run was user-confirmed on an iPhone Air on September 16, 2026.** This is an initial demo result, not a completed network/lifecycle test matrix. Cellular/NAT64, force-quit, background/lock behavior, and repeated start/stop cycles still require explicit testing. A simulator uses the Mac's connection and is not proof of iPhone egress.

The existing test-host allowlist, private-destination blocking, and 32 active CONNECT streams remain. This is not general browsing or background egress. The literal IPv4 relay and Go resolver need real IPv6-only/NAT64 testing. The [Kernel relay-certificate verification caveat](../README.md#limits) also remains.

[Foreground plan](ios-foreground-plan.md) · [Background follow-up](ios-background-follow-up.md)
