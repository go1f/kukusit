import Foundation

public struct ReminderConfiguration: Equatable, Sendable {
    public var sustainedSeconds = 25.0
    public var cooldownSeconds = 180.0
    public var recoverySeconds = 2.0
    public var settleSeconds = 1.0
    public var headEnterDegrees = 8.0
    public var shoulderEnterDegrees = 8.0
    public var exitDegrees = 5.0
    public var maximumGap = 0.5
    public init() {}
}

public enum ReminderKind: String, Codable, Sendable {
    case headTowardLeft, headTowardRight, shoulders
    public var message: String {
        switch self {
        // Native unmirrored Vision roll is positive counterclockwise:
        // positive roll means the person's head leans toward their right.
        case .headTowardLeft: return "头稍微向左侧扶正，放松肩膀。"
        case .headTowardRight: return "头稍微向右侧扶正，放松肩膀。"
        case .shoulders: return "坐直一点，放松肩膀。"
        }
    }
}

public enum ReminderEvent: Equatable, Sendable {
    case correction(ReminderKind), recovered, quiet
}

public enum MonitorState: Equatable, Sendable {
    case inactive
    case unknown(String)
    case normal
    case candidate(ReminderKind, seconds: Int)
    case recovering(ReminderKind, accumulatedSeconds: Int)
    case deviating(ReminderKind)
    public var label: String {
        switch self {
        case .inactive: return "监测已暂停"
        case .unknown: return "暂不可判定"
        case .normal: return "姿态接近参考"
        case .candidate: return "正在观察持续偏移"
        case .recovering: return "待确认恢复"
        case .deviating: return "持续偏离参考"
        }
    }
}

public struct ReminderInput: Sendable {
    public var timestamp: Double
    public var contextID: String
    public var reliable: Bool
    public var quietReason: String
    public var rollDeviation: Double
    public var shoulderDeviation: Double
    public var yawDeviation: Double
    public var pitchDeviation: Double
    public init(timestamp: Double, contextID: String, reliable: Bool, quietReason: String = "识别暂不稳定",
                rollDeviation: Double = 0, shoulderDeviation: Double = 0,
                yawDeviation: Double = 0, pitchDeviation: Double = 0) {
        self.timestamp = timestamp; self.contextID = contextID; self.reliable = reliable; self.quietReason = quietReason
        self.rollDeviation = rollDeviation; self.shoulderDeviation = shoulderDeviation
        self.yawDeviation = yawDeviation; self.pitchDeviation = pitchDeviation
    }
    public var relativeHeadRoll: Double { Geometry.wrapDegrees(rollDeviation - shoulderDeviation) }
}

public struct ReminderResult: Sendable {
    public let state: MonitorState
    public let event: ReminderEvent?
}

public struct ReminderEngine: Sendable {
    public var configuration: ReminderConfiguration
    public private(set) var state: MonitorState = .inactive
    private var previousTimestamp: Double?
    private var previousEligibleTimestamp: Double?
    private var contextID: String?
    private var history: [ReminderInput] = []
    private var candidate: ReminderKind?
    private var badSeconds = 0.0
    private var goodSeconds = 0.0
    private var previousNormalTimestamp: Double?
    private var unstableSince: Double?
    private var episode: ReminderKind?
    private var lastReminderAt: Double?
    public init(configuration: ReminderConfiguration = ReminderConfiguration()) { self.configuration = configuration }

    public mutating func reset() -> ReminderResult {
        previousTimestamp = nil; previousEligibleTimestamp = nil; contextID = nil; history = []
        candidate = nil; badSeconds = 0; goodSeconds = 0; episode = nil; state = .inactive
        previousNormalTimestamp = nil; unstableSince = nil
        // Cooldown survives pause, calibration and setting changes.
        return ReminderResult(state: state, event: .quiet)
    }

