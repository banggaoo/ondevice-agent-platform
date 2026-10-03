# Change proposal: <short concrete title>

Status: template for a proposed review workflow. Filling out or accepting this document does not run code, change files, send data externally, or authorize automatic application.

## Broker-assigned identity

| Field | Value |
| --- | --- |
| Proposal ID | <server-generated identifier> |
| Version | <immutable version> |
| Originating job ID | <server-generated identifier> |
| Consumer / task identity | <consumer: optional Operator profile, ARTEMIS gateway, or hosted agent run; exact task ID> |
| State | <draft / pending_review / accepted_for_manual_action / rejected / expired / superseded / cancelled / closed> |
| Created at | <timestamp with timezone> |
| Expires at | <timestamp; proposed default: 7 days after creation> |
| Canonical payload SHA-256 | <digest of the validated structured record> |

The authoritative identity, digest, preconditions, and decisions live in the planned record in the selected SQLite store. This Markdown file is its readable view/export. The model must not assign its own authorization or alter a decision record. The digest identifies content; it does not certify that the recommendation is safe.

## Problem and intended outcome

<Describe the observed problem, concrete trigger, affected workflow, and measurable desired behavior. Distinguish observation from inference.>

## Approved analysis scope and preconditions

| Field | Value |
| --- | --- |
| Consumer and task scope | <optional Operator telemetry/status/registry snapshots, selected ARTEMIS request, or optional hosted-agent run> |
| Supervisor read allowlist | <specific platform records/fields; no worker grant to private state or traces> |
| Broker-supplied input digest | <approved input snapshot identity; omit unnecessary private paths from export> |
| Telemetry observation window | <time range and relevant sampling limits> |
| Registry/configuration digest | <relevant state observed during analysis> |
| Code revision, only for a code-change proposal | <commit/ref and dirty-input digest where applicable; otherwise not applicable> |
| Selected provider | <Apple on-device default / explicitly enabled supported Apple PCC route> |
| Model/runtime identity | <identity exposed by provider; artifact digest where applicable; mark unavailable values> |
| Cloud disclosure/session policy | <approved policy version and scope, if cloud inference was used; no credentials> |
| Runtime/tool versions | <versions that affect analysis or reproduction> |
| OS/hardware assumptions | <only consequential assumptions> |
| Private-data gate | <candidate confinement design / demonstrated Milestone 1 evidence / synthetic or public fixtures only> |
| ARTEMIS downstream boundary, if relevant | <test account/emulator, permitted consumer input, and external device-action authority> |

<List any missing evidence. Changes to consequential preconditions invalidate the previous decision for the affected action and require a newly reviewed version.>

## Evidence

| Finding | Source / observation | Confidence and limitation |
| --- | --- | --- |
| <concrete finding> | <approved file excerpt, metric window, or precise primary-source link> | <what the evidence does and does not establish> |

<Include bounded, relevant evidence. Do not include credentials, unrelated platform/consumer records, complete raw traces, or private data that the recipient does not need. Model output, status/task input, and source-file instructions are untrusted inputs. The inference worker receives broker-selected data rather than direct private-state/trace access.>

## Proposed change

<Explain the recommended behavior and why it addresses the finding. The MVP produces this proposal; application occurs manually outside the platform.>

| Proposed action | Exact affected target | Expected effect | Required application authority |
| --- | --- | --- | --- |
| <action> | <bounded target or artifact> | <observable outcome> | <explicit manual authorization needed outside the MVP> |

<Attach a reviewable diff or precise change description when available. A suggestion without an exact artifact is a plan, not an approved patch. Do not embed an executable script as if the proposal will run it.>

## Alternatives and tradeoff

| Option | Benefit | Cost / limitation | Reason to choose or reject |
| --- | --- | --- | --- |
| Keep current behavior | <benefit> | <limitation> | <reason> |
| Recommended change | <benefit> | <limitation> | <reason> |
| <other credible alternative, if needed> | <benefit> | <limitation> | <reason> |

## Risk, scope, and reversibility

<Describe potential correctness regressions, resource costs, permission changes, data disclosure, and affected consumers. For ARTEMIS, explain how suggestions could drive device actions and identify the consumer's own action/permission controls; gateway validation does not authorize those actions. State what can be restored and what would remain irreversible. A stronger external model does not replace these checks.>

