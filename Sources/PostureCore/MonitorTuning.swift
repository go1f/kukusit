import Foundation

public enum ComputePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, cpu, gpu, neuralEngine
    public var id: String { rawValue }
    public var deviceName: String { switch self { case .automatic: return "自动"; case .cpu: return "CPU"; case .gpu: return "GPU"; case .neuralEngine: return "Neural Engine" } }
}

public struct MonitorTuning: Codable, Equatable, Sendable {
    public var computePreference: ComputePreference = .automatic
    public var sustainedSeconds = 5.0
    public var cooldownSeconds = 60.0
    public var headEnterDegrees = 3.0
    public var headExitDegrees = 1.5
    public var shoulderEnterDegrees = 8.0
    public var shoulderExitDegrees = 5.0
    public var recoverySeconds = 2.0
    public var lossGraceSeconds = 2.0
    public var settleSeconds = 0.5
    public var yawLimitDegrees = 28.0
    public var pitchLimitDegrees = 35.0
    public var faceHertz = 6.0
    public var bodyHertz = 3.0
    public var handMouthSeconds = 2.0
    public var handMouthRadius = 0.25
    public var lipChangeSeconds = 4.0
    public var lipChangeThreshold = 0.08
    public var facialShiftThreshold = 0.08
    public var eyelidChangeThreshold = 0.15
    public var jawCheckSeconds = 300.0
    public var oralMatchDistance = 0.85
    public var oralMatchMargin = 0.35
    public init() {}
    private enum CodingKeys: String, CodingKey { case computePreference, sustainedSeconds, cooldownSeconds, headEnterDegrees, headExitDegrees, shoulderEnterDegrees, shoulderExitDegrees, recoverySeconds, lossGraceSeconds, settleSeconds, yawLimitDegrees, pitchLimitDegrees, faceHertz, bodyHertz, handMouthSeconds, handMouthRadius, lipChangeSeconds, lipChangeThreshold, facialShiftThreshold, eyelidChangeThreshold, jawCheckSeconds, oralMatchDistance, oralMatchMargin }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        computePreference = try c.decodeIfPresent(ComputePreference.self, forKey: .computePreference) ?? computePreference
        sustainedSeconds = try c.decodeIfPresent(Double.self, forKey: .sustainedSeconds) ?? sustainedSeconds
        cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? cooldownSeconds
        headEnterDegrees = try c.decodeIfPresent(Double.self, forKey: .headEnterDegrees) ?? headEnterDegrees
        headExitDegrees = try c.decodeIfPresent(Double.self, forKey: .headExitDegrees) ?? headExitDegrees
        shoulderEnterDegrees = try c.decodeIfPresent(Double.self, forKey: .shoulderEnterDegrees) ?? shoulderEnterDegrees
        shoulderExitDegrees = try c.decodeIfPresent(Double.self, forKey: .shoulderExitDegrees) ?? shoulderExitDegrees
        recoverySeconds = try c.decodeIfPresent(Double.self, forKey: .recoverySeconds) ?? recoverySeconds
        lossGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .lossGraceSeconds) ?? lossGraceSeconds
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? settleSeconds
        yawLimitDegrees = try c.decodeIfPresent(Double.self, forKey: .yawLimitDegrees) ?? yawLimitDegrees
        pitchLimitDegrees = try c.decodeIfPresent(Double.self, forKey: .pitchLimitDegrees) ?? pitchLimitDegrees
        faceHertz = try c.decodeIfPresent(Double.self, forKey: .faceHertz) ?? faceHertz
        bodyHertz = try c.decodeIfPresent(Double.self, forKey: .bodyHertz) ?? bodyHertz
        handMouthSeconds = try c.decodeIfPresent(Double.self, forKey: .handMouthSeconds) ?? handMouthSeconds
        handMouthRadius = try c.decodeIfPresent(Double.self, forKey: .handMouthRadius) ?? handMouthRadius
        lipChangeSeconds = try c.decodeIfPresent(Double.self, forKey: .lipChangeSeconds) ?? lipChangeSeconds
        lipChangeThreshold = try c.decodeIfPresent(Double.self, forKey: .lipChangeThreshold) ?? lipChangeThreshold
        facialShiftThreshold = try c.decodeIfPresent(Double.self, forKey: .facialShiftThreshold) ?? facialShiftThreshold
        eyelidChangeThreshold = try c.decodeIfPresent(Double.self, forKey: .eyelidChangeThreshold) ?? eyelidChangeThreshold
        jawCheckSeconds = try c.decodeIfPresent(Double.self, forKey: .jawCheckSeconds) ?? jawCheckSeconds
        oralMatchDistance = try c.decodeIfPresent(Double.self, forKey: .oralMatchDistance) ?? oralMatchDistance
        oralMatchMargin = try c.decodeIfPresent(Double.self, forKey: .oralMatchMargin) ?? oralMatchMargin
    }
    public var normalized: Self {
        var t = self
        func bound(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
        }
        t.sustainedSeconds = bound(t.sustainedSeconds, 1...120, 5)
        t.cooldownSeconds = bound(t.cooldownSeconds, 5...1800, 60)
        t.headEnterDegrees = bound(t.headEnterDegrees, 1...15, 3)
        t.headExitDegrees = bound(t.headExitDegrees, 0.2...(t.headEnterDegrees - 0.2), 1.5)
        t.shoulderEnterDegrees = bound(t.shoulderEnterDegrees, 2...25, 8)
        t.shoulderExitDegrees = bound(t.shoulderExitDegrees, 0.5...(t.shoulderEnterDegrees - 0.5), 5)
        t.recoverySeconds = bound(t.recoverySeconds, 0.5...10, 2)
        t.lossGraceSeconds = bound(t.lossGraceSeconds, 0...5, 2)
        t.settleSeconds = bound(t.settleSeconds, 0.2...1, 0.5)
        t.yawLimitDegrees = bound(t.yawLimitDegrees, 10...40, 28)
        t.pitchLimitDegrees = bound(t.pitchLimitDegrees, 10...50, 35)
        t.faceHertz = bound(t.faceHertz, 2...12, 6)
        t.bodyHertz = bound(t.bodyHertz, 1...6, 3)
        t.handMouthSeconds = bound(t.handMouthSeconds, 0.5...15, 2)
        t.handMouthRadius = bound(t.handMouthRadius, 0.05...0.8, 0.25)
        t.lipChangeSeconds = bound(t.lipChangeSeconds, 1...30, 4)
        t.lipChangeThreshold = bound(t.lipChangeThreshold, 0.02...0.3, 0.08)
        t.facialShiftThreshold = bound(t.facialShiftThreshold, 0.02...0.3, 0.08)
        t.eyelidChangeThreshold = bound(t.eyelidChangeThreshold, 0.05...0.5, 0.15)
        t.jawCheckSeconds = bound(t.jawCheckSeconds, 30...3600, 300)
        t.oralMatchDistance = bound(t.oralMatchDistance, 0.2...2, 0.85)
        t.oralMatchMargin = bound(t.oralMatchMargin, 0.1...2, 0.35)
        return t
    }
    public var reminderConfiguration: ReminderConfiguration {
        let t = normalized
        var c = ReminderConfiguration()
        c.sustainedSeconds = t.sustainedSeconds; c.cooldownSeconds = t.cooldownSeconds
        c.headEnterDegrees = t.headEnterDegrees; c.headExitDegrees = t.headExitDegrees
        c.shoulderEnterDegrees = t.shoulderEnterDegrees; c.shoulderExitDegrees = t.shoulderExitDegrees
        c.recoverySeconds = t.recoverySeconds; c.lossGraceSeconds = t.lossGraceSeconds; c.settleSeconds = t.settleSeconds
        c.yawLimitDegrees = t.yawLimitDegrees; c.pitchLimitDegrees = t.pitchLimitDegrees
        c.maximumGap = max(0.5, 1.5 / t.faceHertz)
        return c
    }
}
