import Foundation

public struct ReminderConfiguration: Equatable, Sendable {
    public var sustainedSeconds = 25.0
    public var cooldownSeconds = 180.0
    public var recoverySeconds = 2.0
    public var settleSeconds = 0.5
    public var lossGraceSeconds = 2.0
    public var headEnterDegrees = 4.0
    public var headExitDegrees = 2.0
    public var shoulderEnterDegrees = 8.0
    public var shoulderExitDegrees = 5.0
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
    case waiting(String, accumulatedSeconds: Int)
    case normal
    case slightDeviation
    case candidate(ReminderKind, seconds: Int)
    case recovering(ReminderKind, accumulatedSeconds: Int)
    case deviating(ReminderKind)
    public var label: String {
        switch self {
        case .inactive: return "监测已暂停"
        case .unknown(let reason), .waiting(let reason, _): return reason
        case .normal: return "姿态接近参考"
        case .slightDeviation: return "轻微偏离参考"
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
    public var allowsBriefLoss: Bool
    public var rollDeviation: Double
    // nil means unavailable, never an invented level shoulder line.
    public var shoulderDeviation: Double?
    public var yawDeviation: Double
    public var pitchDeviation: Double
    public init(timestamp: Double, contextID: String, reliable: Bool, quietReason: String = "识别短暂波动",
                allowsBriefLoss: Bool = false,
                rollDeviation: Double = 0, shoulderDeviation: Double? = 0,
                yawDeviation: Double = 0, pitchDeviation: Double = 0) {
        self.timestamp = timestamp; self.contextID = contextID; self.reliable = reliable; self.quietReason = quietReason
        self.allowsBriefLoss = allowsBriefLoss
        self.rollDeviation = rollDeviation; self.shoulderDeviation = shoulderDeviation
        self.yawDeviation = yawDeviation; self.pitchDeviation = pitchDeviation
    }

    public static func make(observation: Observation, metrics: Metrics, baseline: Calibration) -> ReminderInput {
        let allowLoss = observation.faceCount <= 1 && observation.bodyCount <= 1
        guard let roll = metrics.roll else {
            return ReminderInput(timestamp: observation.timestamp, contextID: baseline.id.uuidString,
                reliable: false, quietReason: metrics.faceReason, allowsBriefLoss: allowLoss)
        }
        guard let referenceYaw = baseline.yaw, let referencePitch = baseline.pitch else {
            return ReminderInput(timestamp: observation.timestamp, contextID: baseline.id.uuidString,
                reliable: false, quietReason: "参考缺少观看方向，请重新校准")
        }
        guard let yaw = metrics.yaw, let pitch = metrics.pitch else {
            return ReminderInput(timestamp: observation.timestamp, contextID: baseline.id.uuidString,
                reliable: false, quietReason: "观看方向角度不可用，保持安静", allowsBriefLoss: allowLoss)
        }
        guard abs(yaw) <= 40, abs(pitch) <= 55 else {
            return ReminderInput(timestamp: observation.timestamp, contextID: baseline.id.uuidString,
                reliable: false, quietReason: "脸部侧转或俯仰过大，保持安静")
        }
        return ReminderInput(timestamp: observation.timestamp, contextID: baseline.id.uuidString, reliable: true,
            rollDeviation: Geometry.wrapDegrees(roll - baseline.roll.median),
            shoulderDeviation: metrics.shoulderAngle.flatMap { angle in
                baseline.shoulder.map { Geometry.wrapDegrees(angle - $0.median, period: 180) }
            }, yawDeviation: Geometry.wrapDegrees(yaw - referenceYaw.median),
            pitchDeviation: Geometry.wrapDegrees(pitch - referencePitch.median))
    }
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
    private var suspendedSince: Double?
    private var episode: ReminderKind?
    private var lastReminderAt: Double?
    public init(configuration: ReminderConfiguration = ReminderConfiguration()) { self.configuration = configuration }

    public mutating func reset() -> ReminderResult {
        previousTimestamp = nil; contextID = nil; clearEvidence()
        episode = nil; state = .inactive
        // Cooldown survives pause, calibration and setting changes.
        return ReminderResult(state: state, event: .quiet)
    }

    public mutating func observe(_ input: ReminderInput) -> ReminderResult {
        guard input.timestamp.isFinite else { return quiet("观察时间无效") }
        if let previousTimestamp, input.timestamp <= previousTimestamp { return quiet("观察时间未更新") }
        let gap = previousTimestamp.map { input.timestamp - $0 } ?? 0
        previousTimestamp = input.timestamp
        if contextID != input.contextID {
            let wasConfigured = contextID != nil
            contextID = input.contextID; clearEvidence(); episode = nil
            if wasConfigured { return quiet("观看情境已切换，重新观察") }
        }
        if gap > configuration.maximumGap {
            // Do not count time with no observations, but tolerate brief pipeline stalls.
            previousEligibleTimestamp = nil; previousNormalTimestamp = nil; goodSeconds = 0
            if gap > configuration.lossGraceSeconds { clearEvidence(); episode = nil }
        }
        guard input.reliable else {
            return input.allowsBriefLoss
                ? suspend(input.quietReason, at: input.timestamp)
                : quiet(input.quietReason)
        }
        guard [input.rollDeviation, input.yawDeviation, input.pitchDeviation].allSatisfy(\.isFinite),
              input.shoulderDeviation.map(\.isFinite) ?? true else { return quiet("姿态数值无效") }
        guard abs(input.yawDeviation) <= 28, abs(input.pitchDeviation) <= 35 else {
            return quiet("观看方向偏离参考较大，保持安静")
        }
        history.append(input)
        history.removeAll { input.timestamp - $0.timestamp > 1.2 }
        // Head status uses the same face-to-reference roll shown in the UI.
        // A similar shoulder lean must not cancel visible head deviation into "normal".
        let rawNormal = abs(input.rollDeviation) <= configuration.headExitDegrees
            && (input.shoulderDeviation.map { abs($0) <= configuration.shoulderExitDegrees } ?? true)
        // Show pending recovery immediately; two continuous seconds of real normal samples
        // confirm it. Smoothing must not hide a brief return or count stale normal values.
        if rawNormal, let active = candidate ?? episode,
           active != .shoulders || input.shoulderDeviation != nil {
            return normalResult(at: input.timestamp)
        }
        if !rawNormal { previousNormalTimestamp = nil; goodSeconds = 0 }
        guard history.count >= 3, let first = history.first,
              input.timestamp - first.timestamp + 0.000001 >= configuration.settleSeconds else {
            return suspend("正在收集清晰姿态", at: input.timestamp)
        }
        let rolls = history.map(\.rollDeviation)
        guard stable(rolls, tolerance: 3) else { return suspend("头部角度波动，等待稳定", at: input.timestamp) }
        guard stable(history.map(\.yawDeviation), tolerance: 4), stable(history.map(\.pitchDeviation), tolerance: 4),
              abs(input.yawDeviation - median(history.map(\.yawDeviation))) <= 12,
              abs(input.pitchDeviation - median(history.map(\.pitchDeviation))) <= 12 else {
            return suspend("正在转头或切换观看方向", at: input.timestamp)
        }
        let roll = median(rolls)
        let shoulders = history.compactMap(\.shoulderDeviation)
        // Shoulder jitter cannot block an otherwise clear head observation.
        // A cached shoulder value only classifies head/torso motion; it never accrues shoulder time.
        let lastShoulderAt = history.last(where: { $0.shoulderDeviation != nil })?.timestamp
        let shoulder = shoulders.count >= 3 && stable(shoulders, tolerance: 3)
            && (lastShoulderAt.map({ input.timestamp - $0 <= configuration.lossGraceSeconds }) ?? false)
            ? median(shoulders) : nil
        let head = shoulder.map { Geometry.wrapDegrees(roll - $0) } ?? roll
        let shoulderAvailable = input.shoulderDeviation != nil && shoulder != nil
        let isNormal = abs(roll) <= configuration.headExitDegrees
            && (shoulder.map { abs($0) <= configuration.shoulderExitDegrees } ?? true)
        let delta = previousEligibleTimestamp.map { min(configuration.maximumGap, input.timestamp - $0) } ?? 0

        if isNormal {
            // Missing shoulders cannot confirm recovery of a shoulder episode.
            if (candidate ?? episode) == .shoulders && !shoulderAvailable {
                return suspend("肩线暂不可用，头部可判定", at: input.timestamp)
            }
            if !rawNormal { return suspend("正在调整姿态，等待稳定", at: input.timestamp) }
            return normalResult(at: input.timestamp)
        }
        previousNormalTimestamp = nil; goodSeconds = 0
        let next: ReminderKind?
        if let shoulder, abs(shoulder) >= configuration.shoulderEnterDegrees && abs(roll) <= configuration.headExitDegrees {
            next = .shoulders
        } else if abs(roll) >= configuration.headEnterDegrees {
            // When head and torso lean together, use a general posture correction.
            if let shoulder, abs(shoulder) > configuration.headExitDegrees && abs(head) <= configuration.headExitDegrees {
                next = .shoulders
            } else { next = roll > 0 ? .headTowardLeft : .headTowardRight }
        } else if let shoulder, abs(shoulder) >= configuration.shoulderEnterDegrees {
            next = .shoulders
        } else if let active = candidate ?? episode {
            switch active {
            case .headTowardLeft: next = roll > configuration.headExitDegrees ? active : nil
            case .headTowardRight: next = roll < -configuration.headExitDegrees ? active : nil
            case .shoulders: next = shoulder.map { abs($0) > configuration.shoulderExitDegrees || abs(roll) > configuration.headExitDegrees ? active : nil } ?? nil
            }
        } else { next = nil }
        guard let next else {
            // Values in the entry/exit band are not proof of recovery.
            previousEligibleTimestamp = nil; suspendedSince = nil
            state = .slightDeviation
            return ReminderResult(state: state, event: nil)
        }
        if next == .shoulders && !shoulderAvailable { return suspend("肩线暂不可用，头部可判定", at: input.timestamp) }
        suspendedSince = nil
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

    private mutating func clearEvidence() {
        history = []; previousEligibleTimestamp = nil; candidate = nil; badSeconds = 0; goodSeconds = 0
        previousNormalTimestamp = nil; suspendedSince = nil
    }
    private mutating func normalResult(at timestamp: Double) -> ReminderResult {
        goodSeconds += previousNormalTimestamp.map { min(configuration.maximumGap, timestamp - $0) } ?? 0
        previousNormalTimestamp = timestamp; previousEligibleTimestamp = nil; suspendedSince = nil
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
    private mutating func quiet(_ reason: String) -> ReminderResult {
        clearEvidence()
        state = .unknown(reason)
        return ReminderResult(state: state, event: .quiet)
    }
    private mutating func suspend(_ reason: String, at timestamp: Double) -> ReminderResult {
        if suspendedSince == nil { suspendedSince = timestamp }
        previousEligibleTimestamp = nil; previousNormalTimestamp = nil; goodSeconds = 0
        if timestamp - (suspendedSince ?? timestamp) + 0.000001 >= configuration.lossGraceSeconds {
            candidate = nil; badSeconds = 0
            state = .unknown(reason)
        } else { state = .waiting(reason, accumulatedSeconds: Int(badSeconds)) }
        return ReminderResult(state: state, event: .quiet)
    }
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
    private func stable(_ values: [Double], tolerance: Double) -> Bool {
        let center = median(values)
        let deviations = values.map { abs($0 - center) }.sorted()
        let index = min(deviations.count - 1, Int(ceil(Double(deviations.count) * 0.8)) - 1)
        return median(deviations) <= tolerance && deviations[index] <= tolerance * 2
    }
}
