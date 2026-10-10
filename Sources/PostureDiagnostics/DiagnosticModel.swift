import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import PostureCore

@MainActor
final class DiagnosticModel: ObservableObject {
    @Published var status: CameraStatus = .idle
    @Published var frame: AnalysisPacket?
    @Published var metrics: Metrics?
    @Published var mirrored = true
    @Published var selectedContext: ViewingContext = .upperMonitor
    @Published var profiles: [String: Calibration] = [:]
    @Published var calibrationProgress: Double?
    @Published var calibrationMessage = "看上方外接屏，保持你选定的舒适参考姿态约 20 秒。"
    @Published var notice: String?
    @Published var frameCount = 0
    @Published var faceValidCount = 0
    @Published var shoulderValidCount = 0
    @Published var analysisHz = 0.0
    @Published var p95Milliseconds = 0.0
    @Published var elapsedSeconds = 0.0
    @Published var isDemo = false
    @Published var bodyBackend: BodyBackend = PoseWorker.isAvailable ? .mediaPipe : .appleVision
    let mediaPipeAvailable = PoseWorker.isAvailable
    @Published var demoScenario: DemoScenario = .clear
    @Published var observationIsFresh = false
    @Published var previewExpanded = false
    private(set) var renderingImageRequested = false
    private(set) var renderingSkeletonRequested = false
    @Published var monitorState: MonitorState = .inactive
    @Published private var monitoringBaseline: Calibration?
    @Published var reminderCount = 0
    private(set) var judgmentSampleCounts: [String: Int] = [:]
    @Published var settings = MonitorSettings.load() {
        didSet {
            if !acceleratedDemo && !isDemo { settings.save() }
            let configuration = effectiveReminderConfiguration
            if reminderEngine.configuration != configuration || oldValue.automaticReminders != settings.automaticReminders {
                reminderEngine.configuration = configuration
                applyReminderResult(reminderEngine.reset())
            }
            onSettingsChanged?(oldValue, settings)
        }
    }
    var onReminderEvent: ((ReminderEvent) -> Void)?
    var onSettingsChanged: ((MonitorSettings, MonitorSettings) -> Void)?
    var onWindowClosed: (() -> Void)?
    private var reminderEngine = ReminderEngine()
    private let acceleratedDemo = CommandLine.arguments.contains("--ui-smoke")
    private let camera = CameraController()
    private var collector: CalibrationCollector?
    private var archiveURL: URL?
    private var tickTimer: Timer?
    private var demoTimer: Timer?
    private var startedAt: Double?
    private var frameTimes: [Double] = []
    private var latencies: [Double] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private weak var diagnosticWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?
    private var pendingStart = false

