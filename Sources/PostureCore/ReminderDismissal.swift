import Foundation
import CoreGraphics

/// A user dismissal silences every reminder for 30 monotonic seconds, even if
/// the current episode recovers or a different abnormality appears meanwhile.
public struct ReminderDismissal: Sendable {
    public private(set) var acknowledged: Set<String> = []
    public private(set) var mutedUntil: Double?
    public init() {}
    public mutating func reconcile(ongoingIDs: Set<String>, at timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        if let mutedUntil, timestamp >= mutedUntil { self.mutedUntil = nil; acknowledged = [] }
        else { acknowledged.formIntersection(ongoingIDs) }
    }
    public mutating func dismiss(_ ids: Set<String>, at timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        acknowledged.formUnion(ids)
        mutedUntil = max(mutedUntil ?? timestamp, timestamp + 30)
    }
    public func allows(_ id: String, at timestamp: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        mutedUntil.map { timestamp >= $0 } ?? true
    }
}

public enum ReminderPlacement {
    public static func frame(screen: CGRect, visible: CGRect, singleScreen: Bool, safeTop: Double, size: CGSize) -> CGRect {
        let top = singleScreen ? screen.maxY-safeTop-1 : visible.maxY-8
        return CGRect(x: screen.midX-size.width/2, y: top-size.height, width: size.width, height: size.height)
    }
}
