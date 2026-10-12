import AppKit
import AVFoundation
import PostureCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: DiagnosticModel?
    private var desktop: DesktopCoordinator?
    private var smokeLog: [[String: Any]] = []
    private let appearance = AppAppearance()
    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.start()
        let args = CommandLine.arguments
        let demo = args.contains("--demo") || args.contains("--ui-smoke")
        let model = DiagnosticModel(demo: demo)
        let desktop = DesktopCoordinator(model: model)
        self.model = model; self.desktop = desktop
        if !args.contains("--background-check") { desktop.showMain(expandPreview: true) }
        if !demo, model.settings.resumeOnLaunch, !model.profiles.isEmpty,
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized { model.start() }
        if args.contains("--ui-smoke") { runSmoke(model: model, desktop: desktop) }
        if args.contains("--camera-check") {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.writeReport(["cameraCheck": "needs existing camera permission; no access requested"], flag: "--background-report=")
                NSApplication.shared.terminate(nil); return
            }
            model.settings.automaticReminders = false
            model.start()
        }
        if args.contains("--background-check") || args.contains("--camera-check") {
            schedule(25) {
                let report: [String: Any] = [
                    "input": "live camera; no camera image or raw landmarks saved",
                    "monitoringRunning": model.status == .running, "analyzedFrames": model.frameCount,
                    "referenceMatches": model.matchingProfile != nil, "automaticReminders": model.settings.automaticReminders,
                    "sustainedSeconds": model.settings.sustainedSeconds, "cooldownSeconds": model.settings.cooldownSeconds,
                    "analysisHz": model.analysisHz, "pipelineP95Ms": model.p95Milliseconds,
                    "firstVideoSeconds": model.firstVideoSeconds ?? -1,
                    "firstAnalysisSeconds": model.firstAnalysisSeconds ?? -1, "averageAppCPUPercent": model.averageAppCPU,
                    "computeCapabilities": VisionCompute.report(),
                    "monitorSummary": model.monitorSummary, "monitorDetail": model.monitorDetail ?? "",
                    "faceUsableFraction": model.faceAvailability, "shoulderUsableFraction": model.shoulderAvailability,
                    "judgmentSampleCounts": model.judgmentSampleCounts,
                    "presentation": desktop.presentationSnapshot]
                self.writeReport(report, flag: "--background-report=")
                if args.contains("--exit-after-check") { NSApplication.shared.terminate(nil) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        desktop?.showMain(expandPreview: false); return true
    }
    func applicationWillTerminate(_ notification: Notification) { appearance.stop(); desktop?.shutdown(); model?.shutdown() }

    private func runSmoke(model: DiagnosticModel, desktop: DesktopCoordinator) {
        desktop.showPiP()
        schedule(1) { model.demoScenario = .headTilt }
        schedule(6) { self.record("correction", model: model, desktop: desktop); model.demoScenario = .clear }
        schedule(7.5) { self.record("recovery", model: model, desktop: desktop) }
        schedule(10) { model.demoScenario = .headTilt }
        schedule(16) { self.record("cooldown", model: model, desktop: desktop); model.demoScenario = .turnedAway }
        schedule(18) { self.record("turned-away", model: model, desktop: desktop); model.demoScenario = .croppedShoulder }
        schedule(20) { self.record("head-only", model: model, desktop: desktop); desktop.hidePiP(); desktop.hideMain() }
        schedule(21) { desktop.showMain(expandPreview: true); model.demoScenario = .handNearMouth }
        schedule(25) { self.record("hand-mouth", model: model, desktop: desktop); model.demoScenario = .clear; desktop.hidePiP(); desktop.hideMain() }
        schedule(26) { self.record("hidden", model: model, desktop: desktop) }
        schedule(27) { desktop.showMain(expandPreview: true); model.demoScenario = .headAndShoulderTilt }
        schedule(36) { self.record("persistent-overlap", model: model, desktop: desktop) }
        schedule(37) { model.demoScenario = .shoulderShift }
        schedule(39) { self.record("partial-recovery", model: model, desktop: desktop) }
        schedule(40) { model.demoScenario = .headAndShoulderTilt }
        schedule(45) { self.record("overlap-again", model: model, desktop: desktop) }
        schedule(46) { model.demoScenario = .clear }
        schedule(48) { self.record("all-recovered", model: model, desktop: desktop) }
        schedule(51) { self.record("recovered-hidden", model: model, desktop: desktop) }
        schedule(53) {
            self.record("complete", model: model, desktop: desktop)
            let report: [String: Any] = ["input": "synthetic accelerated demo; no camera or personal calibration changes",
                "snapshots": self.smokeLog, "focusPreserved": desktop.reminders.focusPreserved]
            self.writeReport(report, flag: "--smoke-report=")
            desktop.showMain(expandPreview: false)
        }
    }
    private func record(_ phase: String, model: DiagnosticModel, desktop: DesktopCoordinator) {
        smokeLog.append(["phase": phase, "banner": desktop.reminders.snapshot,
                         "presentation": desktop.presentationSnapshot, "reminderCount": model.reminderCount,
                         "monitorState": model.monitorSummary, "monitorDetail": model.monitorDetail ?? "",
                         "postureChannels": model.postureChannels.map { ["channel": $0.channel.rawValue,
                            "seconds": $0.accumulatedSeconds, "unresolved": $0.isUnresolved, "reminded": $0.hasReminded] }])
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
        if let index = CommandLine.arguments.firstIndex(of: "--update-manifest-check"), CommandLine.arguments.count > index+2 {
            UpdateDiagnostics.check(manifest: CommandLine.arguments[index+1], archive: CommandLine.arguments[index+2])
        }
        if CommandLine.arguments.contains("--bridge-check") { BridgeChecks.run() }
        if CommandLine.arguments.contains("--settings-check") { DiagnosticsChecks.settings() }
        if CommandLine.arguments.contains("--pipeline-check") { DiagnosticsChecks.pipeline() }
        if CommandLine.arguments.contains("--oral-store-check") { DiagnosticsChecks.oralStore() }
        if let index = CommandLine.arguments.firstIndex(of: "--image-check") {
            ImageSampleChecks.run(paths: Array(CommandLine.arguments.dropFirst(index + 1)))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
