import AppKit
import PostureCore

@MainActor enum BannerControllerChecks {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let reminders = ReminderPanelController(router: DisplayRouter())
            let head = MonitoringAlert(id: "posture.head", title: "歪头", message: "头向左扶正", seconds: 8, recovering: false)
            let shoulder = MonitoringAlert(id: "posture.shoulders", title: "高低肩", message: "双肩放平", seconds: 8, recovering: false)
            let ids: Set<String> = [head.id, shoulder.id]
            var checks: [String] = []
            func require(_ condition: Bool, _ message: String) {
                guard condition else { fputs("Banner check failed: \(message)\n", stderr); exit(1) }
            }
            reminders.synchronize([head], recovered: false, ongoingIDs: [head.id])
            require(reminders.visible && reminders.snapshot["canBecomeKey"] as? Bool == false, "initial panel must remain non-key")
            require(reminders.snapshot["ignoresMouseEvents"] as? Bool == false, "panel must accept clicks")
            checks.append("compact clickable nonactivating panel")

            reminders.dismissByUser()
            try? await Task.sleep(nanoseconds: 300_000_000)
            reminders.synchronize([], recovered: false, ongoingIDs: [head.id])
            reminders.synchronize([head], recovered: false, ongoingIDs: [head.id])
            require(!reminders.visible && reminders.showCount == 1, "same episode was redisplayed after dismissal")
            checks.append("dismissal survives missing observation and repeated frames")

            reminders.synchronize([head, shoulder], recovered: false, ongoingIDs: ids)
            require(reminders.visible && reminders.snapshot["presentedIDs"] as? [String] == [shoulder.id], "new shoulder alert must appear independently")
            checks.append("new independent anomaly still appears")
            reminders.dismissByUser()
            let recovering = MonitoringAlert(id: head.id, title: head.title, message: head.message, seconds: 8,
                recovering: true, recoveryProgress: 0.5)
            reminders.synchronize([recovering, shoulder], recovered: false, ongoingIDs: ids)
            require(!reminders.visible, "pending recovery redisplayed a dismissed alert")
            checks.append("pending recovery cannot resurrect dismissed alert")

            reminders.synchronize([], recovered: true, ongoingIDs: [])
            require(reminders.snapshot["acknowledgedIDs"] as? [String] == [], "completed recovery must clear acknowledgement")
            reminders.synchronize([head, shoulder], recovered: false, ongoingIDs: ids)
            require(reminders.visible && reminders.snapshot["presentedIDs"] as? [String] == [head.id, shoulder.id], "fresh episode must display both alerts")
            try? await Task.sleep(nanoseconds: 300_000_000)
            require((reminders.snapshot["panelHeight"] as? CGFloat ?? 0) >= 57, "stacked rows must fit")
            require(reminders.focusPreserved, "panel changed keyboard focus")
            checks.append("confirmed recovery permits a fresh episode; stacked layout preserves focus")
            reminders.hide()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let report: [String: Any] = ["passed": true, "input": "synthetic alerts; no camera or user preferences", "checks": checks]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--banner-report=") }) {
                try? data.write(to: URL(fileURLWithPath: String(flag.dropFirst("--banner-report=".count))), options: .atomic)
            }
            app.terminate(nil)
        }
        app.run()
    }
}
