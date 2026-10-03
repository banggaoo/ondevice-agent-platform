# Discussion agenda

## Confirmed direction

The deterministic serving core is the platform's center; the Operator Agent is an optional consumer and ARTEMIS is an external consumer. Trying Apple Foundation Models first is confirmed experiment direction, not a universal provider default; its suitability and limits remain unmeasured. Support variable Apple Foundation Models-capable Macs such as M2 devices, adapted to each user's device capability rather than one prescribed host. Continue documentation and discussion before implementation.

Firm choices recorded 2026-10-03 from the answers below:

- Audience and goals: the platform is intended for engineers broadly; local, free-to-use, and performant operation are product goals, not measured results, an established license, or distribution authorization.
- Optional Operator stage order: runtime management first, then project/codebase/data, then training, then distribution, then improvement. These are optional consumer stages, not core milestones; each later stage needs its own capability, executor, and data design.
- Runtime data root: `~/.ondevice-agent-platform/`, with per-session folders created only when needed.
- ACP is the default agent-facing protocol per the 2026-10-04 instruction below; the recorded answer still means no mandatory editor adapter, only that the protocol is no longer deferred.
- Storage: embedded SQLite is the confirmed engine; schema, transition protocol, logging, and retention remain proposed.
- OS baseline: macOS 27+ is the accepted sole initial product baseline.
- Delivery: a GitHub-downloadable repository/executable; the per-user executable starts a local server and console. No license, release format, signing, or publication is approved.
- ARTEMIS direction and scope: ARTEMIS is the inference consumer and the platform is the provider - never an automation backend. Serving scope is a tested OpenAI-compatible subset, not exhaustive Android/iOS consumer QA; iOS support is unverified at the pinned revision. Permitted internals may be Apple on-device inference, eligible Apple PCC, an owned local model, or bounded harness/agent orchestration.
- Apple cloud use is accepted conditionally on privacy preservation. Apple's PCC privacy design is now supported by Apple's published security documentation checked 2026-10-03 (stateless processing, no retained user data after response, verifiable transparency); entitlement access under the chosen delivery remains a separate, unestablished gate.

The six prior recommendations were acknowledged (marked OK below); these acknowledgements are historical and superseded wherever the latest correction changes their assumptions: Apple-first Operator, deterministic policy, source-verified ARTEMIS integration, separate local-only/Apple-cloud modes, training deferred until evidence, and the harness contract before prompts or workers.

## Core scope correction (2026-10-03)

The latest clarification supersedes the earlier Operator-first interpretation. Verbatim excerpts from the user:

> ondevice-agent-platform is serving agent and llm, operator agent is optional, basic program should run by 100% codebase. you know harness is not 100% llm driven. operator agent use llm to use openai llm serving protocol, so operator agent is consumer, like artemis. system should well design like using layer and tier, component, seperation of concern. each agent have own harness, and this can be changed due to improvement or spec changes. you ask to use apple foundation model, but ondevice-agent-platform should consider open source model also, since apple model cannot cover all requirement. and some of model is better and apple's, i mentioned qwen 3.8 and apple model is different purpose.

> The brief verdict is that Qwen 3.8 9B is significantly better for raw intelligence, deep reasoning, mathematics, and complex coding. However, the macOS 27 Apple Foundation Model is much better for speed, battery efficiency, and executing system-level automations directly on your Mac. deliver model or agent by purpose is important.

The comparative verdict is recorded as the user's stated purpose hypothesis, not a measured result - no checked source supplies a matched Apple macOS 27 versus Qwen 9B quality, latency, or battery comparison. Any Operator-first or Apple-default wording in the recorded answers below is historical where this correction supersedes it.

## Default protocols and ML scope (2026-10-04)

The latest instruction supersedes the earlier deferral of agent-serving protocol work. Verbatim:

> agent protocol and openai protocol is default, agent should also serving, operator agent is agent that should use agent protocol. open source llm and ml support also default

ACP agent serving and the OpenAI-compatible LLM interface are baseline facilities, with the Operator as one optional served agent reached through ACP. Open-source/open-weight LLM support and typed non-generative ML inference are default supported categories, not extensions. Installed agents and model artifacts remain optional; a baseline facility exists and fails truthfully when its registry is empty or providers are unavailable, and default support does not mean all models or runtimes are installed or verified.

## Recorded discussion answers (2026-10-03)

The user's Answer column was supplied directly and is preserved verbatim. The Prior recommendation column is historical advice, superseded wherever an answer settles the question. Answers record user intention; unsettled items remain our proposals; neither is verified evidence.

