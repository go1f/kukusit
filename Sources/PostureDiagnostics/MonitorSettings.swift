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
    var tuning = MonitorTuning()
    var handMouthMonitoring = true
    var experimentalLipMonitoring = false
    var experimentalFaceMonitoring = false
    var mouthShiftMonitoring = true
    var oralPoseMonitoring = true
    var jawSelfCheck = true
    var bodyBackend: BodyBackend = .mediaPipe
    var pipOnTop = true
    var pipShowsVideo = true
    var pipShowsSkeleton = true
    var pipSize: PiPSize = .small
    var pipCorner: PiPCorner = .topRight
    var pipScreenID = "automatic"
    var resumeOnLaunch = true
    var mirrored = false
    var sustainedSeconds: Double { get { tuning.sustainedSeconds } set { tuning.sustainedSeconds = newValue } }
    var cooldownSeconds: Double { get { tuning.cooldownSeconds } set { tuning.cooldownSeconds = newValue } }
    var reminderConfiguration: ReminderConfiguration { tuning.reminderConfiguration }
    init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tuning, automaticReminders, handMouthMonitoring, experimentalLipMonitoring,
             experimentalFaceMonitoring, mouthShiftMonitoring, oralPoseMonitoring, jawSelfCheck, bodyBackend, pipOnTop, pipShowsVideo, pipShowsSkeleton,
             pipSize, pipCorner, pipScreenID, resumeOnLaunch, mirrored
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // V1 lacks tuning: adopt the requested 5 s / 3° default and preserve window preferences.
        tuning = (try c.decodeIfPresent(MonitorTuning.self, forKey: .tuning) ?? MonitorTuning()).normalized
        automaticReminders = try c.decodeIfPresent(Bool.self, forKey: .automaticReminders) ?? true
        handMouthMonitoring = try c.decodeIfPresent(Bool.self, forKey: .handMouthMonitoring) ?? true
        experimentalLipMonitoring = try c.decodeIfPresent(Bool.self, forKey: .experimentalLipMonitoring) ?? false
        experimentalFaceMonitoring = try c.decodeIfPresent(Bool.self, forKey: .experimentalFaceMonitoring) ?? false
        mouthShiftMonitoring = try c.decodeIfPresent(Bool.self, forKey: .mouthShiftMonitoring) ?? true
        oralPoseMonitoring = try c.decodeIfPresent(Bool.self, forKey: .oralPoseMonitoring) ?? true
        jawSelfCheck = try c.decodeIfPresent(Bool.self, forKey: .jawSelfCheck) ?? true
        bodyBackend = try c.decodeIfPresent(BodyBackend.self, forKey: .bodyBackend) ?? .mediaPipe
        pipOnTop = try c.decodeIfPresent(Bool.self, forKey: .pipOnTop) ?? true
        pipShowsVideo = try c.decodeIfPresent(Bool.self, forKey: .pipShowsVideo) ?? true
        pipShowsSkeleton = try c.decodeIfPresent(Bool.self, forKey: .pipShowsSkeleton) ?? true
        pipSize = try c.decodeIfPresent(PiPSize.self, forKey: .pipSize) ?? .small
        pipCorner = try c.decodeIfPresent(PiPCorner.self, forKey: .pipCorner) ?? .topRight
        pipScreenID = try c.decodeIfPresent(String.self, forKey: .pipScreenID) ?? "automatic"
        resumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumeOnLaunch) ?? true
        // Older releases always saved this value, including their former true default.
        // Preserve saved choices; only a fresh or missing preference adopts the new default.
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .schemaVersion); try c.encode(tuning.normalized, forKey: .tuning)
        try c.encode(automaticReminders, forKey: .automaticReminders)
        try c.encode(handMouthMonitoring, forKey: .handMouthMonitoring)
        try c.encode(experimentalLipMonitoring, forKey: .experimentalLipMonitoring)
        try c.encode(experimentalFaceMonitoring, forKey: .experimentalFaceMonitoring)
        try c.encode(mouthShiftMonitoring, forKey: .mouthShiftMonitoring)
        try c.encode(oralPoseMonitoring, forKey: .oralPoseMonitoring)
        try c.encode(jawSelfCheck, forKey: .jawSelfCheck)
        try c.encode(bodyBackend, forKey: .bodyBackend)
        try c.encode(pipOnTop, forKey: .pipOnTop); try c.encode(pipShowsVideo, forKey: .pipShowsVideo)
        try c.encode(pipShowsSkeleton, forKey: .pipShowsSkeleton); try c.encode(pipSize, forKey: .pipSize)
        try c.encode(pipCorner, forKey: .pipCorner); try c.encode(pipScreenID, forKey: .pipScreenID)
        try c.encode(resumeOnLaunch, forKey: .resumeOnLaunch)
        try c.encode(mirrored, forKey: .mirrored)
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
