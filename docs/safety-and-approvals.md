# Safety, approvals, and data handling

Status: proposed strategy for discussion. This document defines intended behavior and validation gates; it does not establish that any runtime, sandbox, approval service, or storage mechanism already exists.

## MVP authority

The first consumer is the platform's own Operator Agent: explain approved telemetry, runtime status, and the platform's own registry/configuration snapshots, then produce reviewable operational or optimization proposals. The supervisor reads an explicit allowlist of its own records and supplies bounded inputs to inference. Use synthetic or public fixtures until the private-data boundary checks for the chosen provider topology pass. The Operator should not execute a shell, run generated code, edit its registry or configuration, change a repository, train a model, install a tool, discover models online, or dispatch work automatically to an external executor.

The proposed Swift supervisor owns admission control, policy decisions, user sessions, and proposal persistence. A trusted native adapter calls Apple Foundation Models in process with broker-supplied data; XPC separation is an alternative to evaluate. An optional owned-model worker is a separate restricted process, permitted only allowlisted runtime/model artifacts and broker-supplied inputs, with no direct grant to private platform state or consumer traces. In-process native code shares the application permissions; do not claim it has the same OS isolation as a restricted process. The broker validates output and creates a proposal; the model does not write authoritative records or select storage paths. Choosing a different or larger model changes inference behavior, not its authority.

Read-only status access is itself a permission. Record which telemetry fields, registry/configuration records, task summaries, and consumer-provided inputs the supervisor may read and which may reach a model. A model should not enlarge that scope, search the home directory, or request raw private traces simply because input contains instructions to do so. Files, tool results, model prose, and imported review reports are data, not authorization.

| Component | Proposed authority | Excluded from the MVP |
| --- | --- | --- |
| Web console | Display findings and submit explicit user decisions | Implicit approval through ordinary chat text |
| Swift supervisor/broker | Read allowlisted platform status; enforce validated requests; maintain bounded records; control its own worker | Arbitrary commands, privilege escalation, registry/configuration changes driven by the model |
| Native adapter / optional owned-model worker | Infer on broker-supplied input through the approved provider and return candidate output | Model-directed state/trace discovery, policy edits, credentials, arbitrary networking |
| Proposal renderer | Display validated records and safe text | Executing Markdown, HTML, links, or code blocks |
| Human or external reviewer | Review a manually exported, previewed package | Inheriting application authority from model status or review quality |

The user may stop work and revoke an input scope or provider session. Stop cancels queued work and requests cancellation of active inference; the exact worker termination behavior and recovery guarantees must be established during a later spike. Revocation prevents new disclosure; it cannot recall an already submitted inference payload.

## Second consumer: ARTEMIS inference gateway

The second consumer is Google's ARTEMIS, connected through a bounded inference gateway after the Operator validates the serving lifecycle. The gateway authenticates the consumer, validates request scope and size, applies resource admission and provider/disclosure policy, and returns model output. It does not assume the role of an Android device permission manager or executor.

ARTEMIS may use model suggestions to drive device actions. Therefore inference-only integration does not make its downstream effects read-only or safe. Device permissions, action validation, account access, and confirmation for consequential actions remain within ARTEMIS and its test setup. Begin with an emulator or an explicitly selected test device and test account with narrow permissions; use synthetic/public task fixtures until the private-data gate passes. Device state or screenshots may contain sensitive information and require an explicit input/disclosure policy even when the platform never calls a device action directly.

The gateway receives only the selected request payload. It does not grant the inference worker access to ARTEMIS trace folders, device credentials, or the platform's private history. A response marked valid means its schema passed, not that the suggested action is authorized or correct. Cross-consumer data, sessions, proposal evidence, and retained traces require separation and explicit sharing rather than an implicit common history.

## Foundation Models and optional Apple cloud inference

Apple Foundation Models on-device inference is the proposed default on capable, available Macs. Eligibility is detected at runtime; an M2 label alone does not establish OS, model availability, or language/task support. A missing provider yields an explicit unavailable/deferred result instead of silently selecting another provider. Consult [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels) and the project's verified capability matrix for the supported OS/SDK/device combinations.

Optional Apple Private Cloud Compute inference may be enabled only when the public API, OS/SDK availability, entitlement, service quota, and runtime conditions permit it. [Apple PrivateCloudComputeLanguageModel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel) is the API verification reference; this strategy does not assume all Foundation Models-capable Macs or deployment targets can use it. Approved cloud inference produces suggestions; it does not apply proposals or grant an external executor authority.

