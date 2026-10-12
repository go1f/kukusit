import AppKit
import Combine
import SwiftUI
import Foundation
import CryptoKit
import PostureCore

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    @Published private(set) var canCheck = false
    @Published private(set) var busy = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastCheck: Date?
    @Published private(set) var message = "后台每天检查一次；发现新版后由你选择安装。"
    @Published private(set) var available: UpdateManifest?
    @Published private(set) var readyPlan: UpdateInstallPlan?
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var updateWindow: NSWindow?
    private var downloadedWorkspace: URL?
    let enabled: Bool

    init(enabled: Bool, defaults: UserDefaults = .standard) {
        self.enabled = enabled; self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        super.init()
        automaticallyChecks = defaults.object(forKey: "nativeUpdateAutomatic") as? Bool ?? true
        lastCheck = defaults.object(forKey: "nativeUpdateLastSuccess") as? Date
        canCheck = enabled
        guard enabled else { message = "演示和诊断模式不检查更新。"; return }
        if let data = try? String(contentsOf: Self.statusURL), !data.isEmpty { message = data }
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIfDue() } }
        // Camera startup remains independent; no network wait on the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now()+15) { [weak self] in self?.checkIfDue() }
    }
    deinit { timer?.invalidate(); session.invalidateAndCancel() }
    static var statusURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PostureDiagnostics/update-status.txt")
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }
    func setAutomaticChecks(_ enabled: Bool) {
        automaticallyChecks = enabled; defaults.set(enabled, forKey: "nativeUpdateAutomatic")
        if !enabled, busy, available == nil { cancel() }
    }
    private func setBusy(_ value: Bool) { busy = value; canCheck = enabled && !value }
    private func checkIfDue() {
        guard automaticallyChecks, !busy else { return }
        let attempt = defaults.object(forKey: "nativeUpdateLastAttempt") as? Date ?? .distantPast
        if Date().timeIntervalSince(attempt) >= 86400 { startCheck(manual: false) }
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        showWindow(); startCheck(manual: true)
    }
    private func startCheck(manual: Bool) {
        guard canCheck, readyPlan == nil else { return }
        setBusy(true); message = "正在检查新版本…"
        defaults.set(Date(), forKey: "nativeUpdateLastAttempt")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.task = nil }
            do {
                guard let urlText = Bundle.main.object(forInfoDictionaryKey: "KukusitUpdateFeedURL") as? String,
                      let url = URL(string: urlText), url.scheme == "https",
                      let keyText = Bundle.main.object(forInfoDictionaryKey: "KukusitUpdatePublicKey") as? String,
                      let key = Data(base64Encoded: keyText) else { throw UpdateFailure.invalidManifest }
                let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.process("暂时无法取得更新信息，请稍后再试。") }
                let item = try UpdateManifest.verified(data, publicKey: key)
                lastCheck = Date(); defaults.set(lastCheck, forKey: "nativeUpdateLastSuccess")
                let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                guard item.build > build else { available = nil; message = "当前已是最新版本。"; return }
                guard item.supports(os: ProcessInfo.processInfo.operatingSystemVersion) else { throw UpdateFailure.unsupportedOS }
                if !manual, defaults.integer(forKey: "nativeUpdateSkippedBuild") == item.build {
                    message = "已跳过版本 \(item.version)，可以手动检查再次查看。"; return
                }
                available = item; message = "发现新版本 \(item.version)，可以下载安装。"
            } catch {
                if Task.isCancelled { message = "已取消，当前应用未改动。" }
                else { message = "检查失败：\(error.localizedDescription)" }
            }
        }
    }
    func skipVersion() {
        guard !busy, let item = available else { return }
        defaults.set(item.build, forKey: "nativeUpdateSkippedBuild")
        if let plan = readyPlan { try? FileManager.default.removeItem(atPath: plan.workspace) }
        readyPlan = nil; downloadedWorkspace = nil; available = nil
        message = "已跳过该版本；手动检查仍可查看。"
    }
    func cancel() { task?.cancel() }
    func downloadUpdate() {
        guard !busy, let item = available, readyPlan == nil else { return }
        setBusy(true); message = "正在下载安装包（约 \(item.size/1_000_000) MB）…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false); self.task = nil }
            var temporary: URL?
            do {
                let (file, response) = try await session.download(from: URL(string: item.url)!)
                temporary = file
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.process("安装包下载失败，请稍后再试。") }
                try Task.checkCancellation()
                let destination = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
                let plan = try await Task.detached(priority: .utility) {
                    try Self.prepare(file: file, item: item, destination: destination)
                }.value
                if Task.isCancelled {
                    try? FileManager.default.removeItem(atPath: plan.workspace); throw CancellationError()
                }
                downloadedWorkspace = URL(fileURLWithPath: plan.workspace); readyPlan = plan
                message = "安装包和应用签名已验证。选择“安装并重新启动”后完成更新。"
                try? FileManager.default.removeItem(at: file)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                message = Task.isCancelled ? "已取消，当前应用未改动。" : "下载或验证失败：\(error.localizedDescription)"
            }
        }
    }
    nonisolated static func prepare(file: URL, item: UpdateManifest, destination: URL) throws -> UpdateInstallPlan {
        let fm = FileManager.default
        let values = try destination.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard destination.pathExtension == "app", values.volumeIsReadOnly != true,
              !destination.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateFailure.installLocation }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(); var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
        guard bytes == item.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw UpdateFailure.invalidArchive }
        let entries = try UpdateInstallation.command("/usr/bin/zipinfo", ["-1", file.path]).split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let path = String(entry)
            return (path.hasPrefix("Kukusit.app/") || path.hasPrefix("__MACOSX/")) && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
        }) else { throw UpdateFailure.invalidArchive }
        let workspace = destination.deletingLastPathComponent().appendingPathComponent(".kukusit-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var success = false; defer { if !success { try? fm.removeItem(at: workspace) } }
        let extracted = workspace.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try UpdateInstallation.command("/usr/bin/ditto", ["-x", "-k", file.path, extracted.path])
        // Framework symlinks may resolve within the app; reject links outside the extraction root.
        let root = extracted.path + "/"
        if let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                guard url.resolvingSymlinksInPath().path.hasPrefix(root) else { throw UpdateFailure.invalidArchive }
            }
        }
        let app = extracted.appendingPathComponent("Kukusit.app")
        try UpdateInstallation.verifyBundle(app, expectedBuild: item.build)
        try UpdateInstallation.verifyBundle(destination, expectedBuild: nil)
        let staged = workspace.appendingPathComponent("next.app")
        try fm.moveItem(at: app, to: staged); try fm.removeItem(at: extracted)
        success = true
        return UpdateInstallPlan(destination: destination.path, staged: staged.path, workspace: workspace.path,
            parentPID: getpid(), expectedBuild: item.build,
            statusFile: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PostureDiagnostics/update-status.txt").path)
    }
    func installAndRestart() {
        guard !busy, let plan = readyPlan else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KukusitUpdateInstaller")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            message = "安装助手缺失，请重新下载应用安装包。"; return
        }
        do {
            let config = URL(fileURLWithPath: plan.workspace).appendingPathComponent("install.json")
            try JSONEncoder().encode(plan).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let process = Process(); process.executableURL = helper; process.arguments = [config.path]
            try process.run(); setBusy(true); message = "正在退出并安装更新…"
            NSApplication.shared.terminate(nil)
        } catch { message = "安装未启动：\(error.localizedDescription)" }
    }
    private func showWindow() {
        if updateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Kukusit 更新"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppUpdateSettingsView(updater: self))
            window.center(); updateWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true); updateWindow?.makeKeyAndOrderFront(nil)
    }
}

