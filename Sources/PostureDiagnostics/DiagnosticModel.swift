import Foundation
import AppKit
import AVFoundation
import Darwin
import Combine
import UniformTypeIdentifiers
import PostureCore

@MainActor
final class DiagnosticModel: ObservableObject {
    @Published var status: CameraStatus = .idle
    @Published var frame: AnalysisPacket?
    @Published var metrics: Metrics?
    var mirrored: Bool { get { settings.mirrored } set { settings.mirrored = newValue } }
    @Published var selectedContext: ViewingContext = .upperMonitor {
        didSet { if oldValue != selectedContext { cancelOralRecording() } }
    }
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
    @Published private(set) var demoPaused = false
    @Published var bodyBackend: BodyBackend = PoseWorker.isAvailable ? .mediaPipe : .appleVision
    let mediaPipeAvailable = PoseWorker.isAvailable
    @Published var demoScenario: DemoScenario = .clear
    @Published var observationIsFresh = false
    @Published var previewExpanded = false
    private(set) var renderingImageRequested = false
    private(set) var renderingSkeletonRequested = false
    @Published var monitorState: MonitorState = .inactive
    @Published private(set) var postureChannels: [ReminderChannelSnapshot] = []
    @Published private(set) var habitStates: [HabitState] = []
    let oralSamples: OralSampleStore
    private var habitsReliable = false
    private var recoveryConfirmed = false
    @Published private var monitoringBaseline: Calibration?
    @Published var reminderCount = 0
    private(set) var judgmentSampleCounts: [String: Int] = [:]
    @Published var settings = MonitorSettings.load() {
        didSet {
            if !acceleratedDemo && !isDemo && !diagnosticRun { settings.save() }
            let configuration = effectiveReminderConfiguration
            if reminderEngine.configuration != configuration || oldValue.automaticReminders != settings.automaticReminders {
                reminderEngine.configuration = configuration
                applyReminderResult(reminderEngine.reset())
            }
            onSettingsChanged?(oldValue, settings)
            configureCameraAnalysis()
            if oldValue.automaticReminders != settings.automaticReminders
                || oldValue.handMouthMonitoring != settings.handMouthMonitoring || oldValue.tuning != settings.tuning
                || oldValue.experimentalLipMonitoring != settings.experimentalLipMonitoring
                || oldValue.experimentalFaceMonitoring != settings.experimentalFaceMonitoring
                || oldValue.mouthShiftMonitoring != settings.mouthShiftMonitoring
                || oldValue.oralPoseMonitoring != settings.oralPoseMonitoring {
                habitEngine.reset(); habitStates = []; habitsReliable = false; recoveryConfirmed = false
            }
            refreshReminderPresentation()
        }
    }
    var onReminderEvent: ((ReminderEvent) -> Void)?
    var onReminderAlertsChanged: (([MonitoringAlert], Bool) -> Void)?
    var onSettingsChanged: ((MonitorSettings, MonitorSettings) -> Void)?
    var onWindowClosed: (() -> Void)?
    private var reminderEngine = ReminderEngine()
    private var habitEngine = HabitEngine()
    @Published private(set) var habitSummary = "口部观察未开始"
    @Published private(set) var firstVideoSeconds: Double?
    @Published private(set) var firstAnalysisSeconds: Double?
    @Published private(set) var averageAppCPU = 0.0
    private var cpuOrigin = 0.0
    private var requestedStartAt: Double?
    private var nextJawCheck: Double?
    var cameraSession: AVCaptureSession { camera.previewSession }
    @Published private(set) var computeSummary = "Apple Vision 自动调度"
    var facialReferenceAvailable: Bool { (monitoringBaseline ?? matchingProfile)?.facialReference != nil }
    private var currentOralExamples: OralPoseExamples? {
        guard settings.oralPoseMonitoring,
              var library = oralSamples.library(context: monitoringBaseline?.context ?? selectedContext,
                signature: frame?.observation.cameraSignature) else { return nil }
        library.maximumDistance = settings.tuning.normalized.oralMatchDistance
        library.minimumMargin = settings.tuning.normalized.oralMatchMargin
        return library
    }
    var facialMetricsSummary: String {
        guard observationIsFresh, let f = frame?.observation.oral?.features else { return "口唇特征暂不可用" }
        return String(format: "开口比例 %.3f · 口唇高度比例 %.3f · 嘴角横移 %.3f", f.mouthOpening, f.outerLipAspect, f.mouthShift)
    }
    private let acceleratedDemo = CommandLine.arguments.contains("--ui-smoke")
    private let diagnosticRun = (CommandLine.arguments.contains("--camera-check") || CommandLine.arguments.contains("--session-resume-check"))
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
    private var unlockObserver: NSObjectProtocol?
    private var interruption = MonitoringInterruptionState()
    private var resumeWork: DispatchWorkItem?
    private weak var diagnosticWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?
    private var pendingStart = false

