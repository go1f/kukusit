import Foundation

struct MonitoringAlert: Equatable, Identifiable {
    var id: String
    var title: String
    var message: String
    var seconds: Int
    var recovering: Bool
}
