import Foundation

public enum HabitKind: String, Sendable {
    case handMouth, lipChange, facialShift, eyelidChange
    public var message: String {
        switch self {
        case .handMouth: return "手离开嘴唇，轻轻放松下颌。"
        case .lipChange: return "口唇姿态有变化，检查是否正在咬唇，轻轻放松。"
        case .facialShift: return "口唇或嘴角姿态偏离个人参考，轻轻放松。"
        case .eyelidChange: return "眼周姿态持续偏离个人参考，留意是否正单侧眯眼。"
        }
    }
}
public struct HabitEngine: Sendable {
    private var lastTimestamp: Double?
    private var evidence: [HabitKind: Double] = [:]
    private var previousActive: Set<HabitKind> = []
    private var lastPrompt: [HabitKind: Double] = [:]
    public private(set) var summary = "口部观察等待清晰画面"
    public init() {}
    public mutating func reset() { lastTimestamp = nil; evidence = [:]; previousActive = []; summary = "口部观察等待清晰画面" }
    public mutating func observe(_ observation: Observation, metrics: Metrics, reference: FacialReference?,
                                 tuning: MonitorTuning, hand: Bool, lips: Bool, face: Bool) -> HabitKind? {
        guard observation.timestamp.isFinite, lastTimestamp.map({ observation.timestamp > $0 }) ?? true else { return nil }
        let gap = lastTimestamp.map { observation.timestamp - $0 } ?? 0
        lastTimestamp = observation.timestamp
        guard gap <= 0.75, metrics.faceUsable, observation.faceCount == 1, observation.bodyCount <= 1,
              let yaw = metrics.yaw, let pitch = metrics.pitch, abs(yaw) <= 15, abs(pitch) <= 30,
              let oral = observation.oral else {
            evidence = [:]; previousActive = []; summary = "口部看不清或观看方向偏转，保持安静"; return nil
        }
        let t = tuning.normalized, f = oral.features
        var active: Set<HabitKind> = []
        if hand, FacialGeometry.handNearMouth(oral, image: observation.imageSize, radius: t.handMouthRadius) { active.insert(.handMouth) }
        // An appearance change can suggest checking a habit; it cannot identify tooth contact.
        if let reference, f.mouthOpening < 0.08 {
            if lips, reference.outerLipAspect - f.outerLipAspect >= t.lipChangeThreshold { active.insert(.lipChange) }
            if face, abs(f.mouthShift - reference.mouthShift) >= t.facialShiftThreshold
                || abs(f.cornerSlope - reference.cornerSlope) >= t.facialShiftThreshold { active.insert(.facialShift) }
        }
        if face, let baseline = reference?.eyelidDifference, let value = f.eyelidDifference,
           abs(value - baseline) >= t.eyelidChangeThreshold { active.insert(.eyelidChange) }
        for kind in [HabitKind.handMouth, .lipChange, .facialShift, .eyelidChange] {
            if active.contains(kind) {
                if previousActive.contains(kind) { evidence[kind, default: 0] += gap }
                else { evidence[kind] = 0 }
            } else { evidence[kind] = 0 }
        }
        previousActive = active
        summary = active.isEmpty ? "未观察到持续手口、口唇或眼周变化" : "正在观察手口、口唇或眼周变化"
        for kind in [HabitKind.handMouth, .lipChange, .facialShift, .eyelidChange] where active.contains(kind) {
            let threshold = kind == .handMouth ? t.handMouthSeconds : t.lipChangeSeconds
            if (evidence[kind] ?? 0) + 0.000001 >= threshold,
               lastPrompt[kind].map({ observation.timestamp - $0 >= t.cooldownSeconds }) ?? true {
                lastPrompt[kind] = observation.timestamp; return kind
            }
        }
        return nil
    }
}
