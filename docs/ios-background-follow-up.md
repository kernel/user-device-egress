# iOS background egress: follow-up experiment

Status: planned follow-up; an initial [foreground routing demo](ios-foreground-plan.md) is now user-confirmed on iPhone Air. Research checked September 16, 2026. No background implementation or approval is claimed.

## Product hypothesis

The user starts a specific agent task using their phone's connection, then can switch apps or lock the phone while it runs. Requiring them to watch a foreground app is not the product path. Indefinite, unattended bandwidth sharing is also not the initial promise.

Investigate `BGContinuedProcessingTask` on iOS 26+, using the same in-process networking core as the foreground demo.

## What the research establishes

- Apple permits user-initiated foreground work to continue in the background, including networking. This is not an API reserved exclusively for CPU-heavy processing. [Long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [default CPU/network resources](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequestresources/bgcontinuedprocessingtaskrequestresourcesdefault).
- The task has system-visible progress and cancellation. It can expire under resource pressure, and lack of progress makes it vulnerable to termination. No guaranteed runtime follows from API availability. [Task documentation](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask).
- Apple describes explicit user initiation, meaningful progress, completion, expiration handling, and a fail-immediately submission option. [WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/227/). These APIs are also present in the locally installed iOS 26.5 SDK headers; that confirms API availability, not suitability for our workload.
- A Network Extension is not our fallback keepalive mechanism: Apple lists proxy-server hosting as an unsupported packet-tunnel use. [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers).

**Unproven inference:** facilitating a finite cloud-agent task may fit continued processing. Neither networking permission nor a successful prototype proves that Apple accepts reverse egress as the primary task. Ask Apple Developer Technical Support about this precise architecture and seek review feedback before promising distribution.

## Experiment design

### 1. Define a finite, measurable job

Start with a user-triggered network diagnostic: a fixed number of actual Kernel-browser requests through the phone, with a real end result. Then test an agent-like workload containing both bursts of requests and waiting periods.

Report completed work, not elapsed time disguised as progress. Proxy bytes are telemetry, not automatically meaningful progress toward an agent goal. Do not generate meaningless traffic, fake progress, play silent audio, or repeatedly resubmit tasks to manufacture indefinite runtime.

A later real agent integration needs an authenticated, session-scoped way to deliver task milestones and completion to the phone. Plan that control channel explicitly; the existing byte-forwarding tunnel does not convey agent progress. Do not put an account-wide Kernel API key on the phone.

### 2. Connect the task lifecycle to the session

Register a permitted task identifier and submit only from an explicit foreground action. Verify required target capabilities and identifier behavior against the selected SDK. Use `.fail` initially so an unavailable task does not start unexpectedly later. Use default CPU/network resources; do not request GPU access.

Let the task handler own the session. Update real progress and stop on completion, user cancellation, or expiration. Make shutdown idempotent and promptly close the SSH connection and all destination streams. Report task completion once. Denied submission leaves sharing off and displays the reason; it must not silently fall back to foreground-only operation.

Review Keychain accessibility and test lock/unlock behavior explicitly. Avoid assuming that a key readable while unlocked can be fetched again after lock. Do not weaken storage protection merely to make a demo survive.

### 3. Measure suspension and cancellation honestly

Use a physical iPhone, launched without a debugger. Compare the same workload with and without a continued-processing task. Repeat at least three times per baseline condition; record exact device/OS, battery/charging state, request outcomes, progress events, task expiration, memory, and disconnect latency.

| Condition | What to learn |
| --- | --- |
| Foreground → another app; separately foreground → lock | Whether real requests continue, not merely whether a timer or UI says the task is running. |
| Finite jobs targeting roughly 1, 5, and 15 minutes | Observed completion and termination behavior; these are test lengths, not promised execution budgets. |
| Bursty work with 30–120 second idle gaps | Whether realistic agent waiting causes progress-related expiration. |
| Cellular/Wi-Fi; battery/charging; Low Power Mode | Which resource and network conditions change outcomes. |
| System UI cancellation, force-quit, airplane mode | Whether forwarding stops and the remote workflow notices promptly. |

Track the prototype's existing two-minute CONNECT lifetime separately. Open fresh test connections as needed; a per-connection timeout is not evidence that iOS expired the task. Test active streams as well as fresh requests.

### 4. Add a remote stop boundary before productizing

Do not rely exclusively on the phone receiving an expiration callback: it may be suspended or killed. Specify a bounded, session-scoped lease enforced outside the phone before any broader trial. On lease loss, close existing forwarding streams, reject new ones, and pause or terminate the cloud job. This requires additional relay/control-plane work; it is not a property of the current relay.

Treat the lease as a safety mechanism, not manufactured task progress. Never remove a proxy from a still-running browser as a way to stop traffic: that can enable direct egress. Test that app resumption cannot replay stale queued work after cancellation, and require explicit restart after a failed session.

## Decision gate

Proceed only if representative finite jobs complete repeatedly in the required background states, failure is visible and bounded, and progress represents genuine work. A diagnostic benchmark passing is not enough to claim agent-workflow reliability or App Store acceptance.

If the design works only under a debugger, needs fabricated progress, or repeatedly dies during normal agent waiting, record that outcome and reassess. Do not replace the intended product with a mandatory foreground viewing experience.

Estimate: 2–3 engineering days for the API harness and initial measurements after foreground routing works. Broader device testing, an external lease/control channel, and distribution review are separate work.