    public mutating func observe(_ input: ReminderInput) -> ReminderResult {
        guard input.timestamp.isFinite else { return quiet("观察时间无效") }
        if let previousTimestamp, input.timestamp <= previousTimestamp {
            return quiet("观察时间未更新")
        }
        let gap = previousTimestamp.map { input.timestamp - $0 } ?? 0
        previousTimestamp = input.timestamp
        if contextID != input.contextID {
            let wasConfigured = contextID != nil
            contextID = input.contextID; history = []; previousEligibleTimestamp = nil
            candidate = nil; badSeconds = 0; goodSeconds = 0; episode = nil
            previousNormalTimestamp = nil; unstableSince = nil
            if wasConfigured { return quiet("观看情境已切换，重新观察") }
        }
        if gap > configuration.maximumGap {
            history = []; previousEligibleTimestamp = nil; candidate = nil; badSeconds = 0; goodSeconds = 0
            previousNormalTimestamp = nil; unstableSince = nil
        }
        guard input.reliable,
              [input.rollDeviation, input.shoulderDeviation, input.yawDeviation, input.pitchDeviation].allSatisfy(\.isFinite)
        else { return quiet(input.quietReason) }
        guard abs(input.yawDeviation) <= 20, abs(input.pitchDeviation) <= 18 else {
            return quiet("转头或观看方向变化，保持安静")
        }
        history.append(input)
        history.removeAll { input.timestamp - $0.timestamp > 1.2 }
        let head = input.relativeHeadRoll, shoulder = input.shoulderDeviation
        let isNormal = abs(head) <= configuration.exitDegrees && abs(shoulder) <= configuration.exitDegrees
        let delta = previousEligibleTimestamp.map { min(configuration.maximumGap, input.timestamp - $0) } ?? 0

        if isNormal {
            goodSeconds += previousNormalTimestamp.map { min(configuration.maximumGap, input.timestamp - $0) } ?? 0
            previousNormalTimestamp = input.timestamp
            previousEligibleTimestamp = nil
            unstableSince = nil
            if let active = candidate ?? episode, goodSeconds + 0.000001 < configuration.recoverySeconds {
                state = .recovering(active, accumulatedSeconds: Int(badSeconds))
                return ReminderResult(state: state, event: nil)
            }
            let hadEpisode = episode != nil
            candidate = nil; badSeconds = 0; state = .normal
            if hadEpisode && goodSeconds + 0.000001 >= configuration.recoverySeconds {
                episode = nil
                return ReminderResult(state: state, event: .recovered)
            }
            return ReminderResult(state: state, event: nil)
        }
        previousNormalTimestamp = nil
        goodSeconds = 0
        guard isStable(at: input.timestamp) else {
            // Brief reliable motion pauses accumulation without losing prior abnormal time.
            // Unreliable observations, looking away and long gaps still reset via quiet().
            if unstableSince == nil { unstableSince = input.timestamp }
            previousEligibleTimestamp = nil
            if input.timestamp - (unstableSince ?? input.timestamp) >= configuration.recoverySeconds {
                candidate = nil; badSeconds = 0
            }
            state = .unknown("姿态正在变化或识别波动，保持安静")
            return ReminderResult(state: state, event: .quiet)
        }
        unstableSince = nil

        let next: ReminderKind?
        if abs(shoulder) >= configuration.shoulderEnterDegrees && abs(input.rollDeviation) <= configuration.exitDegrees {
            next = .shoulders
        } else if abs(head) >= configuration.headEnterDegrees {
            next = head > 0 ? .headTowardLeft : .headTowardRight
        } else if abs(shoulder) >= configuration.shoulderEnterDegrees {
            next = .shoulders
        } else if let candidate = candidate ?? episode {
            switch candidate {
            case .headTowardLeft: next = head > configuration.exitDegrees ? candidate : nil
            case .headTowardRight: next = head < -configuration.exitDegrees ? candidate : nil
            case .shoulders: next = abs(shoulder) > configuration.exitDegrees ? candidate : nil
            }
        } else { next = nil }
        guard let next else {
            previousEligibleTimestamp = nil; candidate = nil; badSeconds = 0
            state = .normal
            return ReminderResult(state: state, event: nil)
        }
        let changed = candidate != next
        if changed { candidate = next; badSeconds = 0; previousEligibleTimestamp = nil }
        else { badSeconds += delta }
        previousEligibleTimestamp = input.timestamp
        if badSeconds + 0.000001 < configuration.sustainedSeconds {
            state = .candidate(next, seconds: Int(badSeconds))
            return ReminderResult(state: state, event: changed && episode != nil ? .quiet : nil)
        }
        state = .deviating(next)
        if lastReminderAt.map({ input.timestamp - $0 >= configuration.cooldownSeconds }) ?? true {
            lastReminderAt = input.timestamp; episode = next
            return ReminderResult(state: state, event: .correction(next))
        }
        return ReminderResult(state: state, event: nil)
    }

    private mutating func quiet(_ reason: String) -> ReminderResult {
        history = []; previousEligibleTimestamp = nil; candidate = nil; badSeconds = 0; goodSeconds = 0
        previousNormalTimestamp = nil; unstableSince = nil
        state = .unknown(reason)
        return ReminderResult(state: state, event: .quiet)
    }
    private func isStable(at timestamp: Double) -> Bool {
        guard history.count >= 4, let first = history.first,
              timestamp - first.timestamp >= configuration.settleSeconds else { return false }
        func span(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        return span(history.map(\.relativeHeadRoll)) <= 6
            && span(history.map(\.shoulderDeviation)) <= 6
            && span(history.map(\.yawDeviation)) <= 12 && span(history.map(\.pitchDeviation)) <= 12
    }
}
