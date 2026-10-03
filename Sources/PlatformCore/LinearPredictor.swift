import Foundation

/// Immutable linear classification artifact: ordered features, labels, a
/// weights matrix, and optional bias. Weights are bounded data declared in
/// registry.json - not executable code and never a loadable path.
public struct LinearModelSpec: Sendable, Equatable {
    public let features: [String]     // input order; must equal the input schema keys
    public let labels: [String]
    public let weights: [[Double]]    // labels.count rows x features.count columns
    public let bias: [Double]         // labels.count
}

/// Pure-Swift typed-ML provider: score = bias + W*x per label, then a
/// deterministic softmax argmax. Computes real arithmetic on schema-validated
/// inputs only; it is honestly `builtin.linear`, not a disguised Core ML or
/// downloaded runtime. Cancellation is trivial because the computation is
/// bounded arithmetic, not a suspended inference.
public final class LinearPredictor: MLPredictor, @unchecked Sendable {
    public static let id = "builtin.linear"
    public let providerID: String
    public let spec: LinearModelSpec

    public init(spec: LinearModelSpec) {
        providerID = LinearPredictor.id
        self.spec = spec
    }

    /// Defensive re-validation; the supervisor already enforced the declared
    /// input schema before dispatch, but a predictor never trusts input shape.
    private func numeric(_ request: PredictionRequest, feature: String) throws -> Double {
        switch request.inputs[feature] {
        case .int(let i): return Double(i)
        case .double(let d) where d.isFinite: return d
        default: throw PlatformError(.invalidRequest, detail: "feature not numeric")
        }
    }

    public func predict(_ request: PredictionRequest, profile: ModelProfile) async throws -> PredictionResult {
        var scores = spec.bias
        for labelIndex in spec.labels.indices {
            for (featureIndex, feature) in spec.features.enumerated() {
                scores[labelIndex] += spec.weights[labelIndex][featureIndex]
                    * (try numeric(request, feature: feature))
            }
        }
        // Stable softmax; deterministic argmax on ties (lowest index wins).
        let peak = scores.max() ?? 0
        var total = 0.0
        var bestIndex = 0
        var bestProb = -1.0
        for (index, score) in scores.enumerated() {
            let prob = exp(score - peak)
            total += prob
            if prob > bestProb { bestProb = prob; bestIndex = index }
        }
        guard total.isFinite, total > 0 else {
            throw PlatformError(.internal, detail: "degenerate scores")
        }
        return PredictionResult(
            modelIdentity: LinearPredictor.id,
            outputs: [
                "label": .string(spec.labels[bestIndex]),
                "confidence": .double(bestProb / total),
            ])
    }
}
