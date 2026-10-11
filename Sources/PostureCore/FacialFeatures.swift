import Foundation

// Personal, normalized appearance measurements; never a diagnosis or a symmetry score.
public struct FacialFeatures: Codable, Equatable, Sendable {
    public var outerLipAspect: Double
    public var mouthOpening: Double
    public var mouthShift: Double
    public var cornerSlope: Double
    public var eyelidDifference: Double?
    // Optional fields preserve decoding of v0.5 calibration and example files.
    public var mouthWidth: Double?
    public var upperLipThickness: Double?
    public var lowerLipThickness: Double?
    public var upperLipAsymmetry: Double?
    public var lowerLipAsymmetry: Double?
    public var innerMouthAsymmetry: Double?
    public init(outerLipAspect: Double, mouthOpening: Double, mouthShift: Double, cornerSlope: Double,
                eyelidDifference: Double? = nil, mouthWidth: Double? = nil, upperLipThickness: Double? = nil,
                lowerLipThickness: Double? = nil, upperLipAsymmetry: Double? = nil,
                lowerLipAsymmetry: Double? = nil, innerMouthAsymmetry: Double? = nil) {
        self.outerLipAspect = outerLipAspect; self.mouthOpening = mouthOpening
        self.mouthShift = mouthShift; self.cornerSlope = cornerSlope; self.eyelidDifference = eyelidDifference
        self.mouthWidth = mouthWidth; self.upperLipThickness = upperLipThickness; self.lowerLipThickness = lowerLipThickness
        self.upperLipAsymmetry = upperLipAsymmetry; self.lowerLipAsymmetry = lowerLipAsymmetry
        self.innerMouthAsymmetry = innerMouthAsymmetry
    }
    public var isFinite: Bool {
        [outerLipAspect, mouthOpening, mouthShift, cornerSlope].allSatisfy(\.isFinite)
            && [eyelidDifference, mouthWidth, upperLipThickness, lowerLipThickness, upperLipAsymmetry,
                lowerLipAsymmetry, innerMouthAsymmetry].compactMap { $0 }.allSatisfy(\.isFinite)
    }
}
public struct FacialReference: Codable, Equatable, Sendable {
    public var outerLipAspect: Double
    public var mouthShift: Double
    public var cornerSlope: Double
    public var eyelidDifference: Double?
    public var mouthWidth: Double?
    public var mouthOpening: Double?
    public var upperLipThickness: Double?
    public var lowerLipThickness: Double?
    public var upperLipAsymmetry: Double?
    public var lowerLipAsymmetry: Double?
    public var innerMouthAsymmetry: Double?
    public init(outerLipAspect: Double, mouthShift: Double, cornerSlope: Double, eyelidDifference: Double? = nil,
                upperLipThickness: Double? = nil, lowerLipThickness: Double? = nil,
                upperLipAsymmetry: Double? = nil, lowerLipAsymmetry: Double? = nil, innerMouthAsymmetry: Double? = nil, mouthWidth: Double? = nil, mouthOpening: Double? = nil) {
        self.outerLipAspect = outerLipAspect; self.mouthShift = mouthShift; self.cornerSlope = cornerSlope
        self.eyelidDifference = eyelidDifference; self.mouthWidth = mouthWidth; self.mouthOpening = mouthOpening; self.upperLipThickness = upperLipThickness; self.lowerLipThickness = lowerLipThickness
        self.upperLipAsymmetry = upperLipAsymmetry; self.lowerLipAsymmetry = lowerLipAsymmetry; self.innerMouthAsymmetry = innerMouthAsymmetry
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
              (outer + inner + leftEye + rightEye + nose).allSatisfy(\.isInFrame),
              image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0 else { return nil }
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
        let midX = (first.x + last.x) / 2
        // Remove the mouth-corner line as well as head roll. Contour heights are relative to mouth width.
        func contourHeight(_ p: Point) -> Double { (p.y - first.y - (p.x - first.x) * slope) / width }
        let outerHeight = lips.map(contourHeight), innerHeight = inside.map(contourHeight)
        let upper = max(0, (outerHeight.max() ?? 0) - (innerHeight.max() ?? 0))
        let lower = max(0, (innerHeight.min() ?? 0) - (outerHeight.min() ?? 0))
        func halfAsymmetry(_ points: [Point], upper: Bool) -> Double? {
            let left = points.filter { $0.x <= midX + width * 0.001 }.map(contourHeight), right = points.filter { $0.x >= midX - width * 0.001 }.map(contourHeight)
            guard left.count >= 2, right.count >= 2 else { return nil }
            return upper ? (right.max() ?? 0) - (left.max() ?? 0) : (left.min() ?? 0) - (right.min() ?? 0)
        }
        func openingAsymmetry(_ points: [Point]) -> Double? {
            let left = points.filter { $0.x <= midX + width * 0.001 }.map(contourHeight), right = points.filter { $0.x >= midX - width * 0.001 }.map(contourHeight)
            guard left.count >= 2, right.count >= 2 else { return nil }
            return ((right.max() ?? 0) - (right.min() ?? 0)) - ((left.max() ?? 0) - (left.min() ?? 0))
        }
        func eyeAspect(_ region: [Point]) -> Double? {
            let points = region.map(aligned)
            let width = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
            guard points.count >= 4, width * eyeDistance >= 10 else { return nil }
            return ((points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)) / width
        }
        let difference = eyeAspect(leftEye).flatMap { l in eyeAspect(rightEye).map { l - $0 } }
        let result = FacialFeatures(outerLipAspect: aspect, mouthOpening: opening, mouthShift: shift, cornerSlope: slope,
            eyelidDifference: difference, mouthWidth: width, upperLipThickness: upper, lowerLipThickness: lower,
            upperLipAsymmetry: halfAsymmetry(lips, upper: true), lowerLipAsymmetry: halfAsymmetry(lips, upper: false),
            innerMouthAsymmetry: openingAsymmetry(inside))
        return result.isFinite ? result : nil
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
