import Foundation
import PostureCore

struct MonitoringAlert: Equatable, Identifiable {
    var id: String
    var title: String
    var message: String
    var seconds: Int
    var recovering: Bool
    var recoveryProgress: Double = 0
    var resolved = false
    var showsRecoveryCheckmark = false
    var suspended = false
    var animateRecovery = true
}

struct ReminderPresentationUpdate {
    var alerts: [MonitoringAlert]
    var ongoingIDs: Set<String>
    var recoveredIDs: Set<String> = []
    var enabled = true
    static func recoveredPostureIDs(previous: [ReminderChannelSnapshot], current: [ReminderChannelSnapshot]) -> Set<String> {
        let reminded = Set(previous.filter(\.hasReminded).map(\.channel))
        return Set(current.filter {
            reminded.contains($0.channel) && !$0.hasReminded && $0.isObservable && $0.state == .normal
        }.map { "posture." + $0.channel.rawValue })
    }
}
