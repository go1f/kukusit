import Foundation

// Personal, normalized appearance measurements; never a diagnosis or a symmetry score.
public struct FacialFeatures: Codable, Equatable, Sendable {
    public var outerLipAspect: Double
    public var mouthOpening: Double
    public var mouthShift: Double
    public var cornerSlope: Double
    public var eyelidDifference: Double?
    public init(outerLipAspect: Double, mouthOpening: Double, mouthShift: Double, cornerSlope: Double, eyelidDifference: Double? = nil) {
        self.outerLipAspect = outerLipAspect; self.mouthOpening = mouthOpening
        self.mouthShift = mouthShift; self.cornerSlope = cornerSlope
        self.eyelidDifference = eyelidDifference
    }
}
public struct FacialReference: Codable, Equatable, Sendable {
    public var outerLipAspect: Double
    public var mouthShift: Double
    public var cornerSlope: Double
    public var eyelidDifference: Double?
    public init(outerLipAspect: Double, mouthShift: Double, cornerSlope: Double, eyelidDifference: Double? = nil) {
        self.outerLipAspect = outerLipAspect; self.mouthShift = mouthShift; self.cornerSlope = cornerSlope
        self.eyelidDifference = eyelidDifference
    }
}
public struct OralObservation: Sendable {
    public var features: FacialFeatures
    public var mouthOutline: [Point]
    public var fingerTips: [JointPoint]
    public var handsObserved: Bool
    public init(features: FacialFeatures, mouthOutline: [Point], fingerTips: [JointPoint] = [], handsObserved: Bool = false) {
        self.features = features; self.mouthOutline = mouthOutline; self.fingerTips = fingerTips; self.handsObserved = handsObserved
    }
}
public enum FacialGeometry {
    public static func features(outer: [Point], inner: [Point], leftEye: [Point], rightEye: [Point],
                                nose: [Point], image: ImageSize) -> FacialFeatures? {
        guard outer.count >= 6, inner.count >= 4, !leftEye.isEmpty, !rightEye.isEmpty, !nose.isEmpty,
              (outer + inner + leftEye + rightEye + nose).allSatisfy(\.isInFrame) else { return nil }
        func mean(_ points: [Point]) -> Point {
            Point(points.map(\.x).reduce(0, +) / Double(points.count), points.map(\.y).reduce(0, +) / Double(points.count))
        }
        let eyes = [mean(leftEye), mean(rightEye)].sorted { $0.x < $1.x }
        let dx = (eyes[1].x - eyes[0].x) * image.width, dy = (eyes[1].y - eyes[0].y) * image.height
        let eyeDistance = hypot(dx, dy)
        guard eyeDistance >= 20 else { return nil }
        let c = dx / eyeDistance, s = dy / eyeDistance
        func aligned(_ p: Point) -> Point {
            let x = (p.x - eyes[0].x) * image.width, y = (p.y - eyes[0].y) * image.height
            return Point((x * c + y * s) / eyeDistance, (-x * s + y * c) / eyeDistance)
        }
        let lips = outer.map(aligned), inside = inner.map(aligned)
        guard let first = lips.min(by: { $0.x < $1.x }), let last = lips.max(by: { $0.x < $1.x }) else { return nil }
        let width = last.x - first.x
        guard width * eyeDistance >= 20, width > 0 else { return nil }
        let aspect = ((lips.map(\.y).max() ?? 0) - (lips.map(\.y).min() ?? 0)) / width
        let opening = ((inside.map(\.y).max() ?? 0) - (inside.map(\.y).min() ?? 0)) / width
        let shift = (first.x + last.x) / 2 - aligned(mean(nose)).x
        let slope = (last.y - first.y) / width
        func eyeAspect(_ region: [Point]) -> Double? {
            let points = region.map(aligned)
            let width = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
            guard points.count >= 4, width * eyeDistance >= 10 else { return nil }
            return ((points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)) / width
        }
        let difference = eyeAspect(leftEye).flatMap { l in eyeAspect(rightEye).map { l - $0 } }
        guard [aspect, opening, shift, slope].allSatisfy(\.isFinite) else { return nil }
        return FacialFeatures(outerLipAspect: aspect, mouthOpening: opening, mouthShift: shift, cornerSlope: slope, eyelidDifference: difference)
    }
    public static func handNearMouth(_ oral: OralObservation, image: ImageSize, radius: Double) -> Bool {
        guard oral.handsObserved, oral.mouthOutline.count >= 6 else { return false }
        let mouth = oral.mouthOutline.filter(\.isInFrame)
        guard let minX = mouth.map(\.x).min(), let maxX = mouth.map(\.x).max(), maxX > minX else { return false }
        let limit = (maxX - minX) * image.width * radius
        return oral.fingerTips.filter(\.isReliable).contains { tip in
            mouth.contains { p in hypot((p.x - tip.location.x) * image.width, (p.y - tip.location.y) * image.height) <= limit }
        }
    }
}