    init(demo: Bool = false) {
        oralSamples = OralSampleStore(persistent: !demo && !CommandLine.arguments.contains("--camera-check") && !CommandLine.arguments.contains("--session-resume-check"))
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true).appendingPathComponent("PostureDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            archiveURL = root.appendingPathComponent("calibration-v1.json")
            if let url = archiveURL, FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(CalibrationArchive.self, from: Data(contentsOf: url))
                if archive.schemaVersion == 1 { profiles = archive.profiles }
                else { notice = "校准文件版本不兼容，请重新校准。" }
            }
        } catch { notice = "校准文件无法读取：\(error.localizedDescription)" }
        reminderEngine.configuration = effectiveReminderConfiguration
        bodyBackend = mediaPipeAvailable ? settings.bodyBackend : .appleVision
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = VisionCompute.report().map { "\($0.key.replacingOccurrences(of: "VNDetect", with: "")): \($0.value.joined(separator: "/"))" }.sorted().joined(separator: " · ")
            DispatchQueue.main.async { self?.computeSummary = "支持的计算设备 · " + report }
        }
        camera.onStatus = { [weak self] value in
            guard let self else { return }
            // All CameraController delivery closures are invoked on the main queue.
            self.status = value
            if value == .running {
                self.pendingStart = false
                if self.startedAt == nil { self.startedAt = ProcessInfo.processInfo.systemUptime; self.cpuOrigin = self.processCPUSeconds() }
            } else if !value.isActive {
                if case .failed = value { self.interruption.requestPause() }
                if value == .denied { self.interruption.requestPause() }
                self.pendingStart = false
                self.analysisHz = 0
                self.clearCurrentObservation()
                self.cancelCalibration(message: "观察已暂停，校准未保存。")
                self.applyReminderResult(self.reminderEngine.reset())
                self.habitEngine.reset(); self.habitStates = []; self.habitsReliable = false
                self.oralSamples.cancel(); self.refreshReminderPresentation()
            }
        }
        camera.onFrame = { [weak self] packet in
            guard let self, !self.isDemo, self.status.isActive else { return }
            self.receive(packet)
        }
        camera.onFirstVideoFrame = { [weak self] seconds in self?.firstVideoSeconds = seconds }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }
        for (name, reason) in [(NSWorkspace.willSleepNotification, MonitoringInterruption.systemSleep),
                               (NSWorkspace.screensDidSleepNotification, .displaySleep),
                               (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendForSystem(reason) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, MonitoringInterruption.systemSleep),
                               (NSWorkspace.screensDidWakeNotification, .displaySleep),
                               (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFromSystem(reason) }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.suspendForSystem(.screenLocked) } }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resumeFromUnlock() } }
        if demo { startDemo() }
    }

    var profile: Calibration? { profiles[selectedContext.rawValue] }
    var matchingProfile: Calibration? {
        if isDemo { return DemoFrame.calibration }
        guard let profile, let signature = frame?.observation.cameraSignature,
              profile.matchesFace(signature) else { return nil }
        return profile
    }
    var canCalibrate: Bool { !isDemo && status == .running && observationIsFresh && metrics?.faceUsable == true && collector == nil && !oralSamples.isRecording }
    var canRecordOralPose: Bool { !isDemo && status == .running && observationIsFresh && metrics?.faceUsable == true && collector == nil && !oralSamples.isRecording }
    var habitTimingSummary: String {
        habitStates.map { state in
            let title: String
            switch state.kind {
            case .handMouth: title = "手口接近"
            case .lipChange: title = "口唇变化"
            case .facialShift: title = "嘴角偏移"
            case .eyelidChange: title = "眼周变化"
            case .jawAppearance: title = "下颌示范"
            case .upperLipAppearance: title = "上唇示范"
            case .lowerLipAppearance: title = "下唇示范"
            case .tongueAppearance: title = "舌部示范"
            }
            return title + " " + String(Int(state.elapsedSeconds)) + " 秒" + (state.recovering ? " · 待确认恢复" : "")
        }.joined(separator: "；")
    }
    var hasStarted: Bool { status.isActive || (isDemo && !demoPaused) || pendingStart || interruption.requestedRunning }
    var monitorSummary: String {
        if !hasStarted { return status.title }
        if calibrationProgress != nil { return "正在校准 · 提醒暂缓" }
        if !settings.automaticReminders { return "观察中 · 提醒已关闭" }
        if frame == nil {
            if case .unknown(let reason) = monitorState { return reason }
            return firstVideoSeconds == nil ? status.title : "画面已就绪，正在识别"
        }
        if case .normal = monitorState, monitoringScopeDetail != nil { return "头部接近参考" }
        return monitorState.label
    }
    var monitorDetail: String? {
        guard hasStarted, collector == nil, settings.automaticReminders else { return nil }
        let independent = postureChannels.filter { $0.isUnresolved }.map { channel -> String in
            let title = channel.channel == .head ? "头部" : "肩线"
            let pending: String
            if case .recovering = channel.state { pending = " · 待确认恢复" }
            else if !channel.isObservable { pending = " · 暂时看不清，保留计时" }
            else { pending = channel.hasReminded ? " · 未恢复" : "" }
            return title + " " + String(Int(channel.accumulatedSeconds)) + " 秒" + pending
        }
        if !independent.isEmpty { return independent.joined(separator: "；") + "（独立计时）" }
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
        if monitoringBaseline.cameraSignature != frame?.observation.cameraSignature { return "仅监测头部：肩部模型不同，请校准肩线" }
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
        guard observationIsFresh, let value = metrics?.shoulderAngle, let profile = monitoringBaseline ?? matchingProfile,
              profile.cameraSignature == frame?.observation.cameraSignature, let baseline = profile.shoulder else { return nil }
        return Geometry.wrapDegrees(value - baseline.median, period: 180)
    }

    func toggleMonitoringFromKeyboard() {
        if isDemo {
            if demoPaused { startDemo() }
            else {
                demoTimer?.invalidate(); demoTimer = nil; demoPaused = true
                status = .paused("演示已暂停，按空格继续。")
                clearCurrentObservation(); applyReminderResult(reminderEngine.reset())
                habitEngine.reset(); habitStates = []; habitsReliable = false; refreshReminderPresentation()
            }
        } else { hasStarted ? pause() : start() }
    }
    func start() {
        resumeWork?.cancel()
        guard interruption.requestStart() else {
            status = .paused("系统暂时中断监测，解锁亮屏后会自动继续。")
            return
        }
        startCapture()
    }
    private func startCapture() {
        stopDemo()
        clearCurrentObservation()
        resetStats()
        requestedStartAt = ProcessInfo.processInfo.systemUptime
        notice = nil
        pendingStart = true
        status = .starting
        settings.resumeOnLaunch = true
        applyReminderResult(reminderEngine.reset())
        camera.start(backend: bodyBackend)
    }
    func pause(reason: String = "已停止采集并清除预览画面。") {
        interruption.requestPause(); resumeWork?.cancel()
        stopCapture(reason: reason, saveManualPause: true)
    }
    private func stopCapture(reason: String, saveManualPause: Bool) {
        stopDemo()
        pendingStart = false
        camera.stop(reason: reason)
        status = .paused(reason)
        analysisHz = 0
        clearCurrentObservation()
        cancelCalibration(message: "观察已暂停，校准未保存。")
        if saveManualPause { settings.resumeOnLaunch = false }
        applyReminderResult(reminderEngine.reset())
        habitEngine.reset(); habitSummary = "口部观察已暂停"; nextJawCheck = nil
        habitStates = []; habitsReliable = false; oralSamples.cancel(); refreshReminderPresentation()
    }
    func suspendForSystem(_ reason: MonitoringInterruption) {
        guard !isDemo else { return }
        interruption.suspend(reason); resumeWork?.cancel()
        guard interruption.requestedRunning || status.isActive || pendingStart else { return }
        stopCapture(reason: "系统暂时中断监测，解锁亮屏后会自动继续。", saveManualPause: false)
    }
    func resumeFromSystem(_ reason: MonitoringInterruption) {
        interruption.resume(reason); scheduleSystemResume()
    }
    func resumeFromUnlock() { interruption.unlocked(); scheduleSystemResume() }
    private func scheduleSystemResume() {
        resumeWork?.cancel()
        guard !isDemo, interruption.canResume, !status.isActive else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.interruption.canResume, !self.status.isActive,
                      AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
                self.startCapture()
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.8, execute: work)
    }
    func backendDidChange() {
        settings.bodyBackend = bodyBackend
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
        tickTimer?.invalidate(); demoTimer?.invalidate(); resumeWork?.cancel()
        camera.shutdown()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    func beginCalibration() {
        guard canCalibrate, let packet = frame else { return }
        collector = CalibrationCollector(context: selectedContext, startedAt: ProcessInfo.processInfo.systemUptime,
                                         signature: packet.observation.cameraSignature)
        configureCameraAnalysis()
        calibrationProgress = 0
        habitEngine.reset()
        habitStates = []; habitsReliable = false; oralSamples.cancel()
        calibrationMessage = "请看\(selectedContext.label)中心，嘴唇自然放松、不讲话，保持舒适参考姿态。"
        notice = nil
        applyReminderResult(reminderEngine.reset())
        refreshReminderPresentation()
    }
    func cancelCalibration(message: String = "校准已取消，保留之前的参考。") {
        if collector != nil { calibrationMessage = message }
        collector = nil; calibrationProgress = nil
        configureCameraAnalysis()
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func receive(_ packet: AnalysisPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - packet.observation.timestamp <= 1 else { return }
        frame = packet
        let evaluated = QualityGate.evaluate(packet.observation)
        metrics = evaluated
        observationIsFresh = true
        frameCount += 1
        if firstAnalysisSeconds == nil, let requestedStartAt { firstAnalysisSeconds = now - requestedStartAt }
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
        oralSamples.consume(packet.observation, metrics: evaluated)
        evaluateReminder(packet, metrics: evaluated)
        if settings.automaticReminders, collector == nil, !oralSamples.isRecording,
           settings.handMouthMonitoring || settings.experimentalLipMonitoring || settings.experimentalFaceMonitoring
                || settings.mouthShiftMonitoring || settings.oralPoseMonitoring {
            let previousConfirmed = habitStates.filter(\.confirmed)
            let result = habitEngine.observeDetailed(packet.observation, metrics: evaluated,
                reference: oralSamples.library(context: monitoringBaseline?.context ?? selectedContext,
                    signature: packet.observation.cameraSignature)?.reference ?? monitoringBaseline?.facialReference,
                tuning: settings.tuning,
                hand: settings.handMouthMonitoring, lips: settings.experimentalLipMonitoring,
                face: settings.experimentalFaceMonitoring,
                examples: currentOralExamples,
                mouthShift: settings.mouthShiftMonitoring)
            habitStates = result.states; habitsReliable = result.reliable
            if result.reliable && !previousConfirmed.isEmpty && result.confirmedStates.isEmpty { recoveryConfirmed = true }
            habitSummary = habitEngine.summary
        } else {
            habitEngine.reset(); habitStates = []; habitsReliable = false
            if !isDemo { habitSummary = "口部自动观察已关闭或暂缓" }
        }
        refreshReminderPresentation()
        judgmentSampleCounts[monitorSummary, default: 0] += 1
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if hasStarted, let startedAt { elapsedSeconds = now - startedAt }
        if hasStarted, elapsedSeconds > 0 { averageAppCPU = max(0, (processCPUSeconds() - cpuOrigin) / elapsedSeconds * 100) }
        if !isDemo, status == .running, settings.automaticReminders, settings.jawSelfCheck,
           collector == nil, !oralSamples.isRecording, observationIsFresh, metrics?.faceUsable == true,
           abs(metrics?.yaw ?? 90) <= 20 {
            if nextJawCheck == nil { nextJawCheck = now + settings.tuning.normalized.jawCheckSeconds }
            if let due = nextJawCheck, now >= due {
                onReminderEvent?(.nudge("放松下颌"))
                nextJawCheck = now + settings.tuning.normalized.jawCheckSeconds
            }
        } else { nextJawCheck = nil }
        if let timestamp = frame?.observation.timestamp, now - timestamp > 1 {
            clearCurrentObservation()
            analysisHz = 0
            applyReminderResult(reminderEngine.observe(ReminderInput(timestamp: now, contextID: "stale",
                                                                    reliable: false, quietReason: "画面过期，保持安静")))
            habitsReliable = false; refreshReminderPresentation()
        }
        if oralSamples.tick(at: now) {
            configureCameraAnalysis(); habitEngine.reset(); habitStates = []; habitsReliable = false
            applyReminderResult(reminderEngine.reset()); refreshReminderPresentation()
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
                    calibrationMessage += baseline.facialReference == nil
                        ? "口唇参考尚未达到采集条件，试验观察需要近正对镜头。" : "个人口唇参考已保存。"
                } catch {
                    calibrationMessage = error.localizedDescription
                }
                self.collector = nil; calibrationProgress = nil
                configureCameraAnalysis()
                applyReminderResult(reminderEngine.reset())
                refreshReminderPresentation()
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
    private func configureCameraAnalysis() {
        var tuning = settings.tuning.normalized
        if collector != nil || oralSamples.isRecording { tuning.faceHertz = max(6, tuning.faceHertz) }
        camera.configureAnalysis(tuning: tuning, hands: settings.handMouthMonitoring,
            oral: settings.experimentalLipMonitoring || settings.experimentalFaceMonitoring || settings.mouthShiftMonitoring
                || settings.oralPoseMonitoring || oralSamples.isRecording || collector != nil)
    }
    func applySensitivityPreset(_ preset: Int) {
        var tuning = settings.tuning
        switch preset {
        case 0: tuning.sustainedSeconds = 3; tuning.headEnterDegrees = 2; tuning.headExitDegrees = 1
        case 2: tuning.sustainedSeconds = 10; tuning.headEnterDegrees = 5; tuning.headExitDegrees = 2.5
        default: tuning.sustainedSeconds = 5; tuning.headEnterDegrees = 3; tuning.headExitDegrees = 1.5
        }
        settings.tuning = tuning.normalized
    }
    func restoreTuningDefaults() { settings.tuning = MonitorTuning() }
    func exportTuning() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "kukusit-parameters.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings.tuning.normalized).write(to: url, options: .atomic)
            notice = "参数已导出；文件不包含个人参考、图像或监测记录。"
        } catch { notice = "参数导出失败：\(error.localizedDescription)" }
    }
    func importTuning() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
            guard data.count <= 64 * 1024 else { notice = "参数文件过大。"; return }
            settings.tuning = try JSONDecoder().decode(MonitorTuning.self, from: data).normalized
            notice = "参数已导入并生效。"
        } catch { notice = "参数文件无法读取：\(error.localizedDescription)" }
    }
    private func applyReminderResult(_ result: ReminderResult) {
        if monitorState != result.state { monitorState = result.state }
        postureChannels = result.channels
        for event in result.events {
            if case .correction = event { reminderCount += 1 }
            if case .recovered = event { recoveryConfirmed = true }
        }
    }
    private func refreshReminderPresentation() {
        var alerts: [MonitoringAlert] = []
        if hasStarted && settings.automaticReminders && collector == nil && !oralSamples.isRecording {
            for channel in postureChannels where channel.hasReminded && channel.isUnresolved && channel.isObservable {
                guard let kind = channel.kind else { continue }
                let recovering: Bool
                if case .recovering = channel.state { recovering = true } else { recovering = false }
                alerts.append(MonitoringAlert(id: "posture." + channel.channel.rawValue,
                    title: channel.channel == .head ? "歪头" : "肩线偏移", message: kind.message,
                    seconds: Int(channel.accumulatedSeconds), recovering: recovering,
                    recoveryProgress: min(1, channel.recoverySeconds / max(0.1, effectiveReminderConfiguration.recoverySeconds))))
            }
            if habitsReliable {
                for state in habitStates where state.confirmed {
                    let message = state.kind.message
                    alerts.append(MonitoringAlert(id: "habit." + state.kind.rawValue, title: "口部变化", message: message,
                        seconds: Int(state.elapsedSeconds), recovering: state.recovering,
                        recoveryProgress: min(1, state.recoverySeconds / max(0.1, settings.tuning.recoverySeconds))))
                }
            }
        }
        let oralEnabled = settings.handMouthMonitoring || settings.experimentalLipMonitoring || settings.experimentalFaceMonitoring
            || settings.mouthShiftMonitoring || settings.oralPoseMonitoring
        let recoveredSafely = recoveryConfirmed && !postureChannels.contains(where: \.isUnresolved)
            && habitStates.isEmpty && (!oralEnabled || habitsReliable)
            && postureChannels.first(where: { $0.channel == .head })?.isObservable == true
        onReminderAlertsChanged?(alerts, recoveredSafely)
        recoveryConfirmed = false
    }
    func beginOralRecording(action: OralPoseAction?) {
        guard canRecordOralPose, let signature = frame?.observation.cameraSignature else { return }
        oralSamples.begin(context: selectedContext, signature: signature, action: action, label: oralSamples.sampleLabel)
        habitEngine.reset(); habitStates = []; habitsReliable = false
        applyReminderResult(reminderEngine.reset()); refreshReminderPresentation(); configureCameraAnalysis()
    }
    func cancelOralRecording() { oralSamples.cancel(); configureCameraAnalysis(); refreshReminderPresentation() }
    func removeOralExamples() {
        oralSamples.remove(context: selectedContext); habitEngine.reset(); habitStates = []; habitsReliable = false
        refreshReminderPresentation()
    }
    private func evaluateReminder(_ packet: AnalysisPacket, metrics: Metrics) {
        guard settings.automaticReminders, collector == nil, !oralSamples.isRecording else {
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
        firstVideoSeconds = nil; firstAnalysisSeconds = nil; nextJawCheck = nil; habitEngine.reset()
        habitStates = []; habitsReliable = false; recoveryConfirmed = false
        cpuOrigin = processCPUSeconds(); averageAppCPU = 0
        judgmentSampleCounts = [:]
        analysisHz = 0; p95Milliseconds = 0; elapsedSeconds = 0
        frameTimes = []; latencies = []; startedAt = nil
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
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
                "habitSummary": habitSummary, "firstVideoSeconds": firstVideoSeconds ?? -1,
                "firstAnalysisSeconds": firstAnalysisSeconds ?? -1, "averageAppCPUPercent": averageAppCPU,
                "tuning": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.tuning.normalized))) ?? [:],
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
        oralSamples.cancel()
        camera.stop(reason: "演示模式：摄像头未启动。")
        cancelCalibration()
        resetStats()
        isDemo = true; demoPaused = false; startedAt = ProcessInfo.processInfo.systemUptime
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
        demoTimer?.invalidate(); demoTimer = nil; isDemo = false; demoPaused = false
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
