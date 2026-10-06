"""Curated model catalog + registry merge, mirroring ModelCatalog.swift.

Every choice carries its provider route's declared requirements; `setup`
presents only entries the host can actually satisfy (the requirements
model, not a predefined all-hosts list).
"""
from __future__ import annotations

from dataclasses import dataclass

from .errors import ErrorCode, PlatformError
from .profiles import ModelSource
from .registry import (LLAMACPP_PROVIDER_ID, MLX_PROVIDER_ID,
                       parse_registry)
from .requirements import RouteRequirements, host_info, qualifies

APPLE_MODEL_ALIAS = "apple-foundation-model"


@dataclass(frozen=True)
class CatalogModel:
    alias: str
    summary: str
    provider: str
    purposes: tuple
    capabilities: tuple
    max_output_tokens: int
    approx_bytes: int
    source: ModelSource
    requires: RouteRequirements
    artifact_file: str | None = None   # single-file GGUF selection

    def registry_value(self) -> dict:
        source = {"repo": self.source.repo, "revision": self.source.revision}
        if self.artifact_file:
            source["file"] = self.artifact_file
        return {
            "alias": self.alias,
            "kind": "llm",
            "provider": self.provider,
            "task": "chat",
            "purposes": list(self.purposes),
            "capabilities": list(self.capabilities),
            "maxOutputTokens": self.max_output_tokens,
            "source": source,
        }


ENTRIES: tuple[CatalogModel, ...] = (
    CatalogModel(
        alias="qwen3.8-9b",
        summary="text reasoning, coding, tool-capable (Qwen3.8-9B-Distill)",
        provider=MLX_PROVIDER_ID,
        purposes=("reasoning", "coding", "runtime-explanation"),
        capabilities=("text",),
        max_output_tokens=4096,
        approx_bytes=5_400_000_000,
        source=ModelSource(
            repo="nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
            revision="e827c31fbd588828f43180a87ab34415a6d8a4bf"),
        requires=RouteRequirements(os=("macOS",), accelerator="metal",
                                   fmt="mlx",
                                   min_free_bytes=6_000_000_000)),
    CatalogModel(
        alias="qwen-vl",
        summary="vision + text (Qwen3-VL-2B-Instruct)",
        provider=MLX_PROVIDER_ID,
        purposes=("vision",),
        capabilities=("text", "vision"),
        max_output_tokens=1024,
        approx_bytes=1_800_000_000,
        source=ModelSource(
            repo="mlx-community/Qwen3-VL-2B-Instruct-4bit",
            revision="main"),
        requires=RouteRequirements(os=("macOS",), accelerator="metal",
                                   fmt="mlx",
                                   min_free_bytes=2_500_000_000)),
    CatalogModel(
        alias="qwen3.8-9b-gguf",
        summary="text reasoning, coding (Qwen3.8-9B-Distill Q4_K_M GGUF)",
        provider=LLAMACPP_PROVIDER_ID,
        purposes=("reasoning", "coding"),
        capabilities=("text",),
        max_output_tokens=4096,
        approx_bytes=5_700_000_000,
        source=ModelSource(
            repo="empero-ai/Qwen3.8-9B-Distill-GGUF",
            revision="main"),
        artifact_file="Qwen3.8-9B-Q4_K_M.gguf",
        requires=RouteRequirements(os=("any",), accelerator="any",
                                   fmt="gguf",
                                   min_free_bytes=6_000_000_000)),
)


def entry(alias: str) -> CatalogModel | None:
    return next((e for e in ENTRIES if e.alias == alias), None)


def available_entries(host=None) -> list[tuple[CatalogModel, bool, str]]:
    """(entry, eligible, reason) - the menu is host-filtered, not fixed."""
    host = host or host_info()
    return [(e, *qualifies(e.requires, host)) for e in ENTRIES]


def merged_registry(existing, selection: list[CatalogModel]):
    """Merge selected catalog entries into the registry payload. Same-alias
    entries are replaced; every other declaration is preserved. The merged
    result is re-validated through parse_registry before callers persist."""
    models: list = []
    if isinstance(existing, dict):
        for key in existing:
            if key not in ("schemaVersion", "models"):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    f"unknown registry key: {key}")
        declared = existing.get("models")
        if declared is not None:
            if not isinstance(declared, list):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "registry models malformed")
            models = list(declared)
    elif existing is not None:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "registry malformed")
    selected = {e.alias for e in selection}
    models = [m for m in models
              if not (isinstance(m, dict) and m.get("alias") in selected)]
    models.extend(e.registry_value() for e in selection)
    merged = {"schemaVersion": 1, "models": models}
    parse_registry(merged)   # fail loudly before callers persist
    return merged
