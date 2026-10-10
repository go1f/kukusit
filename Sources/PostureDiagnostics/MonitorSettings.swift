import Foundation
import PostureCore

enum PiPSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
    var width: Double { switch self { case .small: return 360; case .medium: return 440; case .large: return 560 } }
    var height: Double { switch self { case .small: return 340; case .medium: return 390; case .large: return 460 } }
}
enum PiPCorner: String, Codable, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self { case .topRight: return "右上"; case .topLeft: return "左上"; case .bottomRight: return "右下"; case .bottomLeft: return "左下" }
    }
}

struct MonitorSettings: Codable, Equatable {
    var automaticReminders = true
    var sustainedSeconds = 25.0
    var cooldownSeconds = 180.0
    var pipOnTop = true
    var pipShowsVideo = true
    var pipShowsSkeleton = true
    var pipSize: PiPSize = .small
    var pipCorner: PiPCorner = .topRight
    var pipScreenID = "automatic"
    var resumeOnLaunch = true
    var reminderConfiguration: ReminderConfiguration {
        var configuration = ReminderConfiguration()
        configuration.sustainedSeconds = min(60, max(20, sustainedSeconds))
        configuration.cooldownSeconds = min(600, max(120, cooldownSeconds))
        return configuration
    }
    static func load() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: "monitorSettingsV1"),
              let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) else { return MonitorSettings() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "monitorSettingsV1") }
    }
}
