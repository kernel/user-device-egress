# iPhone background demo

Run a finite cloud-browser diagnostic through a locked iPhone using `BGContinuedProcessingTask`, or compare it with a no-task baseline. [Measured results](ios-background-results.md).

## Set up once

Requires a [provisioned relay](../README.md#1-create-a-relay), Xcode 26.5+, a physical iPhone compatible with the project's deployment target, and a dedicated demo Kernel API key. Run commands from the repository root.

1. Run `./scripts/build-ios-core.sh`. Open `iOSEgressBackground/iOSEgressBackground.xcodeproj`, choose your signing team and iPhone, and run.
2. Have the relay operator [enable pairing and issue a fresh QR](../DEVELOPMENT.md#device-pairing). In the app, choose **Setup → Scan pairing code**, confirm, and save the Kernel key. This app has its own device key; the foreground app's used QR will not work.
3. Stop the Xcode run. Open **Egress Background Lab from the Home Screen**. Starting under a debugger or in a simulator is intentionally blocked.

Pairing codes expire after ten minutes. The project already declares background processing; no VPN or GPU entitlement is needed. QR pairing and a phone-held Kernel key are developer-only setup, not the proposed consumer experience.

## Run the comparison

1. Choose **Continued processing → 60 requests**, enable consent, and start. Resources are temporary but billable.
2. Wait for **“Running — you can leave the app”**, lock the phone for six minutes, then return.
3. Wait for cleanup and **Export experiment report**.
4. Repeat with **Baseline (no background task)** on the same network and under the same power conditions.

For waiting between bursts, choose the workload with a **60-second pause** and lock for three minutes. Keep Kernel live view closed. Failed requests can extend the nominal workload duration; return within eight minutes, then let the run finish or stop it explicitly.

A pass means matching-IP requests completed while backgrounded—not just a running timer. **Wholly in background** includes clock uncertainty and a two-second guard at each edge. Reports contain public IPs and device/network observations; review before sharing.

## Cleanup

Stop, detected network changes, and system expiration/cancellation close forwarding. The app deletes the browser **before** its proxy. If interrupted, reopen and tap **Retry cloud cleanup**. For an unknown creation outcome, inspect the displayed run name in Kernel; never delete its proxy before confirming browser deletion.

Force-quit or suspension can delay cleanup. Phone-side deadlines are not a server-enforced lease. See [technical notes](../DEVELOPMENT.md#background-lab-internals) and [remaining work](ios-background-follow-up.md).
