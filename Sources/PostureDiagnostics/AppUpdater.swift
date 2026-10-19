import AppKit
import Combine
import SwiftUI
import Foundation
import CryptoKit
import PostureCore

enum AppUpdatePhase {
    case idle, checking, downloading, verifying, installing
    var label: String {
        switch self {
        case .idle: return ""
        case .checking: return "正在检查新版本…"
        case .downloading: return "正在下载安装包…"
        case .verifying: return "正在校验安装包和应用签名…"
        case .installing: return "正在安装并重新启动…"
        }
    }
}
struct UpdateDownloadProgress {
    let received: Int64
    let total: Int64
    var fraction: Double { min(1, max(0, Double(received) / Double(max(1, total)))) }
    var percent: Int { Int(fraction * 100) }
    var sizes: String {
        ByteCountFormatter.string(fromByteCount: received, countStyle: .file) + " / "
            + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
@MainActor struct AppUpdateOperations {
    var check: () async throws -> UpdateManifest
    var download: (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
    var prepare: (URL, UpdateManifest, URL) async throws -> UpdateInstallPlan
    var install: (UpdateInstallPlan) throws -> Void
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    @Published private(set) var canCheck = false
    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var downloadProgress: UpdateDownloadProgress?
    @Published private(set) var cancellationRequested = false
    var busy: Bool { phase != .idle }
    var canCancel: Bool { busy && phase != .installing && !cancellationRequested }
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastCheck: Date?
    @Published private(set) var message = "后台每天检查一次；发现新版后由你选择安装。"
    @Published private(set) var available: UpdateManifest?
    @Published private(set) var readyPlan: UpdateInstallPlan?
    private let defaults: UserDefaults
    private let session: URLSession
    private let operations: AppUpdateOperations
    private var operationID: UUID?
    private var lastProgressAt = -Double.infinity
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var updateWindow: NSWindow?
    private var mascotWindow: NSWindow?
    private var downloadedWorkspace: URL?
    let enabled: Bool

    init(enabled: Bool, defaults: UserDefaults = .standard, operations: AppUpdateOperations? = nil) {
        self.enabled = enabled; self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        self.operations = operations ?? AppUpdateOperations(
            check: { try await Self.fetchManifest(session: session) },
            download: { url, progress in
                try await UpdateDownload.fetch(url, configuration: session.configuration, progress: progress)
            },
            prepare: { file, item, destination in
                try await Task.detached(priority: .utility) {
                    try Self.prepare(file: file, item: item, destination: destination)
                }.value
            },
            install: { try Self.launchInstaller($0) })
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
    private func setPhase(_ phase: AppUpdatePhase) {
        self.phase = phase; canCheck = enabled && !busy && readyPlan == nil
    }
    nonisolated private static func fetchManifest(session: URLSession) async throws -> UpdateManifest {
        guard let urlText = Bundle.main.object(forInfoDictionaryKey: "KukusitUpdateFeedURL") as? String,
              let url = URL(string: urlText), url.scheme == "https",
              let keyText = Bundle.main.object(forInfoDictionaryKey: "KukusitUpdatePublicKey") as? String,
              let key = Data(base64Encoded: keyText) else { throw UpdateFailure.invalidManifest }
        let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.process("暂时无法取得更新信息，请稍后再试。") }
        return try UpdateManifest.verified(data, publicKey: key)
    }
    private func checkIfDue() {
        guard automaticallyChecks, !busy else { return }
        let attempt = defaults.object(forKey: "nativeUpdateLastAttempt") as? Date ?? .distantPast
        if Date().timeIntervalSince(attempt) >= 86400 { startCheck(manual: false) }
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        showWindow(); startCheck(manual: true)
    }
    func startCheck(manual: Bool) {
        guard canCheck, readyPlan == nil else { return }
        downloadProgress = nil; cancellationRequested = false; setPhase(.checking); message = phase.label
        defaults.set(Date(), forKey: "nativeUpdateLastAttempt")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.setPhase(.idle); self.task = nil; self.cancellationRequested = false }
            do {
                let item = try await operations.check()
                try Task.checkCancellation()
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
        message = "已跳过该版本；手动检查仍可查看。"; setPhase(.idle)
    }
    func cancel() {
        guard canCancel else { return }
        cancellationRequested = true; message = "正在取消更新…"; task?.cancel()
    }
    private func recordProgress(_ received: Int64, total: Int64, operation: UUID) {
        guard operationID == operation, phase == .downloading, !cancellationRequested,
              received >= (downloadProgress?.received ?? 0) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastProgressAt >= 0.1 || received >= total else { return }
        lastProgressAt = time
        downloadProgress = UpdateDownloadProgress(received: received, total: total)
    }
    func downloadUpdate() {
        guard !busy, let item = available, readyPlan == nil else { return }
        let operation = UUID(); operationID = operation; lastProgressAt = -Double.infinity
        cancellationRequested = false
        downloadProgress = UpdateDownloadProgress(received: 0, total: item.size)
        setPhase(.downloading); message = "下载完成并通过校验后将自动安装、重新启动。"
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.phase != .installing { self.setPhase(.idle); self.downloadProgress = nil }
                self.task = nil; self.operationID = nil; self.cancellationRequested = false
            }
            var temporary: URL?
            do {
                let (file, response) = try await operations.download(URL(string: item.url)!) { [weak self] received in
                    Task { @MainActor in self?.recordProgress(received, total: item.size, operation: operation) }
                }
                temporary = file
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.process("安装包下载失败，请稍后再试。") }
                try Task.checkCancellation()
                downloadProgress = UpdateDownloadProgress(received: item.size, total: item.size)
                setPhase(.verifying); message = phase.label
                let destination = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
                let plan = try await operations.prepare(file, item, destination)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(atPath: plan.workspace); throw CancellationError()
                }
                downloadedWorkspace = URL(fileURLWithPath: plan.workspace); readyPlan = plan
                try? FileManager.default.removeItem(at: file); temporary = nil
                try beginInstallation(plan)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                if phase == .installing { setPhase(.idle) }
                message = Task.isCancelled ? "已取消，当前应用未改动。"
                    : readyPlan != nil ? "安装未启动：\(error.localizedDescription)" : "下载或验证失败：\(error.localizedDescription)"
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
    private func beginInstallation(_ plan: UpdateInstallPlan) throws {
        setPhase(.installing); message = phase.label
        try operations.install(plan)
    }
    func installAndRestart() {
        guard !busy, let plan = readyPlan else { return }
        do { try beginInstallation(plan) }
        catch { setPhase(.idle); message = "安装未启动：\(error.localizedDescription)" }
    }
    private static func launchInstaller(_ plan: UpdateInstallPlan) throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KukusitUpdateInstaller")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw UpdateFailure.process("安装助手缺失，请重新下载应用安装包。")
        }
        let config = URL(fileURLWithPath: plan.workspace).appendingPathComponent("install.json")
        try JSONEncoder().encode(plan).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let process = Process(); process.executableURL = helper; process.arguments = [config.path]
        try process.run()
        NSApplication.shared.terminate(nil)
    }
    fileprivate func showMascot() {
        if mascotWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "偶遇小兽"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MascotEasterEggView())
            window.center(); mascotWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true); mascotWindow?.makeKeyAndOrderFront(nil)
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
                    .contextMenu {
                        Button("和小兽打个招呼", action: updater.showMascot)
                    }
                Toggle("自动检查新版本", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
                    .disabled(!updater.enabled)
                Text("每天在后台检查，不自动安装，也不会上传摄像头画面、校准数据或口部示范。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("检查更新…", action: { updater.checkForUpdates() }).disabled(!updater.canCheck)
                if let item = updater.available {
                    Text("新版本 \(item.version)").font(.headline)
                    Text(item.notes).font(.caption).textSelection(.enabled)
                    if updater.readyPlan == nil, !updater.busy {
                        Button("下载安装更新") { updater.downloadUpdate() }
                        Text("点击后将下载、校验并自动安装，完成时会重新启动应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !updater.busy { Button("跳过这个版本") { updater.skipVersion() } }
                }
                if updater.readyPlan != nil, !updater.busy {
                    Button("重试安装并重新启动") { updater.installAndRestart() }
                }
                if updater.phase == .downloading, let progress = updater.downloadProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("正在下载安装包")
                            Spacer()
                            Text("\(progress.percent)%").monospacedDigit()
                        }
                        ProgressView(value: progress.fraction).progressViewStyle(.linear)
                            .accessibilityLabel("安装包下载进度").accessibilityValue("\(progress.percent)%")
                        Text(progress.sizes).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if updater.busy { ProgressView(updater.phase.label) }
                if updater.busy, updater.phase != .installing {
                    Button(updater.cancellationRequested ? "正在取消…" : "取消更新") { updater.cancel() }
                        .disabled(!updater.canCancel)
                }
                Text(updater.message).font(.callout).textSelection(.enabled)
                if let date = updater.lastCheck {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("安装与重新启动") {
                Text("发现新版本后可以立即更新、稍后提醒或跳过该版本。点击“下载安装更新”后无需再次确认，下载和校验通过即安装并重新启动。镜像选择、敏感度、校准和个人示范都会保留。")
                Text("如果正从安装镜像中运行，请先把应用拖到“应用程序”。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("查看 GitHub 发布记录", destination: URL(string: "https://github.com/go1f/kukusit/releases")!)
            }
        }.formStyle(.grouped)
    }
}

private struct MascotEasterEggView: View {
    var body: some View {
        VStack(spacing: 12) {
            if let url = Bundle.main.url(forResource: "SeatedMascot", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 76, height: 76)
                    .accessibilityLabel("坐姿小兽")
            }
            Text("起来活动一下吧。").font(.callout)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
