import AppKit
import PostureCore

@MainActor enum BannerControllerChecks {
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var time = 0.0
            let reminders = ReminderPanelController(router: DisplayRouter(), now: { time }, presentsOnScreen: false)
            let head = MonitoringAlert(id: "posture.head", title: "歪头", message: "头向左扶正", seconds: 8, recovering: false)
            let shoulder = MonitoringAlert(id: "posture.shoulders", title: "高低肩", message: "双肩放平", seconds: 8, recovering: false)
            let ids: Set<String> = [head.id, shoulder.id]
            var checks: [String] = []
            func require(_ condition: Bool, _ message: String) {
                guard condition else { fputs("Banner check failed: \(message)\n", stderr); exit(1) }
            }
            @MainActor func update(_ alerts: [MonitoringAlert], ongoing: Set<String>, recovered: Set<String> = [], enabled: Bool = true) {
                reminders.synchronize(ReminderPresentationUpdate(alerts: alerts, ongoingIDs: ongoing, recoveredIDs: recovered, enabled: enabled))
            }
            update([head], ongoing: [head.id])
            require(reminders.visible && reminders.snapshot["canBecomeKey"] as? Bool == false, "initial panel must remain non-key")
            let initialWidth = reminders.snapshot["targetWidth"] as! CGFloat
            var recovering = head; recovering.recovering = true; recovering.recoveryProgress = 0.5
            recovering.message = "不应替换原有调整语"
            time = 0.5; update([recovering], ongoing: [head.id])
            require(reminders.snapshot["messages"] as? [String] == [head.message], "recovery changed the instruction")
            require(reminders.snapshot["targetWidth"] as? CGFloat == initialWidth, "progress changed the width")
            require(reminders.snapshot["cornerRadius"] as? CGFloat == 20, "corner radius must be fixed")
            checks.append("recovery preserves instruction, size and corner radius")

            time = 1; update([], ongoing: [head.id])
            require(reminders.visible && reminders.snapshot["suspendedIDs"] as? [String] == [head.id], "brief dropout hid the banner")
            require(reminders.snapshot["recoveryProgress"] as? [Double] == [0.5], "missing evidence must freeze recovery progress")
            time = 1.8; update([head], ongoing: [head.id])
            require(reminders.visible && reminders.showCount == 1, "brief dropout restarted presentation")
            checks.append("brief tracking loss does not flash off and on")

            time = 2; update([head, shoulder], ongoing: ids)
            let expandedHeight = reminders.snapshot["targetHeight"] as! CGFloat
            require(expandedHeight >= 67, "stacked rows do not fit")
            time = 2.5; update([shoulder], ongoing: [shoulder.id], recovered: [head.id])
            require(reminders.snapshot["resolvedIDs"] as? [String] == [head.id], "independent recovery not shown")
            require(reminders.snapshot["targetHeight"] as? CGFloat == expandedHeight, "partial recovery shrank the banner")
            time = 3.5; update([], ongoing: [], recovered: ids)
            require(reminders.visible && reminders.snapshot["resolvedIDs"] as? [String] == [head.id, shoulder.id], "completed rings closed too early")
            time = 6.6; update([], ongoing: [], recovered: ids)
            require(!reminders.visible, "completed banner did not finish its hold")
            checks.append("independent completion holds full rings for 3 seconds without shrinking")

            time = 7; update([head], ongoing: [head.id]); reminders.dismissByUser()
            let count = reminders.showCount
            time = 7.1; update([head, shoulder], ongoing: ids); reminders.preview(); reminders.handle(.nudge("放松下颌"))
            require(!reminders.visible && reminders.showCount == count, "new anomaly or nudge bypassed global mute")
            time = 8; update([], ongoing: [], recovered: ids)
            time = 36.999; update([shoulder], ongoing: [shoulder.id])
            require(!reminders.visible, "recovery reset the 30-second quiet period")
            time = 37; update([shoulder], ongoing: [shoulder.id])
            require(reminders.visible, "fresh reliable anomaly could not remind after 30 seconds")
            checks.append("30-second global dismissal includes new anomalies and self-checks")

            let recoveredCount = reminders.recoveryCount
            time = 38; update([], ongoing: [shoulder.id])
            require(reminders.visible, "unknown state skipped short grace")
            time = 40.1; update([], ongoing: [shoulder.id])
            require(!reminders.visible && reminders.recoveryCount == recoveredCount, "unknown state was falsely reported as recovery")
            time = 41; update([head], ongoing: [head.id])
            update([], ongoing: [], enabled: false)
            require(!reminders.visible && reminders.focusPreserved, "manual pause must hide immediately without taking focus")
            checks.append("prolonged uncertainty hides quietly; pause is immediate")
            try? await Task.sleep(nanoseconds: 350_000_000)
            let report: [String: Any] = ["passed": true, "input": "synthetic alerts and monotonic test clock; no camera or personal preferences", "checks": checks]
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
