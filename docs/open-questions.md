# Discussion agenda

## Confirmed direction

The Operator Agent is first, ARTEMIS support second. Support variable Apple Foundation Models-capable Macs such as M2 devices. Use Apple's cloud inference when supported. Continue documentation and discussion before implementation.

## Remaining strategy decisions

| Question | Recommendation | Why it matters |
| --- | --- | --- |
| Is this a personal utility or an app intended for distribution? | Start with a signed personal utility; treat PCC as conditional until app eligibility is established | Managed PCC entitlement/distribution rules can prevent a generic CLI from using cloud inference |
| Is zero database a firm constraint? | Use embedded SQLite for durable state | File-only approval recovery is possible but adds protocol and failure-testing work |
| What should the Operator first explain or improve? | Provider availability, request deferral, memory cost, and a concrete optimization proposal | Gives the first consumer a small measurable success boundary |
| Which M2/RAM/OS combinations are first supported? | Apple-provider baseline first; owned-worker tiers only after measurement | M2 eligibility does not guarantee 9B or emulator capacity |
| What should happen if current ARTEMIS cannot run fully local through configuration? | Keep the no-source-change constraint visible, document unsupported paths, and evaluate a later upstream revision | Avoids promising offline behavior the consumer does not provide |
| Which ARTEMIS test environment is representative? | One physical test device or controlled emulator, test accounts and harmless tasks | Device actions and emulator overhead are outside pure inference benchmarks |
| Which data may the Apple-cloud policy disclose? | Per-consumer/session opt-in with bounded allowed input classes | Operator telemetry and Android screenshots have different privacy implications |

## Recommendations worth discussing

1. Start the Operator on Apple Foundation Models rather than making a third-party 9B model mandatory.
2. Keep resource/security policy deterministic; the Operator explains and proposes.
3. Make ARTEMIS support a source-verified compatibility milestone. Separate its profiles, gateway protocol, OCR, and cloud routes.
4. Preserve both local-only and explicitly enabled Apple-cloud modes. Do not claim 100% on-device operation when cloud is used.
5. Defer training until the serving workloads establish a repeated task and measurable benefit.

Detailed UI layout, WebSocket frames, training directory mounts, and automatic model promotion can wait until these strategy choices are settled. No unanswered question grants implementation approval.
