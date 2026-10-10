import Foundation
import PostureCore

final class ReminderChecks {
    private func input(_ time: Double, roll: Double = 14, shoulder: Double = 0, yaw: Double = 0,
                       reliable: Bool = true, context: String = "reference") -> ReminderInput {
        ReminderInput(timestamp: time, contextID: context, reliable: reliable,
                      rollDeviation: roll, shoulderDeviation: shoulder, yawDeviation: yaw)
    }
    private func feed(_ engine: inout ReminderEngine, start: Double, seconds: Double,
                      make: (Double) -> ReminderInput) -> [ReminderEvent] {
        (0..<Int(seconds * 6)).compactMap { engine.observe(make(start + Double($0) / 6)).event }
    }
    func testShortDeviationDoesNotRemind() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 24) { self.input($0) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testSustainedHeadTiltUsesPhysicalCorrectionDirection() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 30) { self.input($0) }
        expectEqual(events.filter { if case .correction = $0 { return true }; return false }, [.correction(.headTowardLeft)])
        engine = ReminderEngine()
        let opposite = feed(&engine, start: 0, seconds: 30) { self.input($0, roll: -14) }
        expectTrue(opposite.contains(.correction(.headTowardRight)))
    }
    func testPersistentDeviationRepeatsOnlyAfterThreeMinutes() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 300) { self.input($0) }
        expectEqual(events.filter { if case .correction = $0 { return true }; return false }.count, 2)
    }
    func testUnreliableIntervalBreaksPersistence() {
        var engine = ReminderEngine()
        var events = feed(&engine, start: 0, seconds: 15) { self.input($0) }
        events += feed(&engine, start: 15, seconds: 1) { self.input($0, reliable: false) }
        events += feed(&engine, start: 16, seconds: 15) { self.input($0) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testTimeGapDoesNotContributeToPersistence() {
        var engine = ReminderEngine()
        var events = feed(&engine, start: 0, seconds: 15) { self.input($0) }
        events += feed(&engine, start: 100, seconds: 15) { self.input($0) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testTurningAwayStaysQuiet() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 40) { self.input($0, yaw: 30) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
        if case .unknown = engine.state {} else { expectTrue(false) }
    }
    func testJitterStaysQuiet() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 40) { self.input($0, roll: Int($0 * 6) % 2 == 0 ? 10 : 24) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testSwitchingReferencesBreaksPersistence() {
        var engine = ReminderEngine()
        var events = feed(&engine, start: 0, seconds: 15) { self.input($0) }
        events += feed(&engine, start: 15, seconds: 15) { self.input($0, context: "laptop-reference") }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testShoulderShiftDoesNotInventHeadDirection() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 30) { self.input($0, roll: 0, shoulder: 12) }
        expectTrue(events.contains(.correction(.shoulders)))
        expectFalse(events.contains(.correction(.headTowardRight)))
    }
    func testWholeBodyLeanDoesNotInventIndependentNeckTilt() {
        var engine = ReminderEngine()
        let events = feed(&engine, start: 0, seconds: 30) { self.input($0, roll: 12, shoulder: 12) }
        expectTrue(events.contains(.correction(.shoulders)))
        expectFalse(events.contains(.correction(.headTowardLeft)))
    }
    func testRecoveryHappensOnceAndUnknownIsNotRecovery() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 30) { self.input($0) }
        let unknown = feed(&engine, start: 30, seconds: 2) { self.input($0, reliable: false) }
        expectFalse(unknown.contains(.recovered))
        let normal = feed(&engine, start: 32, seconds: 6) { self.input($0, roll: 0) }
        expectEqual(normal.filter { $0 == .recovered }.count, 1)
    }
    func testPauseResetKeepsCooldown() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 30) { self.input($0) }
        _ = engine.reset()
        let next = feed(&engine, start: 35, seconds: 30) { self.input($0) }
        expectFalse(next.contains { if case .correction = $0 { return true }; return false })
    }
    func testHysteresisKeepsEpisodeWithoutRepeatedAlerts() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 30) { self.input($0) }
        let band = feed(&engine, start: 30, seconds: 10) { self.input($0, roll: 6) }
        expectFalse(band.contains(.recovered))
        switch engine.state { case .deviating, .candidate: break; default: expectTrue(false) }
    }
    func testSubsecondRecoveryRetainsAccumulation() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 18) { self.input($0) }
        let before = engine.state
        _ = feed(&engine, start: 18, seconds: 0.8) { self.input($0, roll: 0) }
        if case .recovering(_, let seconds) = engine.state { expectTrue(seconds >= 16) }
        else { expectTrue(false) }
        let events = feed(&engine, start: 18.8, seconds: 12) { self.input($0) }
        expectTrue(events.contains(.correction(.headTowardLeft)))
        if case .candidate(_, let seconds) = before { expectTrue(seconds >= 16) }
        else { expectTrue(false) }
    }
    func testTwoSecondRecoveryClearsPendingAccumulation() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 18) { self.input($0) }
        _ = feed(&engine, start: 18, seconds: 3) { self.input($0, roll: 0) }
        expectEqual(engine.state, .normal)
        let events = feed(&engine, start: 21, seconds: 15) { self.input($0) }
        expectFalse(events.contains { if case .correction = $0 { return true }; return false })
    }
    func testBriefRecoveryDoesNotEmitRecovered() {
        var engine = ReminderEngine()
        _ = feed(&engine, start: 0, seconds: 30) { self.input($0) }
        let events = feed(&engine, start: 30, seconds: 1) { self.input($0, roll: 0) }
        expectFalse(events.contains(.recovered))
        if case .recovering = engine.state {} else { expectTrue(false) }
    }
    func testCompactPiPHeightScalesWithVideoWidth() {
        expectEqual(WindowLayout.pipHeight(width: 360, visual: true), 299.25, accuracy: 0.001)
        expectEqual(WindowLayout.pipHeight(width: 440, visual: true), 344.25, accuracy: 0.001)
        expectEqual(WindowLayout.pipHeight(width: 360, visual: false), 100, accuracy: 0.001)
    }
}
