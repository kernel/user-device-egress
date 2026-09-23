# iPhone background egress: initial results

**A Kernel cloud browser used a locked iPhone's internet connection for five-minute diagnostics on Wi-Fi and cellular.** A separate run resumed after a 60-second pause in browser work. The cellular baseline without continued processing had no successful background requests.

## Measured results

September 17, 2026 · iPhone Air · iOS 26.6.1 · one run per condition · Low Power Mode off.

| Mode | Network / workload | Matching-IP requests | Fully backgrounded successes |
| --- | --- | ---: | ---: |
| Continued processing | Wi-Fi, ~5 minutes | 60/60 | 58 |
| No-task baseline | Cellular, 60-request target | 1/52 attempted | 0 |
| Continued processing | Cellular, ~5 minutes | 60/60 | 58 |
| Continued processing | Cellular, 60-second pause | 12/12 | 10 |

The cellular five-minute tests used the same phone, OS, reported network type, and 50% starting battery. The baseline's first post-background request timed out; every later attempt failed. Its seven-minute diagnostic deadline prevented the final eight attempts.

The bursty run had a 65-second request gap: the deliberate pause plus the normal five-second interval. All eight requests after the gap succeeded. Continued-processing runs completed cleanup while backgrounded; baseline cleanup completed after reopening. No expiration/cancellation was logged in the successful runs.

## Interpretation

These observations support **finite, user-initiated background egress on this device**, not guaranteed runtime or general agent reliability. The comparison is supportive evidence, not a randomized or repeated trial.

Requests are measured in the cloud, independently of phone polling. Background counts include clock uncertainty and a two-second boundary guard. Protected-data events support the operator's lock-screen observations. During the pause, phone polling and tunnel health checks continued: this was **paused browser work, not complete network inactivity**.

Other devices/carriers, cancellation under failure, longer idle periods, battery impact, general browsing, checkout improvements, and App Store acceptance remain untested. [Next steps](ios-background-follow-up.md).

<details>
<summary>Source reports</summary>

Aggregated from operator-provided exports. Personal IPs and raw exports are not included in this repository.

- Wi-Fi: `47528888-00ed-490d-9c75-41236383fa6e`
- Cellular baseline: `193a471d-ab85-499f-87b2-9a5561b355cc`
- Cellular continued: `8ba13d03-6032-4aaf-bc7e-17f939ac0ad9`
- Cellular pause: `f5b559ed-4076-4a7b-8ab0-c6fd9f2650ff`

</details>

[Run the demo](ios-background-demo.md) · [Apple API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