| Question | Prior recommendation | Why it matters | Answer |
| --- | --- | --- | --- |
| Is this a personal utility or an app intended for distribution? | Start with a signed personal utility; treat PCC as conditional until app eligibility is established | Managed PCC entitlement/distribution rules can prevent a generic CLI from using cloud inference | ondevice-agent-platform is for all engineers who want to use agent with locally, free and performant |
| Is zero database a firm constraint? | Use embedded SQLite for durable state | File-only approval recovery is possible but adds protocol and failure-testing work | using sqlite is matter of choice, not constraint. consider as agent manage this project |
| What should the Operator first explain or improve? | Provider availability, request deferral, memory cost, and a concrete optimization proposal | Gives the first consumer a small measurable success boundary | Operator should manage runtime first, then manage project, codebase, data, then manage training, then manage distribution, then manage improvement |
| Which M2/RAM configurations are first supported on the proposed macOS 27+ baseline? | Apple-provider baseline first; owned-worker tiers only after measurement | M2 eligibility does not guarantee 9B or emulator capacity | device which using ondevice-agent-platform is very, since macos support unified memory we should provide based on user's device capability |
| Where should runtime data live? | Resolve the Foundation application-support directory; keep the home dotfolder as an explicit unsandboxed developer option | Directory placement is organization, not process confinement; root selection is still a discussion decision | in user's .ondevice-agent-platform directory, like .claude code did, and we can create each session folder if needed, if simple task we might not need session folder |
| When should an ACP editor adapter be considered? | Later, after a named compatible editor and a demonstrated benefit over the console | It is a separate session projection of the harness, not a first-product blocker or a universal OpenAI translator | self improvement is provided by operator agent, so we don't need editor adapter for now, since we can conversatoin with operator agent, we can improve ourself also |
| What should happen if current ARTEMIS cannot run fully local through configuration? | Keep the no-source-change constraint visible, document unsupported paths, and evaluate a later upstream revision | Avoids promising offline behavior the consumer does not provide | since ARTEMIS support openai protocol, ondevice-agent-platform should support openai protocol, which means we can use ARTEMIS as backend for ondevice-agent-platform |
| Which ARTEMIS test environment is representative? | One physical test device or controlled emulator, test accounts and harmless tasks | Device actions and emulator overhead are outside pure inference benchmarks | we will test artemis on android and ios, but not necessary fully tested because we are working on ondevice-agent-platform first, if agent or llm serve for ARTEMIS, our role is enough |
| Which data may the Apple-cloud policy disclose? | Per-consumer/session opt-in with bounded allowed input classes | Operator telemetry and Android screenshots have different privacy implications | if apple cloud is not leak our data, it is okay to use our data |

## Recommendations accepted on 2026-10-03

1. Start the Operator on Apple Foundation Models rather than making a third-party 9B model mandatory. OK
2. Keep resource/security policy deterministic; the Operator explains and proposes. OK
3. Make ARTEMIS support a source-verified compatibility milestone. Separate its profiles, gateway protocol, OCR, and cloud routes. OK
4. Preserve both local-only and explicitly enabled Apple-cloud modes. Do not claim 100% on-device operation when cloud is used. OK
5. Defer training until the serving workloads establish a repeated task and measurable benefit. OK
6. Settle the [harness contract](harness-contract.md) and the first bounded task before prompt configuration or training workers. OK

## Recorded follow-up answers (2026-10-03)

The following entries retain the earlier prompts and the user's appended responses verbatim. Their old "open"/"proposed" wording is historical; the current confirmed choices are summarized above.

1. ARTEMIS direction: the audited default treats ARTEMIS as an inference consumer of the platform gateway; the "ARTEMIS as backend" wording may instead mean a separate automation backend the platform invokes. Recorded open (D29); not silently selected. artemis is consumer, ondevice-agent-platform is provider, we do not build automation backend for artemis, only provide llm inference service, inside of llm provider we can use apple cloud or local model, or harness or agent, we just provide the interface.
2. Apple-cloud privacy: the conditional acceptance still needs provider-property verification plus permitted payload classes, redaction, and revocation - an intention, not verified evidence. i ask about apple cloud and Yes, Apple's cloud foundation models strictly protect user privacy through a specialized architecture called Private Cloud Compute (PCC).
3. Distribution packaging, signing, license, and PCC entitlement feasibility for the engineer-wide audience. we use github, customer download repo and run executable, once local server is running user can use server and console.
4. Storage selection: SQLite is our proposed default, not a user-confirmed choice; calibrated device/RAM profiles are likewise unmeasured. you can use sqlite.
5. macOS 27+ support policy remains a separate proposal awaiting acceptance (D19). you can use macos 27+.

## Recorded engineering replies (2026-10-03)

The following entries retain the earlier engineering-check prompts and the user's appended replies verbatim. Prompt wording predates the current direction; the summary above states the confirmed choices.

1. Signing, notarization, build, release format, and license for the GitHub-downloadable executable. follow common ai project standards.
2. PCC entitlement and permitted consumer-gateway use under the chosen distribution mode; the user's privacy acceptance does not establish app eligibility. why need entitlement since we are not distributing through app store? this project is ondevice agent platform, not a standalone app. and agreement should include we are not responsible for any misuse of the platform.
3. The safe cloud payload policy: permitted payload classes, redaction, revocation, and provenance per consumer/session. apple cloud said they are safe, no need to worry about this.
4. Calibration of device/RAM profiles, provider availability, context limits, and budgets on the accepted macOS 27+ baseline, including M2-class devices. calibration is based on knowledge from internet we can search.
5. Pinned-revision compatibility testing and offline-route verification for the declared ARTEMIS serving subset. we will test this.

## Engineering direction and evidence

Current position after the recorded engineering replies and the lead's 2026-10-03 primary-source checks:

- PCC privacy: Apple's published PCC security design (stateless processing, no retained user data after the response, verifiable transparency) supports the user's acceptance. It is Apple's design, not this project's proof, and it does not cover this platform's own logging or disclosure discipline.
- PCC access: published rules require App Store Small Business Program enrollment, fewer than two million first-time App Store downloads, and an assigned entitlement; they describe App Store production use and TestFlight/ad hoc testing. No established public GitHub-executable route is documented, but no categorical CLI ban is claimed either. Local-only Apple inference does not depend on PCC.
- License and release: standard MIT and Developer ID signing/notarization are recommendations (D34), not a selected license or an authorized release.
- Device/provider profiles: public research may seed starting profiles (D35); they are estimates until validated by native observations and bounded measurements.
- ARTEMIS: pinned serving/compatibility tests are planned (D36), not executed; configuration-only offline coverage remains unproven.

See [distribution and responsible use](distribution-and-responsible-use.md) and the [source notes](references/sources.md) for the dated checks and recommendations.

Detailed UI layout, WebSocket frames, training directory mounts, and automatic model promotion can wait until these strategy choices are settled. No unanswered question grants implementation approval.
