"""builtin.linear typed-ML predictor, mirroring LinearPredictor.swift."""
from __future__ import annotations

from ..chat import validate_features
from ..errors import ErrorCode, PlatformError
from ..registry import LINEAR_PROVIDER_ID, LinearSpec


class LinearPredictor:
    provider_id = LINEAR_PROVIDER_ID

    def __init__(self, spec: LinearSpec) -> None:
        self._spec = spec

    def predict(self, request, profile):
        validate_features(request.inputs,
                          {f: "number" for f in self._spec.features})
        row = [float(request.inputs[f]) for f in self._spec.features]
        scores = []
        for i, weights in enumerate(self._spec.weights):
            score = self._spec.bias[i] + sum(
                w * x for w, x in zip(weights, row))
            scores.append((self._spec.labels[i], score))
        best = max(scores, key=lambda s: s[1])
        # softmax confidence for the winning label
        import math
        m = max(s for _, s in scores)
        exps = [math.exp(s - m) for _, s in scores]
        confidence = math.exp(best[1] - m) / sum(exps)
        return PredictionResult(outputs={"label": best[0],
                                         "confidence": confidence})


class PredictionRequest:
    def __init__(self, model: str, task: str, inputs: dict) -> None:
        self.model = model
        self.task = task
        self.inputs = inputs


class PredictionResult:
    def __init__(self, outputs: dict) -> None:
        self.outputs = outputs