The user's permission to use a supported Apple cloud capability allows designing that route. The running product must still establish an explicit disclosure policy before sending live data: permitted consumers/task classes, selected payload fields, redaction rules, destination/provider, time or session boundary, request/resource limits, revocation behavior, and whether eligible requests may be routed automatically within that approved scope. The policy may authorize repeated requests for a bounded session; it need not ask again for every request. Record its version and consent, and show the selected provider for each job. Changing the payload class, provider, consumer scope, or session limits requires renewed consent.

On-device failure does not imply cloud consent. Decline, expired consent, unavailable entitlement/service, or exhausted quota produces an explicit result or approved local retry. Cloud use must not include raw private traces, device screenshots, or other consumer data outside its reviewed policy. Provider privacy properties do not eliminate the need to control what is disclosed. Generic outbound requests and automatic external frontier-model execution remain excluded.

## Process and filesystem boundaries

A separate same-user subprocess is a useful failure and lifecycle boundary. It is not, by itself, a security boundary against a compromised worker. POSIX ownership, a restricted tool list, and a directory named `workspace` do not prevent that process from accessing other resources available to the user.

Before implementation, document the candidate provider topology and which components are trusted native code versus restricted workers. Before private live use, verify the supervisor read allowlist, broker-supplied inputs, model-directed write denial, safe output handling, cancellation, and approved disclosure routes. For an optional owned-model process, additionally demonstrate actual OS restrictions: allowlisted runtime/model reads, denied direct private-state/trace reads, denied writes/network/child-action capabilities, path escape handling, and restart recovery. An in-process native adapter shares supervisor authority; it must not execute model output, and that topology must not be described as worker isolation. Verify local-only inference egress and approved Apple-cloud routes at the applicable boundary; neither permits arbitrary worker networking. If required restrictions cannot be demonstrated, revise the topology or retain synthetic/public-only scope.

