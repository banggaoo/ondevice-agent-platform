"""registry.json validation, mirroring ModelRegistry.swift.

The file is bounded data: every key is checked explicitly and a malformed
registry fails startup loudly rather than silently registering a different
model than the owner wrote.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .errors import ErrorCode, PlatformError
from .limits import PlatformLimits
from .profiles import ModelKind, ModelProfile, ModelSource

_TOP_KEYS = {"schemaVersion", "models"}
_MODEL_KEYS = {
    "alias", "kind", "task", "provider", "purposes", "capabilities",
    "inputSchema", "outputSchema", "maxInputBytes", "maxOutputTokens",
    "linear", "source", "delegate",
}

MLX_PROVIDER_ID = "mlx"
LLAMACPP_PROVIDER_ID = "llamacpp"
VLLMMLX_PROVIDER_ID = "vllm-mlx"
VISIONHYBRID_PROVIDER_ID = "vision-hybrid"
APPLE_PROVIDER_ID = "apple-foundation-models"
LINEAR_PROVIDER_ID = "builtin.linear"


@dataclass
class RegistryEntry:
    profile: ModelProfile
    linear: "LinearSpec | None" = None
    artifact_file: str | None = None
    delegate: str | None = None


@dataclass
class LinearSpec:
    features: list[str]
    labels: list[str]
    weights: list[list[float]]
    bias: list[float]


def is_valid_repo(repo: str) -> bool:
    parts = repo.split("/")
    if len(parts) != 2:
        return False
    return all(part and re.fullmatch(r"[A-Za-z0-9._-]+", part)
               and not part.startswith(".") and not part.endswith(".")
               for part in parts)


def is_valid_revision(revision: str) -> bool:
    return (0 < len(revision) <= 128
            and re.fullmatch(r"[A-Za-z0-9._/-]+", revision) is not None
            and ".." not in revision
            and not revision.startswith("/") and not revision.endswith("/"))


def _strings(value, field_name: str, required=False) -> list[str]:
    if value is None:
        if required:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"{field_name} required")
        return []
    if not isinstance(value, list):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            f"{field_name} must be an array")
    for item in value:
        if not isinstance(item, str) or not item:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"{field_name} entries must be strings")
    return list(value)


def _schema(value, numeric: bool) -> dict:
    if not isinstance(value, dict) or not value:
        raise PlatformError(ErrorCode.INVALID_REQUEST, "schema required")
    for name, ftype in value.items():
        if ftype not in ("number", "string", "boolean"):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "unknown feature type")
        if numeric and ftype != "number":
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "linear features must be numbers")
    return dict(value)


def _parse_linear(value, input_schema: dict) -> LinearSpec:
    if not isinstance(value, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "linear spec required")
    for key in value:
        if key not in ("features", "labels", "weights", "bias"):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "unknown linear key")
    features = _strings(value.get("features"), "features", required=True)
    if len(set(features)) != len(features):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "features must be unique")
    if set(features) != set(input_schema):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "features must match input schema")
    labels = _strings(value.get("labels"), "labels", required=True)
    if len(set(labels)) != len(labels):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "labels must be unique")
    raw_weights = value.get("weights")
    if (not isinstance(raw_weights, list)
            or len(raw_weights) != len(labels)):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "weights must have one row per label")
    weights: list[list[float]] = []
    for row in raw_weights:
        if not isinstance(row, list) or len(row) != len(features):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "weight row must match feature count")
        weights.append([_finite(w) for w in row])
    raw_bias = value.get("bias", [])
    if not isinstance(raw_bias, list):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "bias must be array")
    bias = [_finite(b) for b in raw_bias]
    if bias and len(bias) != len(labels):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "bias must have one value per label")
    return LinearSpec(features=features, labels=labels, weights=weights,
                      bias=bias or [0.0] * len(labels))


def _finite(value) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "weight must be a finite number")
    f = float(value)
    if f != f or f in (float("inf"), float("-inf")):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "weight must be a finite number")
    return f


def _parse_llm(obj: dict, alias: str) -> RegistryEntry:
    provider = obj.get("provider")
    if provider not in (MLX_PROVIDER_ID, LLAMACPP_PROVIDER_ID,
                        VLLMMLX_PROVIDER_ID, VISIONHYBRID_PROVIDER_ID):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "unknown llm provider")
    for key in ("inputSchema", "outputSchema", "linear"):
        if key in obj:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "schemas/linear are typed-ml only")
    delegate = obj.get("delegate")
    if delegate is not None and (not isinstance(delegate, str)
                                 or not delegate):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "delegate must be an alias string")
    artifact_file = None
    source = None
    if provider == VISIONHYBRID_PROVIDER_ID:
        # Composite route: no weights of its own; `delegate` names the
        # VLM alias it escalates to when OCR cannot answer.
        if delegate is None:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "vision-hybrid requires delegate")
        if "source" in obj:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "vision-hybrid holds no artifact source")
    else:
        if delegate is not None:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "delegate is a vision-hybrid-only key")
        source_obj = obj.get("source")
        if not isinstance(source_obj, dict):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "llm models require source")
        for key in source_obj:
            if key not in ("repo", "revision", "file"):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "unknown source key")
        repo, revision = source_obj.get("repo"), source_obj.get("revision")
        if (not isinstance(repo, str) or not isinstance(revision, str)
                or not is_valid_repo(repo)
                or not is_valid_revision(revision)):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "source repo/revision malformed")
        source = ModelSource(repo=repo, revision=revision)
        artifact_file = source_obj.get("file")
        if artifact_file is not None:
            if (not isinstance(artifact_file, str) or not artifact_file
                    or "/" in artifact_file or "\\" in artifact_file
                    or ".." in artifact_file
                    or artifact_file.startswith(".")):
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "source file malformed")
            if provider != LLAMACPP_PROVIDER_ID:
                raise PlatformError(ErrorCode.INVALID_REQUEST,
                                    "source file is a llamacpp-only key")
    task = obj.get("task", "chat")
    if task != "chat":
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "llm models require task chat")
    purposes = _strings(obj.get("purposes"), "purposes")
    capabilities = _strings(obj.get("capabilities"), "capabilities")
    max_input = obj.get("maxInputBytes")
    if max_input is not None:
        if not isinstance(max_input, int) or not (
                0 < max_input <= PlatformLimits.REQUEST_BODY_BYTES):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "maxInputBytes out of bounds")
    max_out = obj.get("maxOutputTokens")
    if max_out is not None:
        if not isinstance(max_out, int) or not (0 < max_out <= 32768):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "maxOutputTokens out of bounds")
    return RegistryEntry(profile=ModelProfile(
        alias=alias, provider_id=provider, kind=ModelKind.LLM, task=task,
        purposes=tuple(purposes), capabilities=tuple(capabilities),
        max_input_bytes=max_input, max_output_tokens=max_out,
        source=source),
        artifact_file=artifact_file, delegate=delegate)


def _parse_ml(obj: dict, alias: str) -> RegistryEntry:
    if obj.get("provider") != LINEAR_PROVIDER_ID:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "unknown model provider")
    if "source" in obj or "maxOutputTokens" in obj:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "source/maxOutputTokens are llm-only keys")
    if obj.get("task") != "classification":
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "linear models require task classification")
    input_schema = _schema(obj.get("inputSchema"), numeric=True)
    output_schema = _schema(obj.get("outputSchema"), numeric=False)
    if output_schema != {"label": "string", "confidence": "number"}:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "linear output schema must be "
                            "{label: string, confidence: number}")
    spec = _parse_linear(obj.get("linear"), input_schema)
    purposes = _strings(obj.get("purposes"), "purposes")
    capabilities = _strings(obj.get("capabilities"), "capabilities")
    max_input = obj.get("maxInputBytes")
    if max_input is not None:
        if not isinstance(max_input, int) or not (
                0 < max_input <= PlatformLimits.REQUEST_BODY_BYTES):
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                "maxInputBytes out of bounds")
    return RegistryEntry(
        profile=ModelProfile(
            alias=alias, provider_id=LINEAR_PROVIDER_ID, kind=ModelKind.ML,
            task="classification", purposes=tuple(purposes),
            input_schema=input_schema, output_schema=output_schema,
            capabilities=tuple(capabilities), max_input_bytes=max_input),
        linear=spec)


def parse_registry(root) -> list[RegistryEntry]:
    if not isinstance(root, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST, "registry malformed")
    for key in root:
        if key not in _TOP_KEYS:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"unknown registry key: {key}")
    version = root.get("schemaVersion")
    if version is not None and version != 1:
        raise PlatformError(ErrorCode.VERSION_UNSUPPORTED)
    models = root.get("models")
    if not isinstance(models, list):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "registry models missing")
    entries: list[RegistryEntry] = []
    aliases: set[str] = set()
    for value in models:
        entry = _parse_entry(value)
        if entry.profile.alias in aliases:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"duplicate alias: {entry.profile.alias}")
        aliases.add(entry.profile.alias)
        entries.append(entry)
    return entries


def _parse_entry(value) -> RegistryEntry:
    if not isinstance(value, dict):
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "registry entry malformed")
    for key in value:
        if key not in _MODEL_KEYS:
            raise PlatformError(ErrorCode.INVALID_REQUEST,
                                f"unknown model key: {key}")
    alias = value.get("alias")
    if not isinstance(alias, str) or not alias:
        raise PlatformError(ErrorCode.INVALID_REQUEST,
                            "model alias required")
    kind = value.get("kind")
    if kind == "llm":
        return _parse_llm(value, alias)
    if kind == "ml":
        return _parse_ml(value, alias)
    raise PlatformError(ErrorCode.INVALID_REQUEST, "unknown model kind")
