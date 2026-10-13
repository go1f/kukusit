import Foundation

public enum HabitKind: String, Codable, CaseIterable, Sendable {
    case handMouth, lipChange, facialShift, eyelidChange
    case jawAppearance, upperLipAppearance, lowerLipAppearance, tongueAppearance
    public var message: String {
        switch self {
        case .handMouth: return "手离开嘴唇"
        case .lipChange: return "放松嘴唇"
        case .facialShift: return "放松嘴角"
        case .eyelidChange: return "放松双眼"
        case .jawAppearance: return "放松下颌"
        case .upperLipAppearance: return "放松嘴唇"
        case .lowerLipAppearance: return "放松嘴唇"
        case .tongueAppearance: return "放松舌头"
        }
    }
}
public struct HabitState: Equatable, Sendable {
    public var kind: HabitKind
    public var elapsedSeconds: Double
    public var thresholdSeconds: Double
    public var confirmed: Bool
    public var recovering: Bool
    public var recoverySeconds: Double
    public var exampleLabel: String?
    public var message: String { kind.message }
}
public struct HabitResult: Equatable, Sendable {
    public var prompt: HabitKind?
    public var reliable: Bool
    public var states: [HabitState]
    public var matchedExample: OralPoseMatch?
    public var confirmedStates: [HabitState] { reliable ? states.filter(\.confirmed) : [] }
}
public struct HabitEngine: Sendable {
    private struct Episode: Sendable {
        var elapsed: Double = 0
        var recovery: Double = 0
        var wasActive = false
        var confirmed = false
        var exampleLabel: String?
        var previousEvidenceUsable = false
    }
    private var lastTimestamp: Double?
    private var lastReliableAt: Double?
    private var previousReliable = false
    private var episodes: [HabitKind: Episode] = [:]
    private var lastPrompt: [HabitKind: Double] = [:]
    private var recentFeatures: [(Double, FacialFeatures)] = []
    public private(set) var summary = "口部观察等待清晰画面"
    public private(set) var result = HabitResult(prompt: nil, reliable: false, states: [], matchedExample: nil)
    public init() {}
    public mutating func reset() {
        lastTimestamp = nil; lastReliableAt = nil; previousReliable = false; episodes = [:]; recentFeatures = []
        summary = "口部观察等待清晰画面"
        result = HabitResult(prompt: nil, reliable: false, states: [], matchedExample: nil)
    }
    // Compatibility with older callers. Persistent banners should use observeDetailed's confirmedStates.
    public mutating func observe(_ observation: Observation, metrics: Metrics, reference: FacialReference?,
                                 tuning: MonitorTuning, hand: Bool, lips: Bool, face: Bool) -> HabitKind? {
        observeDetailed(observation, metrics: metrics, reference: reference, tuning: tuning,
                        hand: hand, lips: lips, face: face).prompt
    }
    public mutating func observeDetailed(_ observation: Observation, metrics: Metrics, reference: FacialReference?,
                                         tuning: MonitorTuning, hand: Bool, lips: Bool, face: Bool,
                                         examples: OralPoseExamples? = nil, mouthShift: Bool? = nil) -> HabitResult {
        let timestamp = observation.timestamp, t = tuning.normalized
        let mouthShiftEnabled = mouthShift ?? face
        guard timestamp.isFinite, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            previousReliable = false
            result = HabitResult(prompt: nil, reliable: false, states: snapshot(tuning: t), matchedExample: nil)
            return result
        }
        let gap = lastTimestamp.map { timestamp - $0 } ?? 0
        lastTimestamp = timestamp
        let multiple = observation.faceCount > 1 || observation.bodyCount > 1
        let turned = (metrics.yaw.map { abs($0) > 15 } ?? false) || (metrics.pitch.map { abs($0) > 30 } ?? false)
        guard gap <= max(0.75, 1.5 / t.faceHertz), metrics.faceUsable, observation.faceCount == 1, !multiple, !turned,
              metrics.yaw != nil, metrics.pitch != nil, let oral = observation.oral, oral.features.isFinite else {
            // Unknown is never recovery. Short dropouts preserve each timer but contribute no time.
            if multiple || turned || lastReliableAt.map({ timestamp - $0 > t.lossGraceSeconds }) ?? true { episodes = [:]; recentFeatures = [] }
            previousReliable = false
            summary = "口部看不清或观看方向偏转，保持安静"
            result = HabitResult(prompt: nil, reliable: false, states: snapshot(tuning: t), matchedExample: nil)
            return result
        }
        let countedGap = previousReliable ? gap : 0
        previousReliable = true; lastReliableAt = timestamp
        let f = oral.features
        // Keep enough actual samples at every supported rate; gaps never synthesize evidence.
        let historyWindow = max(0.6, 2.5 / t.faceHertz)
        recentFeatures.append((timestamp, f)); recentFeatures.removeAll { timestamp - $0.0 > historyWindow }
        let recent = recentFeatures.map(\.1)
        func range(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        // A short mouth-only history suppresses rapidly changing speech without blocking slow posture changes or hand/eye timers.
        let mouthEvidenceUsable = recent.count >= 3
            && range(recent.map(\.mouthOpening)) <= 0.12 && range(recent.map(\.mouthShift)) <= 0.10
            && range(recent.map(\.cornerSlope)) <= 0.12
        var active: Set<HabitKind> = []
        if hand, FacialGeometry.handNearMouth(oral, image: observation.imageSize, radius: t.handMouthRadius) { active.insert(.handMouth) }
        if let reference {
            // Lip tissue height excludes the opening: a fixed exposed-teeth pose is no longer filtered as talking.
            let lipTissueHeight = f.outerLipAspect - f.mouthOpening
            if lips, lipTissueHeight >= 0, f.mouthOpening <= f.outerLipAspect + 0.02,
               reference.outerLipAspect - (reference.mouthOpening ?? 0) - lipTissueHeight >= t.lipChangeThreshold { active.insert(.lipChange) }
            if lips, let base = reference.upperLipThickness, let value = f.upperLipThickness,
               base - value >= t.lipChangeThreshold / 2 { active.insert(.lipChange) }
            if lips, let base = reference.lowerLipThickness, let value = f.lowerLipThickness,
               base - value >= t.lipChangeThreshold / 2 { active.insert(.lipChange) }
            if mouthShiftEnabled {
                let extra = [(f.upperLipAsymmetry, reference.upperLipAsymmetry), (f.lowerLipAsymmetry, reference.lowerLipAsymmetry),
                             (f.innerMouthAsymmetry, reference.innerMouthAsymmetry)].contains { value, base in
                    guard let value, let base else { return false }; return abs(value - base) >= t.facialShiftThreshold
                }
                // Mouth position and corner slope are usable while the mouth is open.
                if abs(f.mouthShift - reference.mouthShift) >= t.facialShiftThreshold
                    || abs(f.cornerSlope - reference.cornerSlope) >= t.facialShiftThreshold
                    || (reference.mouthWidth.flatMap { base in f.mouthWidth.map { abs($0 - base) >= t.facialShiftThreshold } } ?? false) || extra { active.insert(.facialShift) }
            }
        }
        if face, let baseline = reference?.eyelidDifference, let value = f.eyelidDifference,
           abs(value - baseline) >= t.eyelidChangeThreshold { active.insert(.eyelidChange) }
        let matched = examples?.matchesFace(observation.cameraSignature) == true ? examples?.match(f) : nil
        if let matched, matched.action != .mouthShift || mouthShiftEnabled { active.insert(matched.action.habitKind) }
        for kind in HabitKind.allCases {
            let enabled: Bool
            switch kind {
            case .handMouth: enabled = hand
            case .facialShift: enabled = mouthShiftEnabled
            case .eyelidChange: enabled = face
            case .lipChange: enabled = lips
            default: enabled = examples != nil
            }
            guard enabled else { episodes.removeValue(forKey: kind); continue }
            if kind != .handMouth && kind != .eyelidChange && !mouthEvidenceUsable && active.contains(kind) {
                var episode = episodes[kind] ?? Episode()
                episode.previousEvidenceUsable = false
                // A currently visible positive signal is pending observation, never an empty/recovered state.
                if episodes[kind] == nil { episode.wasActive = true }
                episodes[kind] = episode
                continue
            }
            if active.contains(kind) {
                var episode = episodes[kind] ?? Episode()
                if episode.wasActive && episode.previousEvidenceUsable { episode.elapsed += countedGap }
                episode.wasActive = true; episode.previousEvidenceUsable = true; episode.recovery = 0
                episode.exampleLabel = matched?.action.habitKind == kind ? matched?.label : nil
                let threshold = kind == .handMouth ? t.handMouthSeconds : t.lipChangeSeconds
                episode.confirmed = episode.confirmed || episode.elapsed + 0.000001 >= threshold
                episodes[kind] = episode
            } else if var episode = episodes[kind] {
                if !episode.wasActive && episode.previousEvidenceUsable { episode.recovery += countedGap }
                episode.wasActive = false; episode.previousEvidenceUsable = true
                if episode.recovery + 0.000001 >= t.recoverySeconds { episodes.removeValue(forKey: kind) }
                else { episodes[kind] = episode }
            }
        }
        let states = snapshot(tuning: t)
        var prompt: HabitKind?
        for state in states where state.confirmed && !state.recovering {
            if lastPrompt[state.kind].map({ timestamp - $0 >= t.cooldownSeconds }) ?? true {
                lastPrompt[state.kind] = timestamp; prompt = state.kind; break
            }
        }
        if states.isEmpty { summary = "未观察到持续手口、口唇或眼周变化" }
        else {
            let confirmed = states.filter(\.confirmed).count
            summary = confirmed > 0 ? "\(confirmed) 项口部或眼周变化持续中" : "正在独立累计 \(states.count) 项口部或眼周变化"
            if states.allSatisfy(\.recovering) { summary = "口部恢复待确认，持续 \(Int(t.recoverySeconds)) 秒后结束" }
        }
        result = HabitResult(prompt: prompt, reliable: true, states: states, matchedExample: matched)
        return result
    }
    private func snapshot(tuning t: MonitorTuning) -> [HabitState] {
        HabitKind.allCases.compactMap { kind -> HabitState? in
            guard let episode = episodes[kind] else { return nil }
            return HabitState(kind: kind, elapsedSeconds: episode.elapsed,
                thresholdSeconds: kind == .handMouth ? t.handMouthSeconds : t.lipChangeSeconds,
                confirmed: episode.confirmed, recovering: !episode.wasActive, recoverySeconds: episode.recovery, exampleLabel: episode.exampleLabel)
        }
    }

}
