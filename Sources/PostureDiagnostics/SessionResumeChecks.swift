import Foundation
import AppKit
import AVFoundation
import PostureCore

@MainActor enum SessionResumeChecks {
    static func run() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            fputs("Existing camera permission required; no new access requested.\n", stderr); exit(1)
        }
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = DiagnosticModel()
            defer { model.shutdown() }
            model.settings.automaticReminders = false
            var phases: [[String: Any]] = []
            func waitUntil(_ test: () -> Bool) async throws {
                let end = Date().addingTimeInterval(12)
                while !test() {
                    guard Date() < end else { throw UpdateFailure.process("Timed out waiting for capture state") }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            do {
                model.start()
                try await waitUntil { model.status == .running && model.frameCount > 0 }
                phases.append(["phase": "running", "frames": model.frameCount])
                model.suspendForSystem(.screenLocked)
                model.suspendForSystem(.displaySleep)
                precondition(!model.status.isActive && model.settings.resumeOnLaunch)
                model.resumeFromSystem(.displaySleep)
                try await Task.sleep(nanoseconds: 300_000_000)
                precondition(!model.status.isActive)
                phases.append(["phase": "still locked", "imageCleared": model.frame == nil])
                model.resumeFromUnlock()
                try await waitUntil { model.status == .running && model.frameCount > 0 }
                phases.append(["phase": "resumed", "frames": model.frameCount])
                model.suspendForSystem(.screenLocked); model.pause()
                let count = model.frameCount
                model.resumeFromUnlock(); model.resumeFromSystem(.systemSleep)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                precondition(!model.status.isActive && model.frameCount == count && !model.settings.resumeOnLaunch)
                phases.append(["phase": "manual pause preserved", "frames": count])
                let data = try JSONSerialization.data(withJSONObject: ["passed": true, "input": "simulated system events with real capture; no images or feature vectors saved", "phases": phases], options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                model.shutdown(); app.terminate(nil)
            } catch { model.shutdown(); fputs("Session resume failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
