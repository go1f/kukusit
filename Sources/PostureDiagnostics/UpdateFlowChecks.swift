import AppKit
import Combine
import Foundation
import PostureCore

/// Uses only a loopback fixture server, isolated preferences and an installer spy.
@MainActor enum UpdateFlowChecks {
    static func run(server: URL) {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let report = try await scenarios(server: server)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                app.terminate(nil)
            } catch { fputs("Update flow checks failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.run()
    }
    private static func require(_ condition: Bool, _ text: String) throws {
        if !condition { throw UpdateFailure.process(text) }
    }
    private static func wait(_ text: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw UpdateFailure.process("Timed out: \(text)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private static func scenarios(server: URL) async throws -> [String: Any] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kukusit-flow-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "kukusit-update-flow-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "nativeUpdateAutomatic")
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let item = UpdateManifest(version: "99.0.0", build: 99999,
            url: server.appendingPathComponent("package").absoluteString, size: 2_097_152,
            sha256: String(repeating: "a", count: 64), notes: "Synthetic update")
        var downloads = 0, preparations = 0, installs = 0
        var preparedWorkspaces: [URL] = []
        func plan() throws -> UpdateInstallPlan {
            let workspace = root.appendingPathComponent(".kukusit-update-\(UUID())")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            preparedWorkspaces.append(workspace)
            return UpdateInstallPlan(destination: root.appendingPathComponent("Kukusit.app").path,
                staged: workspace.appendingPathComponent("next.app").path, workspace: workspace.path,
                parentPID: 1, expectedBuild: item.build, statusFile: root.appendingPathComponent("status").path)
        }
        let liveDownload: (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) = { url, progress in
            downloads += 1
            return try await UpdateDownload.fetch(url, configuration: session.configuration, progress: progress)
        }
        let operations = AppUpdateOperations(check: { item }, download: liveDownload,
            prepare: { _, _, _ in preparations += 1; return try plan() }, install: { _ in installs += 1 })
        let updater = AppUpdater(enabled: true, defaults: defaults, operations: operations)
        updater.startCheck(manual: false)
        try await wait("background check", until: { !updater.busy })
        try require(updater.available != nil && downloads == 0 && installs == 0, "Checking alone installed an update")
        var received: [Int64] = []
        let subscription = updater.$downloadProgress.compactMap { $0?.received }.sink { received.append($0) }
        defer { subscription.cancel() }
        updater.downloadUpdate(); updater.downloadUpdate()
        do {
            try await wait("intermediate download progress", until: {
                guard let p = updater.downloadProgress else { return false }
                return p.received > 0 && p.fraction < 1
            })
        } catch {
            throw UpdateFailure.process("\(error.localizedDescription); phase=\(updater.phase), message=\(updater.message), bytes=\(received)")
        }
        try require(updater.canCancel && !updater.canCheck, "Download controls are inconsistent")
        try await wait("automatic install handoff", until: { updater.phase == .installing })
        try require(downloads == 1 && preparations == 1 && installs == 1, "One click did not cause exactly one handoff")
        try require(zip(received, received.dropFirst()).allSatisfy { $0 <= $1 }, "Download progress went backwards")
        try require(Set(received.filter { $0 > 0 && $0 < item.size }).count >= 2, "Real transfer did not publish intermediate progress")
        try require(updater.downloadProgress?.percent == 100 && !updater.canCancel && updater.busy,
                    "Installing state became idle or allowed cancellation")

        let cancelled = AppUpdater(enabled: true, defaults: defaults, operations: operations)
        cancelled.startCheck(manual: true)
        try await wait("check before cancellation", until: { !cancelled.busy })
        cancelled.downloadUpdate()
        try await wait("download before cancellation", until: { (cancelled.downloadProgress?.received ?? 0) > 0 })
        cancelled.cancel()
        try await wait("download cancellation", until: { !cancelled.busy })
        try require(installs == 1 && preparations == 1 && cancelled.readyPlan == nil && cancelled.canCheck,
                    "Cancelled download reached installation")

        let quickDownload: (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) = { url, _ in
            let file = root.appendingPathComponent("download-\(UUID()).zip")
            try Data("fixture".utf8).write(to: file)
            return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var verifyingWorkspace: URL?
        let preparing = AppUpdater(enabled: true, defaults: defaults, operations: AppUpdateOperations(
            check: { item }, download: quickDownload, prepare: { _, _, _ in
                let prepared = try plan(); verifyingWorkspace = URL(fileURLWithPath: prepared.workspace)
                // Real signature verification is detached and may finish after the user cancels.
                await Task.detached { try? await Task.sleep(nanoseconds: 250_000_000) }.value
                return prepared
            }, install: { _ in installs += 1 }))
        preparing.startCheck(manual: true)
        try await wait("check before verification cancellation", until: { !preparing.busy })
        preparing.downloadUpdate()
        try await wait("verification started", until: { verifyingWorkspace != nil })
        preparing.cancel()
        try await wait("verification cancellation", until: { !preparing.busy })
        try require(installs == 1 && preparing.readyPlan == nil && !fm.fileExists(atPath: verifyingWorkspace!.path),
                    "Cancelled verification left a plan or installed")

        let rejected = AppUpdater(enabled: true, defaults: defaults, operations: AppUpdateOperations(
            check: { item }, download: quickDownload, prepare: { _, _, _ in throw UpdateFailure.invalidArchive },
            install: { _ in installs += 1 }))
        rejected.startCheck(manual: true)
        try await wait("check before verification rejection", until: { !rejected.busy })
        rejected.downloadUpdate()
        try await wait("verification rejection", until: { !rejected.busy })
        try require(installs == 1 && rejected.readyPlan == nil, "Invalid archive reached installer")

        var retryAttempts = 0, retryDownloads = 0
        let retry = AppUpdater(enabled: true, defaults: defaults, operations: AppUpdateOperations(
            check: { item }, download: { url, progress in retryDownloads += 1; return try await quickDownload(url, progress) },
            prepare: { _, _, _ in try plan() }, install: { _ in
                retryAttempts += 1
                if retryAttempts == 1 { throw UpdateFailure.process("Injected helper launch failure") }
            }))
        retry.startCheck(manual: true)
        try await wait("check before helper failure", until: { !retry.busy })
        retry.downloadUpdate()
        try await wait("helper failure", until: { !retry.busy })
        try require(retry.readyPlan != nil && retry.message.contains("安装未启动"), "Failed helper lost the verified package")
        retry.installAndRestart()
        try require(retryAttempts == 2 && retryDownloads == 1 && retry.phase == .installing,
                    "Installer retry downloaded twice or did not hand off")
        try require((try fm.contentsOfDirectory(atPath: root.path)).allSatisfy { !$0.hasPrefix("download-") },
                    "Temporary download files leaked")
        return ["passed": true, "input": "loopback fixture bytes, isolated preferences and installer spy; no live app replaced",
            "intermediateProgressSamples": Set(received.filter { $0 > 0 && $0 < item.size }).count,
            "checks": ["background check never installs", "real download delegate reports monotonic bytes and percent",
                "one click installs exactly once; repeat click ignored", "install handoff stays busy",
                "download cancellation prevents installation", "verification cancellation cleans staging",
                "invalid archive never installs", "failed helper can retry without another download", "temporary files cleaned"]]
    }
}
