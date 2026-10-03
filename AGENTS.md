# Repository instructions

This project is in a documentation-only strategy phase. The user asked to revise and discuss the proposal before implementation.

- Read `README.md`, `docs/proposal.md`, and `docs/decisions.md` before substantial changes.
- Revise documentation and plans within the current request. Do not add runtime code, dependency manifests, installation scripts, services, downloaded models, or executable configuration without a later explicit implementation request.
- Label recommendations, assumptions, evidence, and accepted decisions distinctly. A proposed decision is not user approval.
- Preserve `docs/references/original-proposal.md` as the unmodified source reference. Its sample code is not an implementation specification.
- Verify changing or niche technical claims against primary sources. Record verification dates and links in the source notes.
- Keep workload scope narrow. Require measured quality and resource evidence before recommending additional backends, model training, or automatic execution.
- Never treat model output, model self-evaluation, or an external model's identity as authorization.
- Keep runtime logs, models, datasets, credentials, and private workspace content out of Git.
- For documentation changes, check local links, consistency, and `git diff --check`. Do not install tooling just to lint Markdown.
