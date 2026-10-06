"""Model/agent profiles, grants, principals — mirroring Profiles.swift and
Grants.swift."""
from __future__ import annotations

import enum
from dataclasses import dataclass, field


class ModelKind(enum.Enum):
    LLM = "llm"
    ML = "ml"


class ProviderCategory(enum.Enum):
    APPLE_FOUNDATION_MODELS = "appleFoundationModels"
    OWNED_OPEN_WEIGHT = "ownedOpenWeight"
    TYPED_ML = "typedML"


class CategoryStatus(enum.Enum):
    QUALIFIED = "qualified"        # at least one executable route registered
    OBSERVING = "observing"        # observable availability, nothing qualified
    NOT_CONFIGURED = "notConfigured"


@dataclass(frozen=True)
class ModelSource:
    """Declared provenance of a downloadable artifact. Pure data: a source
    declaration never causes a download by itself; acquisition is explicit."""
    repo: str          # owner/name
    revision: str      # pinned ref (tag/commit/branch)


@dataclass(frozen=True)
class ModelProfile:
    alias: str
    provider_id: str
    kind: ModelKind
    task: str
    purposes: tuple = ()
    input_schema: dict | None = None
    output_schema: dict | None = None
    capabilities: tuple = ()
    max_input_bytes: int | None = None
    max_output_tokens: int | None = None
    source: ModelSource | None = None


@dataclass(frozen=True)
class AgentProfile:
    """Immutable agent registration. implementation_ref names reviewed,
    compiled-in code - never an arbitrary loadable path."""
    id: str
    version: int
    harness_id: str
    harness_version: int
    state_schema_version: int
    tool_scope: tuple = ()
    model_profile_alias: str | None = None
    implementation_ref: str = ""


class Grant(enum.Enum):
    ADMIN_READ = "adminRead"
    ADMIN_STOP = "adminStop"
    LLM_INFER = "llmInfer"
    ML_PREDICT = "mlPredict"
    AGENT_RUN = "agentRun"
    AGENT_STATUS_READ = "agentStatusRead"


class ConsumerScope(enum.Enum):
    CONSOLE = "console"
    MODEL = "model"
    AGENT = "agent"

    @property
    def base_grants(self) -> frozenset:
        # Internal code-owned permissions, not OS-user authentication:
        # console can read and stop core state and run agents but cannot
        # call inference directly; the model scope only infers; the agent
        # scope runs agents and consumes model/ML calls inside a run, never
        # administration.
        return {
            ConsumerScope.CONSOLE: frozenset({
                Grant.ADMIN_READ, Grant.ADMIN_STOP,
                Grant.AGENT_RUN, Grant.AGENT_STATUS_READ}),
            ConsumerScope.MODEL: frozenset({Grant.LLM_INFER, Grant.ML_PREDICT}),
            ConsumerScope.AGENT: frozenset({
                Grant.AGENT_RUN, Grant.AGENT_STATUS_READ,
                Grant.LLM_INFER, Grant.ML_PREDICT}),
        }[self]


@dataclass(frozen=True)
class Principal:
    """Code-owned consumer identity. `id` is a nonsecret stable identifier;
    the platform issues no tokens."""
    id: str
    scope: ConsumerScope


class LocalConsumers:
    """The fixed local-trust consumers. Every loopback route binds to one of
    these identities rather than authenticating the caller."""
    MODEL = Principal("local-model", ConsumerScope.MODEL)
    AGENT = Principal("local-agent", ConsumerScope.AGENT)
    ADMINISTRATION = Principal("local-admin", ConsumerScope.CONSOLE)