Apple describes XPC as supporting privilege isolation across process boundaries. Its App Sandbox guidance distinguishes inherited child-process restrictions from separate XPC privilege separation. Whether a signed, sandboxed native worker can host the chosen inference runtime with the required entitlements remains an explicit feasibility question. Sources: [Apple XPC](https://developer.apple.com/documentation/XPC), [Apple App Sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

`~/Library/Application Support/ondevice-agent-platform/` is a proposed support-data location for an unsandboxed per-user application. It is not the native App Sandbox merely because it is under `Library`. Resolve support and cache locations with Foundation APIs rather than hardcoding a container path. Apple documents different support-directory locations for sandboxed and unsandboxed applications and creates App Sandbox containers under `~/Library/Containers`. Sources: [Apple applicationSupportDirectory](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory), [Apple App Sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

No root service, Full Disk Access, or broad home-directory access is proposed. If the eventual app adopts App Sandbox, persistent user-selected access may require security-scoped bookmarks and balanced access lifetimes; this must be verified for the selected process topology. A browser button selecting a path is not evidence that macOS granted an OS sandbox extension.

## Local web console

The proposed console uses one loopback origin for its UI and HTTP API, with Server-Sent Events (SSE) for status updates. Mutation requests use HTTP; SSE only delivers events. A fixed public port is unnecessary. Loopback binding reduces exposure but does not authenticate a browser or another local process.

Required controls before a live console is admitted:

- Bind only to the intended IPv4/IPv6 loopback interfaces; reject unexpected exact `Host` values and cross-origin mutation requests.
- Establish a user session; require authentication and action-level authorization. Use explicit Origin checks and CSRF protection for mutations; deny permissive cross-origin access.
- Authenticate SSE subscriptions; avoid session secrets in URLs or logs. Expiry/logout invalidates event subscriptions.
- Validate request schemas and enforce payload, connection, queue, and rate limits.
- Escape output and render Markdown with executable HTML and remote embeds disabled. Treat imported proposal text as untrusted.

These controls follow [OWASP CSRF prevention](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) and [OWASP HTML5 security guidance](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html). Session bootstrap and native-to-browser credential transfer remain design decisions for the implementation spike. They must not rely on a token exposed in browser history, process arguments, or logs.

The History view requests bounded, redacted records through an authenticated API. It does not read arbitrary local files or expose the support-data directory as a static website. Connection success is not permission to approve a proposal. If WebSockets are introduced later, they require authenticated handshakes, exact Origin validation, and message-level authorization; see [OWASP WebSocket security](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html).

## Authoritative proposal and decision records

SQLite is proposed as the local authoritative store for jobs, proposal versions, decisions, and state transitions. This is an embedded database, not an external service. Human-readable Markdown is an export/view of that state. A mutable Markdown file and a `user_approved` boolean are insufficient authority for durable decisions. SQLite transactions provide a practical basis for atomic local record changes, subject to correct configuration and filesystem assumptions; see [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html).

The broker generates proposal and operation identifiers. It validates the structured payload, bounds content sizes, assigns a version, and calculates a SHA-256 digest over a documented canonical representation. The digest identifies reviewed content; it is not proof of provenance or reviewer trust. Proposal records include:

- Proposal ID, version, creation and expiry timestamps, canonical payload digest, and originating job ID.
- Consumer and task identities, approved input scope/snapshot digest, telemetry observation window, and relevant registry/configuration digests. Include a repository/base revision and dirty-input digest only when the proposal concerns a code change; a commit ID alone is not a complete dirty-worktree baseline.
- Selected provider, model/runtime identity exposed by that provider, and local artifact digest where applicable. Record unavailable identities rather than inventing a stable digest for an Apple-managed model.
- Cloud session/disclosure policy identity, if used, without storing session credentials in proposal content.
- Proposed actions and affected targets, evidence, expected effects, risks, verification criteria, and rollback approach.
- Separate plan-review and export-consent records, including the user-session identity, decision time, scope, and reviewed digest.
- Any imported application outcome, its source, and independently verified evidence.

Versions are immutable in the application workflow. Editing a proposed action, export selection, or consequential precondition creates a new version requiring fresh review. Recheck the current consumer/task input and registry/configuration baseline before export or any future application step. A changed consequential input/configuration, stale code revision where relevant, revoked scope, or expired proposal invalidates the earlier authorization for that action. This does not imply that locally stored records are tamper-proof against the account owner or compromised supervisor.

## Proposed lifecycle

| State | Meaning | Allowed next states |
| --- | --- | --- |
| `draft` | Candidate not yet presented for a decision | `pending_review`, `cancelled`, `expired` |
| `pending_review` | Immutable version awaiting explicit plan review | `accepted_for_manual_action`, `rejected`, `expired`, `superseded`, `cancelled` |
| `accepted_for_manual_action` | The user accepted this proposal version; no mutation is authorized through the platform | `superseded`, `expired`, `cancelled`, `closed`; separately consented export |
| `rejected`, `expired`, `superseded`, `cancelled`, `closed` | This version cannot proceed; record a closure timestamp and reason | A new proposal version may be created |

Export and application evidence are recorded separately rather than turning plan acceptance into execution:

| Record | Meaning |
| --- | --- |
| `export_consented` | The user saw the exact package and approved its selected destination/disclosure |
| `exported` | The package was produced for manual transfer; this does not establish that anyone applied it |
| `user_reported_applied` | A human imported an outcome; the claim has not yet been independently checked |
| `verified` / `verification_failed` / `unverified` | The observed evidence against the proposal's explicit verification criteria |

The platform must not label a task complete merely because it exported a package, sent a notification, or received an external model's assertion. Since application is outside the MVP, there is no automatic apply permission or apply endpoint. Any future executor needs its own concrete scope, exact artifact, fresh preconditions, explicit application authorization, and recovery design.

Persist a decision and its state transition transactionally. A repeated decision request must not create a second transition; bind it to the proposal ID, version, digest, expected current state, and unique operation ID. On restart, recover the stored state without interpreting a disconnected UI as acceptance. Pending review releases inference resources; it does not hold a generation worker or an in-memory thread indefinitely.

There is no claim of exactly-once external effects. A future executor must record intent, use idempotency where possible, and reconcile uncertain outcomes after crashes before retrying writes.

## Manual export and disclosure

Preview the exact files and text to be exported, destination, omitted material, and any detected sensitive content before obtaining export consent. Export only the chosen version and selected supporting evidence. Redaction is a helpful check, not a guarantee that private information was removed. Raw traces, the entire repository, credentials, and unrelated file paths are not automatically included.

MVP export creates a local review package for manual transfer. No automatic external executor API dispatch, model discovery, automatic upgrade, or remote executor integration is included. The separately enabled Apple cloud-inference route follows its own disclosure/session policy and does not replace manual proposal-export consent. External reviewers' findings and generated patches re-enter as untrusted material. Credentials for a later integration would use an appropriate secret store such as Keychain, not proposal/configuration/log files; see [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services/).

## Retention, deletion, and training

These are adjustable proposed defaults, with visible usage and explicit user-controlled pins. A pin exempts an item from age-based cleanup but still consumes the quota; storage exhaustion pauses capture/new content and prompts a user choice rather than growing without bound or silently deleting pinned material.

| Data class | Capture default | Proposed retention | Proposed quota |
| --- | --- | --- | --- |
| Raw diagnostic prompts, outputs, or traces | Off; explicit opt-in after the private-data feasibility gate | 7 days from capture time | 25 MiB |
| Structured resource/task metrics | On for approved jobs; exclude content and credentials | 14 days from observation/event time | 100 MiB |
| Closed proposal bodies and associated audit/decision records | On for reviewed proposals | 30 days from the recorded closure time | 100 MiB combined |
| Pending proposal payload | Only explicit analysis output | Version expires 7 days from creation; closed retention then starts | Shares proposal quota |
| Training capture and datasets | Off | No automatic dataset creation | Not part of MVP |

Every immutable proposal version has `expires_at = created_at + 7 days`. Acceptance or export does not extend it. `closed_at` is the first terminal rejection, cancellation, supersession, scheduled expiry, or explicit `closed` transition for a manually verified/abandoned outcome. If expiry is detected after sleep/restart, use the original scheduled expiry time as `closed_at`, not the time the app woke. Delete unpinned closed-version content and associated decisions at `closed_at + 30 days`. Thus an untouched pending proposal normally remains at most 37 days from creation, including its closed retention period. An audit event without an associated proposal uses its own event time plus 30 days. A new proposal version or explicit pin must not silently reset an older version's clock.

Deleting an owned proposal deletes its associated stored content, diagnostic attachments, and owned export copies selected for deletion. Cleanup must account for database journals/WAL and application-created temporary copies. Minimal deletion metadata, if retained, must be described and content-free. Logical deletion is not a promise of forensic erasure from SSDs, system backups, or packages a user transferred elsewhere.

Do not use diagnostic traces as training data by default. Any later training experiment needs a separately approved dataset, provenance, license/consent review, evaluation set, retention/deletion treatment for derived artifacts, and a manual promotion decision. Rejecting a proposal is not permission to learn from its private content.

## What the original sample fails to establish

The original proposal is useful as a statement of intent, but its sample must not be treated as a working safety implementation:

1. Task-name substrings decide significance; effects and capabilities do not. Unrecognized tasks reach a direct-tool branch.
2. `user_approved` is mutable graph state, with no demonstrated authenticated user decision, reviewed version, digest, expiry, or replay prevention.
3. When approval is false, the graph ends. It has no durable checkpointer, interrupt, stable resume identity, or recovery path that waits for a later user response.
4. A model-controlled task ID is inserted into a path without demonstrating confinement, collision prevention, or symlink handling.
5. Notification delivery is a stub; the frontend and external execution results are not verified.
6. The external branch labels dispatch as completed without applying a patch, inspecting the result, or checking rollback/verification criteria.
7. Application Support and an internal workspace are called a sandbox without an enforced OS process boundary.

If LangGraph is adopted later, its documented approval primitive requires a durable checkpointer, stable thread identity, explicit interrupt/resume, and careful handling of node replay. Code before an interrupt may run again, so persistence or notifications must tolerate repetition. A small explicit state machine may be simpler for the MVP. Sources: [LangGraph interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts), [official LangGraph functional API documentation](https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/functional-api.mdx).

## Discussion and acceptance gates

Before implementation, agree on the Operator's status/read allowlist, the ARTEMIS request and downstream-action boundary, the candidate native-adapter topology and optional restricted-worker mechanism, session bootstrap, supported provider capability matrix, cloud disclosure policy, canonical payload format, and retention clocks. Before Milestone 1 private live use, demonstrate restriction against malicious status/task input, out-of-scope reads, write/network attempts, stale or replayed decisions, hostile browser origins, unsafe rendered content, crashes during record transitions, and retention/quota exhaustion. Test ARTEMIS separately on narrow test-account/emulator fixtures before broadening its consumer input scope. These are future acceptance criteria, not evidence that the controls currently pass.