    init(demo: Bool = false) {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true).appendingPathComponent("PostureDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            archiveURL = root.appendingPathComponent("calibration-v1.json")
            if let url = archiveURL, FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(CalibrationArchive.self, from: Data(contentsOf: url))
                if archive.schemaVersion == 1 { profiles = archive.profiles }
                else { notice = "校准文件版本不兼容，请重新校准。" }
            }
        } catch { notice = "校准文件无法读取：\(error.localizedDescription)" }
        reminderEngine.configuration = effectiveReminderConfiguration
        camera.onStatus = { [weak self] value in
            guard let self else { return }
            // All CameraController delivery closures are invoked on the main queue.
            self.status = value
            if value == .running {
                self.pendingStart = false
                if self.startedAt == nil { self.startedAt = ProcessInfo.processInfo.systemUptime }
            } else if !value.isActive {
                self.pendingStart = false
                self.analysisHz = 0
                self.clearCurrentObservation()
                self.cancelCalibration(message: "观察已暂停，校准未保存。")
                self.applyReminderResult(self.reminderEngine.reset())
            }
        }
        camera.onFrame = { [weak self] packet in
            guard let self, !self.isDemo, self.status.isActive else { return }
            self.receive(packet)
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause(reason: "系统休眠或会话已离开，恢复后请重新开始。") }
            })
        }
        // loginwindow's distributed lock signal supplements workspace sleep/session signals.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.pause(reason: "屏幕锁定，已停止摄像头。") } }
        if demo { startDemo() }
    }

    var profile: Calibration? { profiles[selectedContext.rawValue] }
    var matchingProfile: Calibration? {
        if isDemo { return DemoFrame.calibration }
        guard let profile, let signature = frame?.observation.cameraSignature,
              signature == profile.cameraSignature else { return nil }
        return profile
    }
    var canCalibrate: Bool { !isDemo && status == .running && observationIsFresh && metrics?.faceUsable == true && collector == nil }
    var hasStarted: Bool { status.isActive || isDemo || pendingStart }
    var monitorSummary: String {
        if !hasStarted { return status.title }
        if calibrationProgress != nil { return "正在校准 · 提醒暂缓" }
        if !settings.automaticReminders { return "观察中 · 提醒已关闭" }
        if case .normal = monitorState, monitoringScopeDetail != nil { return "头部接近参考" }
        return monitorState.label
    }
    var monitorDetail: String? {
        guard hasStarted, collector == nil, settings.automaticReminders else { return nil }
        if case .waiting(_, let seconds) = monitorState, seconds > 0 {
            return "已累计偏离 \(seconds) 秒；短暂波动保留计时，这段时间不累计。"
        }
        if case .candidate(_, let seconds) = monitorState {
            return "已累计偏离 \(seconds) / \(Int(effectiveReminderConfiguration.sustainedSeconds)) 秒"
                + (monitoringScopeDetail.map { " · " + $0 } ?? "")
        }
        if case .normal = monitorState { return monitoringScopeDetail }
        if case .slightDeviation = monitorState { return "偏移处于恢复阈值和提醒阈值之间，继续观察。" }
        if case .deviating = monitorState { return monitoringScopeDetail }
        return nil
    }
    private var monitoringScopeDetail: String? {
        guard let monitoringBaseline else { return nil }
        if monitoringBaseline.shoulder == nil { return "仅监测头部：当前参考没有肩线" }
        if metrics?.shouldersUsable != true { return "仅监测头部：\(metrics?.shoulderReason ?? "肩线暂不可用")" }
        return nil
    }
    var isAcceleratedDemo: Bool { acceleratedDemo && isDemo }
    var faceAvailability: Double { frameCount > 0 ? Double(faceValidCount) / Double(frameCount) : 0 }
    var shoulderAvailability: Double { frameCount > 0 ? Double(shoulderValidCount) / Double(frameCount) : 0 }
    var rollDeviation: Double? {
        guard observationIsFresh, let value = metrics?.roll, let baseline = (monitoringBaseline ?? matchingProfile)?.roll else { return nil }
        return Geometry.wrapDegrees(value - baseline.median)
    }
    var shoulderDeviation: Double? {
        guard observationIsFresh, let value = metrics?.shoulderAngle, let baseline = (monitoringBaseline ?? matchingProfile)?.shoulder else { return nil }
        return Geometry.wrapDegrees(value - baseline.median, period: 180)
    }

    func start() {
        stopDemo()
        clearCurrentObservation()
        resetStats()
        notice = nil
        pendingStart = true
        status = .starting
        settings.resumeOnLaunch = true
        applyReminderResult(reminderEngine.reset())
        camera.start(backend: bodyBackend)
    }
    func pause(reason: String = "已停止采集并清除预览画面。") {
        stopDemo()
        pendingStart = false
        camera.stop(reason: reason)
        status = .paused(reason)
        analysisHz = 0
        clearCurrentObservation()
        cancelCalibration(message: "观察已暂停，校准未保存。")
        settings.resumeOnLaunch = false
        applyReminderResult(reminderEngine.reset())
    }
    func backendDidChange() {
        if !isDemo { pause(reason: "肩部模型已切换，请重新开始观察；不同模型的参考会分别校验。") }
    }
    func attachWindow(_ window: NSWindow) {
        guard diagnosticWindow !== window else { return }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        diagnosticWindow = window
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                      object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.previewExpanded = false
                self?.onWindowClosed?()
            }
        }
    }
    func shutdown() {
        tickTimer?.invalidate(); demoTimer?.invalidate()
        camera.shutdown()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    func beginCalibration() {
        guard canCalibrate, let packet = frame else { return }
        collector = CalibrationCollector(context: selectedContext, startedAt: ProcessInfo.processInfo.systemUptime,
                                         signature: packet.observation.cameraSignature)
        calibrationProgress = 0
        calibrationMessage = "请看\(selectedContext.label)中心，保持舒适参考姿态。"
        notice = nil
        applyReminderResult(reminderEngine.reset())
    }
    func cancelCalibration(message: String = "校准已取消，保留之前的参考。") {
        if collector != nil { calibrationMessage = message }
        collector = nil; calibrationProgress = nil
    }
    func removeProfile() {
        guard collector == nil else { return }
        let previous = profiles
        profiles.removeValue(forKey: selectedContext.rawValue)
        do { try persistProfiles(); calibrationMessage = "已清除该观看情境的参考。" }
        catch { profiles = previous; notice = "清除参考失败：\(error.localizedDescription)" }
    }
    private func persistProfiles() throws {
        guard let url = archiveURL else {
            throw NSError(domain: "PostureStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问本地校准目录。"])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(CalibrationArchive(profiles: profiles)).write(to: url, options: .atomic)
    }

    private func receive(_ packet: AnalysisPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - packet.observation.timestamp <= 1 else { return }
        frame = packet
        let evaluated = QualityGate.evaluate(packet.observation)
        metrics = evaluated
        observationIsFresh = true
        frameCount += 1
        if evaluated.faceUsable { faceValidCount += 1 }
        if evaluated.shouldersUsable { shoulderValidCount += 1 }
        frameTimes.append(packet.observation.timestamp)
        frameTimes.removeAll { now - $0 > 5 }
        if frameTimes.count >= 2, let first = frameTimes.first, let last = frameTimes.last, last > first {
            analysisHz = Double(frameTimes.count - 1) / (last - first)
        }
        latencies.append(packet.inferenceMilliseconds)
        if latencies.count > 120 { latencies.removeFirst(latencies.count - 120) }
        let sorted = latencies.sorted()
        p95Milliseconds = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        collector?.consume(packet.observation, metrics: evaluated)
        evaluateReminder(packet, metrics: evaluated)
        judgmentSampleCounts[monitorSummary, default: 0] += 1
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if hasStarted, let startedAt { elapsedSeconds = now - startedAt }
        if let timestamp = frame?.observation.timestamp, now - timestamp > 1 {
            clearCurrentObservation()
            analysisHz = 0
            applyReminderResult(reminderEngine.observe(ReminderInput(timestamp: now, contextID: "stale",
                                                                    reliable: false, quietReason: "画面过期，保持安静")))
        }
        if let collector {
            calibrationProgress = collector.progress(at: now)
            if now >= collector.startedAt + collector.duration {
                do {
                    let baseline = try collector.finish(at: now)
                    let previous = profiles
                    profiles[baseline.context.rawValue] = baseline
                    do { try persistProfiles() }
                    catch { profiles = previous; throw error }
                    calibrationMessage = baseline.shoulder != nil
                        ? "已保存\(baseline.context.label)的头部与肩线参考。"
                        : "已保存\(baseline.context.label)的头部参考；双肩未达到稳定校准条件。"
                } catch {
                    calibrationMessage = error.localizedDescription
                }
                self.collector = nil; calibrationProgress = nil
                applyReminderResult(reminderEngine.reset())
            }
        }
    }
    private func clearCurrentObservation() { frame = nil; metrics = nil; observationIsFresh = false; monitoringBaseline = nil }
    func setRendering(image: Bool, skeleton: Bool) {
        renderingImageRequested = image; renderingSkeletonRequested = skeleton
        camera.setRendering(image: image, faceLandmarks: skeleton)
        if !image, let existing = frame, existing.image != nil {
            frame = AnalysisPacket(generation: existing.generation, observation: existing.observation, image: nil,
                                   inferenceMilliseconds: existing.inferenceMilliseconds, cameraName: existing.cameraName,
                                   bodyBackendName: existing.bodyBackendName)
        }
    }
    private var effectiveReminderConfiguration: ReminderConfiguration {
        var configuration = settings.reminderConfiguration
        if acceleratedDemo && isDemo {
            configuration.sustainedSeconds = 3; configuration.cooldownSeconds = 12
            configuration.recoverySeconds = 1; configuration.settleSeconds = 0.5
        }
        return configuration
    }
    private func applyReminderResult(_ result: ReminderResult) {
        if monitorState != result.state { monitorState = result.state }
        if let event = result.event {
            if case .correction = event { reminderCount += 1 }
            onReminderEvent?(event)
        }
    }
    private func evaluateReminder(_ packet: AnalysisPacket, metrics: Metrics) {
        guard settings.automaticReminders, collector == nil else {
            applyReminderResult(reminderEngine.reset()); return
        }
        let observation = packet.observation
        let baseline = isDemo ? DemoFrame.calibration : CalibrationReferenceSelector.choose(
            profiles: Array(profiles.values), cameraSignature: observation.cameraSignature,
            yaw: metrics.yaw, pitch: metrics.pitch, previousID: monitoringBaseline?.id, preferredContext: selectedContext)
        if monitoringBaseline != baseline { monitoringBaseline = baseline }
        guard let baseline else {
            applyReminderResult(reminderEngine.observe(ReminderInput(timestamp: observation.timestamp, contextID: "no-reference",
                reliable: false, quietReason: "请先完成个人校准"))); return
        }
        let input = ReminderInput.make(observation: observation, metrics: metrics, baseline: baseline)
        applyReminderResult(reminderEngine.observe(input))
    }
    private func resetStats() {
        frameCount = 0; faceValidCount = 0; shoulderValidCount = 0
        judgmentSampleCounts = [:]
        analysisHz = 0; p95Milliseconds = 0; elapsedSeconds = 0
        frameTimes = []; latencies = []; startedAt = nil
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
    func exportSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "posture-diagnostics.json"
        panel.title = "导出诊断数值摘要"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // A modal save panel can suspend default-mode timers; read the clock directly.
            let exportedElapsed = hasStarted ? startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? elapsedSeconds : elapsedSeconds
            let report: [String: Any] = [
                "schemaVersion": 1, "generatedAtUTC": ISO8601DateFormatter().string(from: Date()),
                "inputKind": isDemo ? "syntheticDemo" : "camera",
                "cameraName": frame?.cameraName ?? "notActive",
                "bodyBackend": frame?.bodyBackendName ?? bodyBackend.label,
                "reminderCount": reminderCount,
                "monitorState": monitorState.label,
                "monitorDetail": monitorDetail ?? "",
                "judgmentSampleCounts": judgmentSampleCounts,
                "previewImageRequested": renderingImageRequested,
                "skeletonRenderingRequested": renderingSkeletonRequested,
                "lastFrameHasImage": frame?.image != nil,
                "analysisFrameCount": frameCount, "faceUsableFrameCount": faceValidCount,
                "shoulderUsableFrameCount": shoulderValidCount,
                "faceUsableFraction": faceAvailability, "shoulderUsableFraction": shoulderAvailability,
                "elapsedSeconds": exportedElapsed, "recentAnalysisHz": analysisHz,
                "recentPipelineP95Milliseconds": p95Milliseconds,
                "note": "Aggregated diagnostic values only. No images, video or frame-by-frame landmarks. These fractions describe analyzed frames, not all captured frames or medical accuracy."
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            notice = "已导出数值摘要。"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }

    func startDemo() {
        camera.stop(reason: "演示模式：摄像头未启动。")
        cancelCalibration()
        resetStats()
        isDemo = true; startedAt = ProcessInfo.processInfo.systemUptime
        reminderEngine.configuration = effectiveReminderConfiguration
        applyReminderResult(reminderEngine.reset())
        status = .idle
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitDemoFrame() }
        }
        if let demoTimer { RunLoop.main.add(demoTimer, forMode: .common) }
        emitDemoFrame()
    }
    private func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil; isDemo = false
        reminderEngine.configuration = effectiveReminderConfiguration
    }
    private func emitDemoFrame() {
        guard isDemo else { return }
        let packet = DemoFrame.packet(scenario: demoScenario, timestamp: ProcessInfo.processInfo.systemUptime)
        var observation = packet.observation
        if !renderingSkeletonRequested { observation.faceLandmarks = [] }
        receive(AnalysisPacket(generation: packet.generation, observation: observation,
                               image: renderingImageRequested ? packet.image : nil,
                               inferenceMilliseconds: packet.inferenceMilliseconds, cameraName: packet.cameraName,
                               bodyBackendName: packet.bodyBackendName))
    }
}