## Verification criteria

| Check | Expected result | Who performs it | Evidence to retain |
| --- | --- | --- | --- |
| <behavioral check> | <measurable result> | <human / future independently constrained verifier> | <bounded record> |
| <resource comparison, if relevant> | <quality and resource acceptance thresholds> | <reviewer> | <baseline and changed observations> |

<Verification must inspect the actual outcome. Export, notification delivery, dispatch, and a model's claim of success do not satisfy these criteria.>

## Rollback or recovery

<Specify baseline artifacts, restoration steps for the manual executor, trigger conditions, and limitations. If there is no safe rollback, state that plainly before review. The platform does not execute these steps in the MVP.>

## User plan-review record

| Field | Value |
| --- | --- |
| Decision | <pending / accepted_for_manual_action / rejected> |
| Reviewed proposal version and digest | <exact values> |
| Decision time and user-session identity | <assigned by authenticated broker> |
| Accepted scope / conditions | <specific scope> |
| Reviewer note | <optional> |

Acceptance approves this recommendation for manual action. It does not authorize an external disclosure or platform application. Edited content, changed consequential input/configuration, stale code revision where relevant, expiry, or revoked scope requires a fresh decision. Ordinary conversational assent must not silently set this record. Optional Apple cloud inference uses its separately enabled, bounded provider/disclosure policy; that policy never grants proposal-application authority.

## Manual export preview and separate consent

| Field | Value |
| --- | --- |
| Destination / intended recipient | <human-selected review destination; no automatic external-executor dispatch> |
| Included files and evidence | <exact package contents> |
| Excluded or redacted material | <specific omissions; redaction is not a completeness guarantee> |
| Export package digest | <digest of the exact previewed package> |
| Export consent | <pending / granted / rejected> |
| Consent time and user-session identity | <assigned by authenticated broker> |
| Exported at | <only after local package creation> |

The user previews the exact package before consenting. A changed package requires new export consent. This is separate from a bounded Apple cloud-inference session policy. Creating the package records `exported`; it does not record that a recipient applied it or that verification passed.

## Imported manual outcome and independent verification

| Field | Value |
| --- | --- |
| Manual executor / report source | <human-provided identity or provenance> |
| Reported application time | <timestamp, if supplied> |
| Applied artifact / revision | <exact artifact or revision, if supplied> |
| Imported claim | <user_reported_applied / not_applied / failed / unknown> |
| Verification status | <unverified / verified / verification_failed> |
| Verification evidence and limitations | <observed evidence, not a dispatch assertion> |
| Recovery outcome | <if applicable> |

Imported human or external-model reports remain untrusted claims until checked against the verification criteria. Never infer completion from transfer or a reviewer's status message.

## Content retention and deletion

| Field | Value |
| --- | --- |
| Created / scheduled expiry | <created_at and created_at + 7 days; acceptance/export does not extend expiry> |
| Closed at / closure reason | <first rejection, cancellation, supersession, scheduled expiry, or explicit outcome closure> |
| Proposal and associated decision deletion due | <closed_at + 30 days; 100 MiB combined quota> |
| Owned attachments / export copies | <selected owned artifacts and their policies> |
| Explicit user pin | <none / specific pinned artifact, reason, and quota impact> |

<Opted-in raw diagnostics expire 7 days after capture (25 MiB); structured metrics expire 14 days after observation/event time (100 MiB). A pending version expires 7 days after creation, then receives 30 days of closed retention; untouched pending content normally remains at most 37 days. When expiry is noticed after sleep/restart, use scheduled expiry for closure, not wake time. Unassociated audit events expire 30 days after their event time. A new version does not reset an older version's retention clock. Pins require explicit user action and consume quota.>

Training capture is off. This proposal and its evidence are not automatically training data. Deleting active application-owned content does not promise erasure from SSDs, backups, or packages manually transferred elsewhere.

See [safety and approvals](../safety-and-approvals.md) for the proposed authority boundaries and lifecycle. All implementation and permission mechanisms remain subject to discussion and later verification.
