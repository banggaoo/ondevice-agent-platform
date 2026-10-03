# Distribution and responsible use

**Status:** v0.7 recommendations, 2026-10-03. GitHub executable delivery is confirmed; the specific license, release workflow, and legal text remain proposed. No binary, license file, agreement, release, or signing setup is created by this document.

## Delivery shape

The product is a per-user macOS 27+ executable that starts a local inference server and web console. It does not require a standalone native GUI or default App Store distribution. Source stays on GitHub; recommend versioned Apple Silicon release archives with checksums, changelog, supported OS/SDK requirements, dependency notices, and a tested local startup/stop path. Keep generated binaries, models, datasets, traces, credentials, and runtime state out of source history.

For prebuilt direct-download artifacts, recommend Developer ID signing and notarization, with Gatekeeper/startup testing before release. This is separate from App Review and does not grant protected cloud API access. Source builds and prebuilt downloads need distinct support instructions. No installer, privileged daemon, or automatic update mechanism is selected for the initial scope. [Apple Developer ID](https://developer.apple.com/developer-id/), [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## PCC access is a separate gate

The local platform does not need a PCC entitlement merely to run. If its provider calls Apple's PCC API, the calling software must meet Apple's access rules regardless of being called a platform, server, or app. Apple's current published policy requires App Store Small Business Program enrollment, fewer than two million first-time downloads from any app on the App Store, and an assigned PCC entitlement. It describes production App Store use and TestFlight/ad hoc testing, not unrestricted GitHub executable distribution. This does not prove every possible CLI arrangement is forbidden, but it does mean the chosen public delivery path has no established PCC eligibility. Obtain an applicable supported path before promising that cloud route; do not bypass authorization. The local-only code-owned serving core with purpose-qualified providers remains useful independently of PCC. [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/).

## License and misuse responsibility

Recommend the standard, unmodified MIT license for a small permissively licensed platform. Its canonical terms require copyright/license notice preservation and include an AS IS warranty disclaimer and liability limitation. This is a recommendation, not the selected license or a guarantee of complete legal immunity. Choose copyright holders and license before publication; assess dependency/model licenses separately. [Canonical MIT license](https://opensource.org/license/mit).

Proposed responsible-use direction: users and consumer authors are responsible for legitimate task authorization, account/device/data permissions, and their downstream actions. The platform supplies inference and bounded platform controls; it does not authorize ARTEMIS device actions or arbitrary generated-code execution. Release documentation should describe misuse responsibility and applicable no-warranty/liability terms without claiming that a disclaimer prevents every possible liability. Any custom agreement needs appropriate legal review for its intended jurisdiction. This documentation draft is not legal advice or a binding agreement.

A disclaimer does not replace authentication, scope enforcement, safe input handling, cancellation, incident handling, or accurate capability claims. Do not modify a standard open-source license with an improvised blanket exemption and call it the original license.

## Release quality and privacy

Before a later release, use the declared [evaluation gates](evaluation.md) and publish only supported serving capabilities and device profiles. The user's commitment to ARTEMIS testing is a future plan, not a passing result. Record source-informed estimates separately from measured resource/quality evidence. Public research informs defaults; workload tests validate them.

Use one explicit local-only/eligible-Apple-cloud mode choice for repeated in-scope requests, not approval on every generation. Apple's PCC privacy design does not cover this platform's local logs, accidental credential capture, or cross-consumer data sharing. Keep those ordinary application safeguards and do not treat cloud inference as execution authorization. [Cloud policy](safety-and-approvals.md#foundation-models-and-optional-apple-cloud-inference).
