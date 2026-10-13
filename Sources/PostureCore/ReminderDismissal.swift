import Foundation
import CoreGraphics

/// A click acknowledges the current episodes, including episodes temporarily
/// hidden by poor tracking. New abnormality types can still be presented.
public struct ReminderDismissal: Sendable {
    public private(set) var acknowledged: Set<String> = []
    public init() {}
    public mutating func reconcile(ongoingIDs: Set<String>) { acknowledged.formIntersection(ongoingIDs) }
    public mutating func dismiss(_ ids: Set<String>) { acknowledged.formUnion(ids) }
    public func allows(_ id: String) -> Bool { !acknowledged.contains(id) }
}

public enum ReminderPlacement {
    public static func frame(screen: CGRect, visible: CGRect, singleScreen: Bool, safeTop: Double, size: CGSize) -> CGRect {
        let top = singleScreen ? screen.maxY-safeTop-1 : visible.maxY-8
        return CGRect(x: screen.midX-size.width/2, y: top-size.height, width: size.width, height: size.height)
    }
}
