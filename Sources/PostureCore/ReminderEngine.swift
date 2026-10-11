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
    public var yawLimitDegrees = 28.0
    public var pitchLimitDegrees = 35.0
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
    case correction(ReminderKind), recovered, quiet, nudge(String)
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
            shoulderDeviation: (baseline.cameraSignature == observation.cameraSignature ? metrics.shoulderAngle : nil).flatMap { angle in
                baseline.shoulder.map { Geometry.wrapDegrees(angle - $0.median, period: 180) }
            }, yawDeviation: Geometry.wrapDegrees(yaw - referenceYaw.median),
            pitchDeviation: Geometry.wrapDegrees(pitch - referencePitch.median))
    }
}

public enum ReminderChannel: String, Codable, CaseIterable, Sendable {
    case head, shoulders
}

public struct ReminderChannelSnapshot: Equatable, Sendable {
    public let channel: ReminderChannel
    public let kind: ReminderKind?
    public let state: MonitorState
    public let accumulatedSeconds: Double
    public let hasReminded: Bool
    public let isUnresolved: Bool
    // Each channel can become unavailable independently. Missing shoulders must
    // not hide a reliable head reminder, and missing evidence is never recovery.
    public let isObservable: Bool
}

public struct ReminderResult: Sendable {
    public let state: MonitorState
    public let event: ReminderEvent?
    public let channels: [ReminderChannelSnapshot]
    public let events: [ReminderEvent]
    public init(state: MonitorState, event: ReminderEvent?,
                channels: [ReminderChannelSnapshot] = [], events: [ReminderEvent] = []) {
        self.state = state; self.channels = channels
        self.events = events.isEmpty ? event.map { [$0] } ?? [] : events
        self.event = event ?? self.events.first
    }
}

public struct ReminderEngine: Sendable {
    public var configuration: ReminderConfiguration
    public private(set) var state: MonitorState = .inactive
    private var previousTimestamp: Double?
    private var contextID: String?
    private var history: [ReminderInput] = []
    private var head = ChannelEvidence(channel: .head)
    private var shoulders = ChannelEvidence(channel: .shoulders)
    public init(configuration: ReminderConfiguration = ReminderConfiguration()) { self.configuration = configuration }

    private struct ChannelEvidence: Sendable {
        let channel: ReminderChannel
        var state: MonitorState = .inactive
        var candidate: ReminderKind?
        var episode: ReminderKind?
        var badSeconds = 0.0
        var goodSeconds = 0.0
        var previousEligibleTimestamp: Double?
        var previousNormalTimestamp: Double?
        var suspendedSince: Double?
        var lastReminderAt: Double?
        var observable = false
        var activeKind: ReminderKind? { candidate ?? episode }
        var snapshot: ReminderChannelSnapshot {
            ReminderChannelSnapshot(channel: channel, kind: activeKind, state: state,
                accumulatedSeconds: badSeconds, hasReminded: episode != nil,
                isUnresolved: activeKind != nil, isObservable: observable)
        }
        mutating func clearEvidence(clearEpisode: Bool = false) {
            candidate = nil; badSeconds = 0; goodSeconds = 0
            previousEligibleTimestamp = nil; previousNormalTimestamp = nil; suspendedSince = nil
            observable = false
            if clearEpisode { episode = nil }
        }
        mutating func breakContinuity() {
            previousEligibleTimestamp = nil; previousNormalTimestamp = nil; goodSeconds = 0
        }
        mutating func suspend(_ reason: String, at timestamp: Double, configuration: ReminderConfiguration) {
            if suspendedSince == nil { suspendedSince = timestamp }
            breakContinuity(); observable = false
            if timestamp - (suspendedSince ?? timestamp) + 0.000001 >= configuration.lossGraceSeconds {
                candidate = nil; badSeconds = 0
                state = .unknown(reason)
            } else { state = .waiting(reason, accumulatedSeconds: Int(badSeconds)) }
        }
        mutating func normal(at timestamp: Double, configuration: ReminderConfiguration) {
            observable = true; suspendedSince = nil; previousEligibleTimestamp = nil
            guard let active = activeKind else {
                goodSeconds = 0; previousNormalTimestamp = nil; state = .normal
                return
            }
            goodSeconds += previousNormalTimestamp.map { min(configuration.maximumGap, timestamp - $0) } ?? 0
            previousNormalTimestamp = timestamp
            if goodSeconds + 0.000001 < configuration.recoverySeconds {
                state = .recovering(active, accumulatedSeconds: Int(badSeconds))
            } else {
                candidate = nil; episode = nil; badSeconds = 0
                goodSeconds = 0; previousNormalTimestamp = nil; state = .normal
            }
        }
        mutating func abnormal(kind: ReminderKind, at timestamp: Double,
                               configuration: ReminderConfiguration) -> ReminderEvent? {
            observable = true; suspendedSince = nil; goodSeconds = 0; previousNormalTimestamp = nil
            // Direction changes change the instruction, not the head channel's
            // accumulated time. Head and shoulders never share this evidence.
            let delta = previousEligibleTimestamp.map { min(configuration.maximumGap, timestamp - $0) } ?? 0
            if candidate != nil { badSeconds += delta }
            candidate = kind
            if episode != nil { episode = kind }
            previousEligibleTimestamp = timestamp
            guard badSeconds + 0.000001 >= configuration.sustainedSeconds else {
                state = .candidate(kind, seconds: Int(badSeconds)); return nil
            }
            state = .deviating(kind)
            if lastReminderAt.map({ timestamp - $0 >= configuration.cooldownSeconds }) ?? true {
                lastReminderAt = timestamp; episode = kind
                return .correction(kind)
            }
            return nil
        }
    }

