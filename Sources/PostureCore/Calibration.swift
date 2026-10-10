import Foundation

public enum ViewingContext: String, Codable, CaseIterable, Identifiable, Sendable {
    case upperMonitor, laptop
    public var id: String { rawValue }
    public var label: String { self == .upperMonitor ? "上方外接屏" : "笔记本屏幕" }
}

public struct BaselineMetric: Codable, Equatable, Sendable {
    public var median: Double
    public var mad: Double
    public static func from(_ values: [Double], period: Double = 360) -> BaselineMetric? {
        guard let anchor = values.first else { return nil }
        let unwrapped = values.map { anchor + Geometry.wrapDegrees($0 - anchor, period: period) }
        let center = medianOf(unwrapped)
        return BaselineMetric(median: Geometry.wrapDegrees(center, period: period),
                              mad: medianOf(unwrapped.map { abs($0 - center) }))
    }
    private static func medianOf(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
    public static func percentileDeviation(_ values: [Double], from center: Double, period: Double = 360) -> Double {
        guard !values.isEmpty else { return .infinity }
        let deviations = values.map { abs(Geometry.wrapDegrees($0 - center, period: period)) }.sorted()
        return deviations[min(deviations.count - 1, Int(ceil(Double(deviations.count) * 0.9)) - 1)]
    }
}

public struct Calibration: Codable, Equatable, Sendable {
    public var id: UUID
    public var context: ViewingContext
    public var createdAt: Date
    public var cameraSignature: String
    public var roll: BaselineMetric
    public var yaw: BaselineMetric?
    public var pitch: BaselineMetric?
    public var shoulder: BaselineMetric?
    public var faceValidSeconds: Double
    public var shoulderValidSeconds: Double
    public var sampleCount: Int
}

public enum CalibrationError: Error, Equatable, LocalizedError {
    case notFinished, insufficientFaceCoverage, unstableFace, cameraChanged
    public var errorDescription: String? {
        switch self {
        case .notFinished: return "校准尚未完成。"
        case .insufficientFaceCoverage: return "有效脸部观察不足 75%。请确保完整脸部可见，再重新校准。"
        case .unstableFace: return "校准期间头部波动较大。请保持舒适参考姿态，再重新校准。"
        case .cameraChanged: return "采集配置发生变化，请重新开始校准。"
        }
    }
}

public struct CalibrationCollector: Sendable {
    public let context: ViewingContext
    public let startedAt: Double
    public let duration: Double
    public let signature: String
    public private(set) var sampleCount = 0
    public private(set) var faceValidSeconds = 0.0
    public private(set) var shoulderValidSeconds = 0.0
    private var lastTimestamp: Double?
    private var lastFaceValid = false
    private var lastShoulderValid = false
    private var signatureChanged = false
    private var rolls: [Double] = [], yaws: [Double] = [], pitches: [Double] = [], shoulders: [Double] = []

    public init(context: ViewingContext, startedAt: Double, signature: String, duration: Double = 20) {
        self.context = context; self.startedAt = startedAt; self.signature = signature; self.duration = duration
    }
    public func progress(at now: Double) -> Double { min(1, max(0, (now - startedAt) / duration)) }
    public mutating func consume(_ observation: Observation, metrics: Metrics) {
        guard observation.timestamp.isFinite, observation.timestamp >= startedAt,
              observation.timestamp <= startedAt + duration,
              lastTimestamp.map({ observation.timestamp > $0 }) ?? true else { return }
        if observation.cameraSignature != signature { signatureChanged = true; return }
        if let last = lastTimestamp {
            let delta = observation.timestamp - last
            if delta <= 0.5 {
                if metrics.faceUsable && lastFaceValid { faceValidSeconds += delta }
                if metrics.shouldersUsable && lastShoulderValid { shoulderValidSeconds += delta }
            }
        }
        lastTimestamp = observation.timestamp
        lastFaceValid = metrics.faceUsable; lastShoulderValid = metrics.shouldersUsable
        sampleCount += 1
        if let value = metrics.roll { rolls.append(value) }
        if let value = metrics.yaw { yaws.append(value) }
        if let value = metrics.pitch { pitches.append(value) }
        if let value = metrics.shoulderAngle { shoulders.append(value) }
    }
    public func finish(at now: Double, date: Date = Date()) throws -> Calibration {
        guard now >= startedAt + duration else { throw CalibrationError.notFinished }
        guard !signatureChanged else { throw CalibrationError.cameraChanged }
        guard faceValidSeconds >= duration * 0.75, rolls.count >= 20,
              let roll = BaselineMetric.from(rolls) else { throw CalibrationError.insufficientFaceCoverage }
        let yaw = yaws.count >= 20 ? BaselineMetric.from(yaws) : nil
        let pitch = pitches.count >= 20 ? BaselineMetric.from(pitches) : nil
        guard roll.mad <= 3, BaselineMetric.percentileDeviation(rolls, from: roll.median) <= 6,
              (yaw?.mad ?? 0) <= 6, (pitch?.mad ?? 0) <= 6,
              yaw.map({ BaselineMetric.percentileDeviation(yaws, from: $0.median) <= 12 }) ?? true,
              pitch.map({ BaselineMetric.percentileDeviation(pitches, from: $0.median) <= 12 }) ?? true else {
            throw CalibrationError.unstableFace
        }
        let shoulderCandidate = BaselineMetric.from(shoulders, period: 180)
        let shoulder = shoulderValidSeconds >= duration * 0.75 && shoulders.count >= 20
            && (shoulderCandidate?.mad ?? .infinity) <= 3
            && (shoulderCandidate.map({ BaselineMetric.percentileDeviation(shoulders, from: $0.median, period: 180) <= 6 }) ?? false)
            ? shoulderCandidate : nil
        return Calibration(id: UUID(), context: context, createdAt: date, cameraSignature: signature,
                           roll: roll, yaw: yaw, pitch: pitch, shoulder: shoulder,
                           faceValidSeconds: faceValidSeconds, shoulderValidSeconds: shoulderValidSeconds,
                           sampleCount: sampleCount)
    }
}

public struct CalibrationArchive: Codable, Sendable {
    public var schemaVersion = 1
    public var profiles: [String: Calibration]
    public init(profiles: [String: Calibration] = [:]) { self.profiles = profiles }
}
