import AppKit
import AVFoundation
import PostureCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: DiagnosticModel?
    private var desktop: DesktopCoordinator?
    private var smokeLog: [[String: Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let demo = args.contains("--demo") || args.contains("--ui-smoke")
        let model = DiagnosticModel(demo: demo)
        let desktop = DesktopCoordinator(model: model)
        self.model = model; self.desktop = desktop
        if demo || args.contains("--show-settings") { desktop.showMain(expandPreview: false) }
        if !demo, model.settings.resumeOnLaunch, !model.profiles.isEmpty,
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized { model.start() }
        if args.contains("--ui-smoke") { runSmoke(model: model, desktop: desktop) }
        if args.contains("--background-check") {
            schedule(12) {
                let report: [String: Any] = [
                    "input": "live camera; no camera image or raw landmarks saved",
                    "monitoringRunning": model.status == .running, "analyzedFrames": model.frameCount,
                    "referenceMatches": model.matchingProfile != nil, "automaticReminders": model.settings.automaticReminders,
                    "sustainedSeconds": model.settings.sustainedSeconds, "cooldownSeconds": model.settings.cooldownSeconds,
                    "analysisHz": model.analysisHz, "pipelineP95Ms": model.p95Milliseconds,
                    "presentation": desktop.presentationSnapshot]
                self.writeReport(report, flag: "--background-report=")
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        desktop?.showMain(expandPreview: false); return true
    }
    func applicationWillTerminate(_ notification: Notification) { desktop?.shutdown(); model?.shutdown() }

    private func runSmoke(model: DiagnosticModel, desktop: DesktopCoordinator) {
        desktop.showPiP()
        schedule(1) { model.demoScenario = .headTilt }
        schedule(6) { self.record("correction", model: model, desktop: desktop); model.demoScenario = .clear }
        schedule(7.5) { self.record("recovery", model: model, desktop: desktop) }
        schedule(10) { model.demoScenario = .headTilt }
        schedule(16) { self.record("cooldown", model: model, desktop: desktop); model.demoScenario = .turnedAway }
        schedule(18) { self.record("turned-away", model: model, desktop: desktop); desktop.hidePiP(); desktop.hideMain() }
        schedule(19) {
            self.record("hidden", model: model, desktop: desktop)
            let report: [String: Any] = ["input": "synthetic accelerated demo; no camera or personal calibration changes",
                "snapshots": self.smokeLog, "focusPreserved": desktop.reminders.focusPreserved]
            self.writeReport(report, flag: "--smoke-report=")
            desktop.showMain(expandPreview: false)
        }
    }
    private func record(_ phase: String, model: DiagnosticModel, desktop: DesktopCoordinator) {
        smokeLog.append(["phase": phase, "banner": desktop.reminders.snapshot,
                         "presentation": desktop.presentationSnapshot, "reminderCount": model.reminderCount,
                         "monitorState": model.monitorState.label])
    }
    private func writeReport(_ report: [String: Any], flag: String) {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(flag) }),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: String(argument.dropFirst(flag.count))), options: .atomic)
    }
    private func schedule(_ seconds: Double, action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { action() }
    }
}

@main
enum PostureDiagnosticsApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--bridge-check") { BridgeChecks.run() }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
