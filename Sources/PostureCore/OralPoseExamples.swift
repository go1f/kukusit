import Foundation

// These are appearance labels selected by the user. They never certify a hidden tooth contact or bite force.
public enum OralPoseAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case jawTension, upperLip, lowerLip, mouthShift, tongueSide
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .jawTension: return "下颌紧张外观"
        case .upperLip: return "上唇动作外观"
        case .lowerLip: return "下唇动作外观"
        case .mouthShift: return "嘴角偏移"
        case .tongueSide: return "舌部动作外观"
        }
    }
    public var habitKind: HabitKind {
        switch self {
        case .jawTension: return .jawAppearance
        case .upperLip: return .upperLipAppearance
        case .lowerLip: return .lowerLipAppearance
        case .mouthShift: return .facialShift
        case .tongueSide: return .tongueAppearance
        }
    }
}
public struct OralPoseExample: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var action: OralPoseAction
    public var label: String
    public var samples: [FacialFeatures]
    public init(id: UUID = UUID(), action: OralPoseAction, label: String, samples: [FacialFeatures]) {
        self.id = id; self.action = action; self.label = String(label.prefix(60)); self.samples = samples
    }
}
public struct OralPoseMatch: Equatable, Sendable {
    public var exampleID: UUID
    public var action: OralPoseAction
    public var label: String
    public var distance: Double
    public var margin: Double
    // Distance and margin are geometry comparisons, not medical probabilities or measured accuracy.
}
public struct OralPoseExamples: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var cameraSignature: String
    public var neutral: [FacialFeatures]
    public var examples: [OralPoseExample]
    public var maximumDistance: Double = 0.85
    public var minimumMargin: Double = 0.35
    public init(cameraSignature: String, neutral: [FacialFeatures] = [], examples: [OralPoseExample] = []) {
        self.cameraSignature = cameraSignature; self.neutral = neutral; self.examples = examples
    }
    public func matchesFace(_ signature: String) -> Bool {
        guard !cameraSignature.isEmpty, !signature.isEmpty else { return false }
        return cameraSignature.split(separator: "|").prefix(4) == signature.split(separator: "|").prefix(4)
    }
    public var hasNeutralReference: Bool { neutral.filter(\.isFinite).count >= 6 }
    public var reference: FacialReference? {
        let samples = neutral.filter(\.isFinite)
        guard samples.count >= 6 else { return nil }
        func median(_ values: [Double]) -> Double? {
            guard values.count >= 6 else { return nil }; let values = values.sorted()
            let half = values.count / 2
            return values.count % 2 == 0 ? (values[half - 1] + values[half]) / 2 : values[half]
        }
        return FacialReference(outerLipAspect: median(samples.map(\.outerLipAspect))!,
            mouthShift: median(samples.map(\.mouthShift))!, cornerSlope: median(samples.map(\.cornerSlope))!,
            eyelidDifference: median(samples.compactMap(\.eyelidDifference)),
            upperLipThickness: median(samples.compactMap(\.upperLipThickness)), lowerLipThickness: median(samples.compactMap(\.lowerLipThickness)),
            upperLipAsymmetry: median(samples.compactMap(\.upperLipAsymmetry)), lowerLipAsymmetry: median(samples.compactMap(\.lowerLipAsymmetry)),
            innerMouthAsymmetry: median(samples.compactMap(\.innerMouthAsymmetry)), mouthWidth: median(samples.compactMap(\.mouthWidth)),
            mouthOpening: median(samples.map(\.mouthOpening)))
    }

    public func sampleCount(for action: OralPoseAction) -> Int {
        examples.filter { $0.action == action }.flatMap(\.samples).filter(\.isFinite).count
    }
    public func match(_ features: FacialFeatures) -> OralPoseMatch? {
        guard schemaVersion == 1, features.isFinite, hasNeutralReference else { return nil }
        let neutral = neutral.filter(\.isFinite)
        let negativeDistance = neutral.compactMap { Self.distance(features, $0) }.min() ?? .infinity
        let maxDistance = maximumDistance.isFinite ? min(2, max(0.2, maximumDistance)) : 0.85
        let marginLimit = minimumMargin.isFinite ? min(2, max(0.1, minimumMargin)) : 0.35
        var candidates: [(OralPoseExample, Double)] = []
        for example in examples {
            // A positive sample overlapping a comfortable sample cannot define a useful prototype.
            let separated = example.samples.filter { f in
                f.isFinite && (neutral.compactMap { Self.distance(f, $0) }.min() ?? 0) >= 0.75
            }
            guard separated.count >= 6, let distance = separated.compactMap({ Self.distance(features, $0) }).min() else { continue }
            candidates.append((example, distance))
        }
        candidates.sort { $0.1 < $1.1 }
        guard let best = candidates.first, best.1 <= maxDistance else { return nil }
        let otherDistance = candidates.filter { $0.0.action != best.0.action }.map(\.1).min() ?? .infinity
        let margin = min(negativeDistance, otherDistance) - best.1
        guard margin >= marginLimit else { return nil }
        return OralPoseMatch(exampleID: best.0.id, action: best.0.action, label: best.0.label,
                             distance: best.1, margin: margin)
    }
    public static func distance(_ lhs: FacialFeatures, _ rhs: FacialFeatures) -> Double? {
        guard lhs.isFinite, rhs.isFinite else { return nil }
        // Fixed physical scales make one stretched feature unable to dominate every comparison.
        let values: [(Double?, Double?, Double)] = [
            (lhs.outerLipAspect, rhs.outerLipAspect, 0.06), (lhs.mouthOpening, rhs.mouthOpening, 0.05),
            (lhs.mouthShift, rhs.mouthShift, 0.045), (lhs.cornerSlope, rhs.cornerSlope, 0.06),
            (lhs.mouthWidth, rhs.mouthWidth, 0.12), (lhs.upperLipThickness, rhs.upperLipThickness, 0.035),
            (lhs.lowerLipThickness, rhs.lowerLipThickness, 0.035), (lhs.upperLipAsymmetry, rhs.upperLipAsymmetry, 0.04),
            (lhs.lowerLipAsymmetry, rhs.lowerLipAsymmetry, 0.04), (lhs.innerMouthAsymmetry, rhs.innerMouthAsymmetry, 0.05)
        ]
        let squared = values.compactMap { a, b, scale -> Double? in
            guard let a, let b else { return nil }; return pow((a - b) / scale, 2)
        }
        guard squared.count >= 4 else { return nil }
        return sqrt(squared.reduce(0, +) / Double(squared.count))
    }
}
