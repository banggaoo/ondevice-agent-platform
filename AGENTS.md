# Repository instructions

This project began implementation on 2026-10-04 after the user's explicit approval ("approve proposal, proceed development"), and the user has since directed continued autonomous development ("do not stop until complete project development"). The authoritative implementation plan is `docs/development.md`. Completed so far: the M1 serving foundation, the opt-in Apple Foundation Models provider, and the `builtin.linear` registry-declared typed-ML route. Still out of scope without a separate explicit request: model downloads, third-party dependencies, the Operator, cloud providers, ARTEMIS mutation, training, automation executors, and distribution.

- Read `README.md`, `docs/proposal.md`, `docs/decisions.md`, and `docs/development.md` before substantial changes.
- Keep runtime code within the approved M1 scope in `docs/development.md`. Do not add dependency manifests, installation scripts, services, downloaded models, or executable configuration beyond it without a later explicit implementation request.
- Label recommendations, assumptions, evidence, and accepted decisions distinctly. A proposed decision is not user approval.
- Preserve `docs/references/original-proposal.md` as the unmodified source reference. Its sample code is not an implementation specification.
- Verify changing or niche technical claims against primary sources. Record verification dates and links in the source notes.
- Keep workload scope narrow. Require measured quality and resource evidence before recommending additional backends, model training, or automatic execution.
- Never treat model output, model self-evaluation, or an external model's identity as authorization.
- Keep runtime logs, models, datasets, credentials, and private workspace content out of Git.
- For documentation changes, check local links, consistency, and `git diff --check`. Do not install tooling just to lint Markdown.
