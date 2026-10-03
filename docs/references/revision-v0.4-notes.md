# Architectural revision input notes

Recorded 2026-10-03 from the user's third proposal and accompanying instruction. This summary preserves the input's intent; the pasted source remains attached to the chat.

New direction:

- The user permits trying Apple Foundation Models first and limiting support to macOS 27 or later.
- The proposal calls the Operator a deterministic orchestration harness, with generative inference on demand.
- It adds ACP IDE integration, native-tool fast paths, a hidden home-directory layout, per-consumer scratch/locks, and syntax checking before later optimization.
- The user continues to allow better architectural choices and revisions. The existing docs-first boundary remains in force.

Adopted as proposed strategy: deterministic typed read-only fast paths; separate harness and model roles; first Apple provider evaluation on macOS 27+; separate ACP integration contract; explicit storage-root alternatives; static validation evidence attached to proposals.

Corrected or deferred: direct edits/formatting/builds, model-driven privilege routing, automatic external execution, mandatory Qwen fallback, immediate Apple system-model eviction, directory-based sandbox claims, syntax-as-correctness/training-label assumptions, all-night-only validation, and broad protocol/offline guarantees.

The source repeats `OPENAI_API_BASE`; the pinned ARTEMIS audit establishes `OPENAI_BASE_URL`. Its private mail link does not establish engineering claims; the revised docs use official technical references. Its LangGraph sample remains illustrative and is not copied into an implementation.
