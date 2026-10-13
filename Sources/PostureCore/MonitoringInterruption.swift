import Foundation
import CoreGraphics

public enum MonitoringInterruption: String, Hashable, Sendable {
    case systemSleep, displaySleep, sessionInactive, screenLocked
}
/// System interruption preserves intent; a manual pause always cancels resumption.
public struct MonitoringInterruptionState: Sendable {
    public private(set) var requestedRunning = false
    public private(set) var blockers: Set<MonitoringInterruption> = []
    public init() {}
    public var canResume: Bool { requestedRunning && blockers.isEmpty }
    @discardableResult public mutating func requestStart() -> Bool { requestedRunning = true; return canResume }
    public mutating func requestPause() { requestedRunning = false }
    public mutating func suspend(_ reason: MonitoringInterruption) { blockers.insert(reason) }
    public mutating func resume(_ reason: MonitoringInterruption) { blockers.remove(reason) }
    // An explicit unlock means the current session is visible and awake. This also
    // handles systems where the paired workspace wake notifications were coalesced.
    public mutating func unlocked() { blockers.removeAll() }
}

public struct FloatingWindowPlacement: Codable, Equatable, Sendable {
    public let displayID: String
    public let xFraction: Double
    public let yFraction: Double
    public private(set) var contentWidth: Double
    public var isValid: Bool {
        !displayID.isEmpty && xFraction.isFinite && yFraction.isFinite && contentWidth.isFinite
            && (0...1).contains(xFraction) && (0...1).contains(yFraction) && (320...800).contains(contentWidth)
    }
    public init(displayID: String, frame: CGRect, visibleFrame: CGRect, contentWidth: Double, margin: Double = 18) {
        self.displayID = displayID; self.contentWidth = min(800, max(320, contentWidth))
        xFraction = min(1, max(0, (frame.minX-visibleFrame.minX-margin) / max(1, visibleFrame.width-frame.width-margin*2)))
        yFraction = min(1, max(0, (frame.minY-visibleFrame.minY-margin) / max(1, visibleFrame.height-frame.height-margin*2)))
    }
    public func changingWidth(_ width: Double) -> Self {
        var copy = self; copy.contentWidth = min(800, max(320, width)); return copy
    }
    public func origin(visibleFrame: CGRect, windowSize: CGSize, margin: Double = 18) -> CGPoint {
        CGPoint(x: visibleFrame.minX + margin + xFraction * max(0, visibleFrame.width-windowSize.width-margin*2),
                y: visibleFrame.minY + margin + yFraction * max(0, visibleFrame.height-windowSize.height-margin*2))
    }
}
