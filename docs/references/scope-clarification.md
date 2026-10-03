# User scope clarification

Recorded from the user's replies on 2026-10-03. This is a summary, not a verbatim archive of the second pasted proposal.

Confirmed requirements:

- First consumer: ondevice-agent-platform's own Operator Agent.
- Second consumer: Google ARTEMIS support.
- Devices can vary; support Apple Foundation Models-capable Macs, such as M2 devices.
- Use Apple Foundation Models cloud handoff if supported.
- Continue the original docs-first strategy/revision/discussion request; do not implement directly.

The additional proposal requests non-invasive ARTEMIS integration through an OpenAI-compatible local endpoint, Flash/Pro support, hardware governance, local logs, reviewed operator changes, and later optimization. It proposes LangChain/LangGraph, a zero-database filesystem, Apple Foundation Models/Vision/Core ML/MLX routing, and a Qwen 9B operator.

These are source ideas to assess, not verified compatibility or performance results. In particular, `OPENAI_API_BASE`, 100% on-device operation, profile routing by model-name substring, OCR/VLM equivalence, and successful busy messages need correction. The user expressly permits a better solution; storage and orchestration alternatives remain documented for discussion.