    public mutating func reset() -> ReminderResult {
        previousTimestamp = nil; contextID = nil; history = []
        head.clearEvidence(clearEpisode: true); shoulders.clearEvidence(clearEpisode: true)
        head.state = .inactive; shoulders.state = .inactive; state = .inactive
        // Each channel's cooldown survives pause, calibration and setting changes.
        return result(events: [.quiet])
    }

    public mutating func observe(_ input: ReminderInput) -> ReminderResult {
        guard input.timestamp.isFinite else { return quiet("观察时间无效") }
        if let previousTimestamp, input.timestamp <= previousTimestamp { return quiet("观察时间未更新") }
        let gap = previousTimestamp.map { input.timestamp - $0 } ?? 0
        previousTimestamp = input.timestamp
        if contextID != input.contextID {
            let wasConfigured = contextID != nil
            contextID = input.contextID; history = []
            head.clearEvidence(clearEpisode: true); shoulders.clearEvidence(clearEpisode: true)
            if wasConfigured { return quiet("观看情境已切换，重新观察") }
        }
        if gap > configuration.maximumGap {
            // No channel accrues unobserved time, including a brief pipeline stall.
            head.breakContinuity(); shoulders.breakContinuity()
            if gap > configuration.lossGraceSeconds {
                history = []; head.clearEvidence(clearEpisode: true); shoulders.clearEvidence(clearEpisode: true)
            }
        }
        guard input.reliable else {
            return input.allowsBriefLoss
                ? suspend(input.quietReason, at: input.timestamp)
                : quiet(input.quietReason)
        }
        guard [input.rollDeviation, input.yawDeviation, input.pitchDeviation].allSatisfy(\.isFinite),
              input.shoulderDeviation.map(\.isFinite) ?? true else { return quiet("姿态数值无效") }
        guard abs(input.yawDeviation) <= configuration.yawLimitDegrees,
              abs(input.pitchDeviation) <= configuration.pitchLimitDegrees else {
            return quiet("观看方向偏离参考较大，保持安静")
        }
        history.append(input)
        history.removeAll { input.timestamp - $0.timestamp > 1.2 }
        let collected = history.count >= 3 && history.first.map {
            input.timestamp - $0.timestamp + 0.000001 >= configuration.settleSeconds
        } == true
        let directionStable = collected && stable(history.map(\.yawDeviation), tolerance: 4)
            && stable(history.map(\.pitchDeviation), tolerance: 4)
            && abs(input.yawDeviation - median(history.map(\.yawDeviation))) <= 12
            && abs(input.pitchDeviation - median(history.map(\.pitchDeviation))) <= 12
        let hadReminded = head.episode != nil || shoulders.episode != nil
        var events: [ReminderEvent] = []
        // The visible face roll is compared to the face reference independently
        // of the shoulder line. An equal torso lean cannot cancel a head deviation.
        if let event = classify(&head, raw: input.rollDeviation,
            values: history.map(\.rollDeviation), collected: collected, directionStable: directionStable,
            enter: configuration.headEnterDegrees, exit: configuration.headExitDegrees,
            timestamp: input.timestamp, unavailable: "头部暂不可用",
            unstable: "头部角度波动，等待稳定", configuration: configuration) { events.append(event) }
        let shoulderSamples = history.filter { $0.shoulderDeviation != nil }
        let shoulderCollected = collected && shoulderSamples.count >= 3 && shoulderSamples.first.map {
            input.timestamp - $0.timestamp + 0.000001 >= configuration.settleSeconds
        } == true
        if let event = classify(&shoulders, raw: input.shoulderDeviation,
            values: shoulderSamples.compactMap(\.shoulderDeviation), collected: shoulderCollected,
            directionStable: directionStable, enter: configuration.shoulderEnterDegrees,
            exit: configuration.shoulderExitDegrees, timestamp: input.timestamp,
            unavailable: "肩线暂不可用，头部可判定", unstable: "肩线角度波动，等待稳定",
            configuration: configuration) { events.append(event) }
        // Recovery means the last reminded channel has actually recovered; one
        // corrected shoulder must never dismiss a still unresolved head reminder.
        if hadReminded && head.episode == nil && shoulders.episode == nil { events.append(.recovered) }
        state = aggregateState()
        if events.isEmpty && !head.observable && !shoulders.observable { events.append(.quiet) }
        return result(events: events)
    }