struct AppUpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Form {
            Section("Kukusit") {
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                Toggle("自动检查新版本", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
                    .disabled(!updater.enabled)
                Text("每天在后台检查，不自动安装，也不会上传摄像头画面、校准数据或口部示范。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("检查更新…", action: { updater.checkForUpdates() }).disabled(!updater.canCheck)
                if let item = updater.available {
                    Text("新版本 \(item.version)").font(.headline)
                    Text(item.notes).font(.caption).textSelection(.enabled)
                    if updater.readyPlan == nil { Button("下载安装更新") { updater.downloadUpdate() }.disabled(updater.busy) }
                    Button("跳过这个版本") { updater.skipVersion() }.disabled(updater.busy)
                }
                if updater.readyPlan != nil { Button("安装并重新启动") { updater.installAndRestart() }.disabled(updater.busy) }
                if updater.busy { ProgressView(); Button("取消") { updater.cancel() } }
                Text(updater.message).font(.callout).textSelection(.enabled)
                if let date = updater.lastCheck {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("安装与重新启动") {
                Text("发现新版本后可以立即更新、稍后提醒或跳过该版本。安装时重新启动应用，镜像选择、敏感度、校准和个人示范都会保留。")
                Text("如果正从安装镜像中运行，请先把应用拖到“应用程序”。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("查看 GitHub 发布记录", destination: URL(string: "https://github.com/go1f/kukusit/releases")!)
            }
        }.formStyle(.grouped)
    }
}