    private func classify(_ channel: inout ChannelEvidence, raw: Double?, values: [Double],
                          collected: Bool, directionStable: Bool, enter: Double, exit: Double,
                          timestamp: Double, unavailable: String, unstable: String,
                          configuration: ReminderConfiguration) -> ReminderEvent? {
        guard let raw else { channel.suspend(unavailable, at: timestamp, configuration: configuration); return nil }
        guard collected else {
            channel.suspend("正在收集清晰姿态", at: timestamp, configuration: configuration); return nil
        }
        guard directionStable else {
            channel.suspend("正在转头或切换观看方向", at: timestamp, configuration: configuration); return nil
        }
        // Recovery uses current samples, avoiding a stale smoothed normal value.
        // A brief real return pauses the bad timer without clearing its evidence.
        if abs(raw) <= exit && channel.activeKind != nil {
            channel.normal(at: timestamp, configuration: configuration); return nil
        }
        guard stable(values, tolerance: 3) else {
            channel.suspend(unstable, at: timestamp, configuration: configuration); return nil
        }
        let value = median(values)
        if abs(value) <= exit {
            if abs(raw) <= exit { channel.normal(at: timestamp, configuration: configuration) }
            else { channel.suspend("正在调整姿态，等待稳定", at: timestamp, configuration: configuration) }
            return nil
        }
        if abs(value) >= enter || channel.activeKind != nil {
            let kind: ReminderKind = channel.channel == .shoulders ? .shoulders
                : (value > 0 ? .headTowardLeft : .headTowardRight)
            return channel.abnormal(kind: kind, at: timestamp, configuration: configuration)
        }
        channel.observable = true; channel.suspendedSince = nil; channel.breakContinuity()
        channel.state = .slightDeviation
        return nil
    }

    private func aggregateState() -> MonitorState {
        let evidence = [head, shoulders]
        for item in evidence where item.observable {
            if case .deviating = item.state { return item.state }
        }
        for item in evidence where item.observable {
            if case .recovering = item.state { return item.state }
        }
        for item in evidence where item.observable {
            if case .candidate = item.state { return item.state }
        }
        // An unobservable unresolved channel cannot be reported as recovered.
        if let item = evidence.first(where: { !$0.observable && $0.activeKind != nil }) { return item.state }
        if evidence.contains(where: { $0.observable && $0.state == .slightDeviation }) { return .slightDeviation }
        if head.observable { return .normal }
        return head.state
    }
    private func result(events: [ReminderEvent]) -> ReminderResult {
        ReminderResult(state: state, event: events.first,
            channels: [head.snapshot, shoulders.snapshot], events: events)
    }
    private mutating func quiet(_ reason: String) -> ReminderResult {
        history = []; head.clearEvidence(); shoulders.clearEvidence()
        head.state = .unknown(reason); shoulders.state = .unknown(reason); state = .unknown(reason)
        return result(events: [.quiet])
    }
    private mutating func suspend(_ reason: String, at timestamp: Double) -> ReminderResult {
        head.suspend(reason, at: timestamp, configuration: configuration)
        shoulders.suspend(reason, at: timestamp, configuration: configuration)
        state = aggregateState()
        return result(events: [.quiet])
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
