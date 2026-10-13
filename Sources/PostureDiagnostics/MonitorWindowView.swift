import SwiftUI
import PostureCore

struct MonitorWindowView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("坐姿监测").font(.title2.weight(.semibold))
                    Text(model.isDemo ? "演示输入 · 摄像头未启动" : model.monitorSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { desktop.collapseMainToPiP() } label: { Label("画中画", systemImage: "pip.enter") }
                Button { desktop.showSettings() } label: { Label("设置", systemImage: "gearshape") }
                Button { desktop.hideMain() } label: { Image(systemName: "minus") }.help("收起到菜单栏")
            }
            ZStack {
                Color.black.opacity(0.9)
                if model.isDemo, let frame = model.frame, let image = frame.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                    LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: model.mirrored)
                } else if model.status.isActive {
                    CameraPreview(session: model.cameraSession, mirrored: model.mirrored, enabled: model.renderingImageRequested)
                    if let frame = model.frame {
                        LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: model.mirrored)
                    }
                    if model.firstVideoSeconds == nil { Text("正在启动摄像头，识别模块随后就绪").foregroundStyle(.white.opacity(0.85)) }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 40, weight: .light))
                        Text(model.hasStarted ? "等待系统恢复后继续监测" : "监测已暂停").font(.headline)
                        if !model.hasStarted { Button("开始监测") { model.start() }.buttonStyle(.borderedProminent) }
                        if model.status == .denied { Button("打开摄像头设置") { model.openPrivacySettings() } }
                    }.foregroundStyle(.white.opacity(0.85))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 24) {
                metric("头部偏移", model.rollDeviation)
                metric("肩线偏移", model.shoulderDeviation)
                Spacer()
                Text(model.monitorSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(model.monitorSummary)
                Button(model.hasStarted ? "暂停监测" : "开始监测") { model.hasStarted ? model.pause() : model.start() }
                    .buttonStyle(.borderedProminent).help("窗口聚焦时，按空格暂停或继续监测")
            }
            if let detail = model.monitorDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if !model.habitTimingSummary.isEmpty {
                Text(model.habitTimingSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.habitTimingSummary)
            }
        }.padding(18).frame(minWidth: 720, minHeight: 520)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—").font(.system(.title3, design: .rounded)).monospacedDigit()
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    @ObservedObject var router: DisplayRouter
    var body: some View {
        TabView {
            Form {
                Section("提醒与敏感度") {
                    Toggle("自动轻提醒", isOn: $model.settings.automaticReminders)
                    HStack {
                        Text("快速选择")
                        Spacer()
                        Button("更敏感") { model.applySensitivityPreset(0) }
                        Button("敏感 · 推荐") { model.applySensitivityPreset(1) }
                        Button("宽松") { model.applySensitivityPreset(2) }
                    }
                    numeric("持续偏离后提醒", $model.settings.tuning.sustainedSeconds, 1...120, 1, "秒")
                    numeric("头部偏离起点", $model.settings.tuning.headEnterDegrees, 1...15, 0.5, "°")
                    numeric("头部恢复范围", $model.settings.tuning.headExitDegrees, 0.2...max(0.2, model.settings.tuning.headEnterDegrees - 0.2), 0.1, "°")
                    numeric("连续回正确认", $model.settings.tuning.recoverySeconds, 0.5...10, 0.5, "秒")
                    numeric("再次提醒间隔", $model.settings.tuning.cooldownSeconds, 5...1800, 5, "秒")
                    Text("各项异常独立计时。短暂回正保留计时，默认静音；持续异常的提示保留到确认恢复，看不清时隐藏。").font(.caption).foregroundStyle(.secondary)
                    Text(model.rollDeviation.map { String(format: "当前头部偏移 %+.1f°", $0) } ?? "开始监测并校准后可查看实时偏移")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("更多姿态参数") {
                    numeric("肩线偏离起点", $model.settings.tuning.shoulderEnterDegrees, 2...25, 0.5, "°")
                    numeric("肩线恢复范围", $model.settings.tuning.shoulderExitDegrees, 0.5...max(0.5, model.settings.tuning.shoulderEnterDegrees - 0.5), 0.5, "°")
                    numeric("短暂丢点容忍", $model.settings.tuning.lossGraceSeconds, 0...5, 0.5, "秒")
                    numeric("最短稳定观察", $model.settings.tuning.settleSeconds, 0.2...1, 0.1, "秒")
                    numeric("相对参考左右观看范围", $model.settings.tuning.yawLimitDegrees, 10...40, 1, "°")
                    numeric("相对参考俯仰观看范围", $model.settings.tuning.pitchLimitDegrees, 10...50, 1, "°")
                    Text("侧转太大、多个目标或识别不可靠时仍保持安静。").font(.caption).foregroundStyle(.secondary)
                }
                Button("还原参数默认值（5 秒 / 3°）") { model.restoreTuningDefaults() }
                HStack {
                    Button("导出参数") { model.exportTuning() }
                    Button("导入参数") { model.importTuning() }
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("提醒", systemImage: "bell") }
            Form {
                Section("嘴角与口部变化") {
                    Toggle("监测持续歪嘴", isOn: $model.settings.mouthShiftMonitoring)
                    numeric("变化持续时间", $model.settings.tuning.lipChangeSeconds, 1...30, 1, "秒")
                    numeric("嘴角变化阈值（比例）", $model.settings.tuning.facialShiftThreshold, 0.02...0.3, 0.01, "")
                    Text("嘴角相对自然参考的偏移独立累计，张嘴时也观察。").font(.caption).foregroundStyle(.secondary)
                }
                OralSampleSettingsView(model: model, store: model.oralSamples)
                DisclosureGroup("示范匹配敏感度") {
                    numeric("允许的外观差距", $model.settings.tuning.oralMatchDistance, 0.2...2, 0.05, "")
                    numeric("分类区分裕度", $model.settings.tuning.oralMatchMargin, 0.1...2, 0.05, "")
                    Text("允许差距调大或区分裕度调小，会更容易提示，也可能增加误报。这里的数值是几何距离，不是识别准确率。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("手与嘴唇") {
                    Toggle("手靠近嘴唇时提醒", isOn: $model.settings.handMouthMonitoring)
                    numeric("持续接近后提醒", $model.settings.tuning.handMouthSeconds, 0.5...15, 0.5, "秒")
                    numeric("接近范围（嘴唇宽度比例）", $model.settings.tuning.handMouthRadius, 0.05...0.8, 0.05, "")
                    Text("识别画面中的手口接近，不能确认手指碰到了牙齿或正在咬手指。吃东西、喝水、化妆时可关闭。").font(.caption).foregroundStyle(.secondary)
                }
                Section("下颌放松自检") {
                    Toggle("定时提醒检查咬紧牙齿", isOn: $model.settings.jawSelfCheck)
                    numeric("自检提醒间隔", $model.settings.tuning.jawCheckSeconds, 30...3600, 30, "秒")
                    Text("自检提醒不代表检测到了磨牙或牙齿紧绷。普通摄像头无法测量咬合力量。").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("口唇与眼周变化（试验）") {
                    Toggle("持续口唇收紧变化时提示", isOn: $model.settings.experimentalLipMonitoring)
                    Toggle("持续嘴角或单侧眯眼变化时提示", isOn: $model.settings.experimentalFaceMonitoring)
                    numeric("口唇变化阈值（比例）", $model.settings.tuning.lipChangeThreshold, 0.02...0.3, 0.01, "")
                    numeric("眼周变化阈值（比例）", $model.settings.tuning.eyelidChangeThreshold, 0.05...0.5, 0.01, "")
                    Text(model.facialReferenceAvailable ? "已建立个人口唇参考" : "需要重新校准，采集自然放松、不讲话时的口唇参考")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("比较与个人参考的外观变化；具体动作可通过上方个人示范匹配。画面不用于确认牙位接触或咬合力量。").font(.caption).foregroundStyle(.secondary)
                }
                Section("实时观察") {
                    Text(model.habitSummary).font(.callout)
                    if !model.habitTimingSummary.isEmpty { Text(model.habitTimingSummary).font(.caption).monospacedDigit() }
                    Text(model.facialMetricsSummary).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("口部习惯", systemImage: "hand.raised") }
            Form {
                Section("视频预览") {
                    Toggle("镜像视频预览", isOn: $model.mirrored)
                    Text("同时应用于监控窗口和画中画的视频与骨架。默认关闭；只改变预览方向，不改变姿态判断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("画中画") {
                    Toggle("保持置顶", isOn: $model.settings.pipOnTop)
                    Toggle("显示摄像头", isOn: $model.settings.pipShowsVideo)
                    Toggle("显示骨架", isOn: $model.settings.pipShowsSkeleton)
                    Picker("大小", selection: $model.settings.pipSize) { ForEach(PiPSize.allCases) { Text($0.label).tag($0) } }
                    Picker("显示器", selection: $model.settings.pipScreenID) {
                        Text("自动（优先上次位置）").tag("automatic")
                        ForEach(router.displays) { Text($0.name).tag($0.id) }
                    }
                    Picker("默认位置", selection: $model.settings.pipCorner) { ForEach(PiPCorner.allCases) { Text($0.label).tag($0) } }
                    Text("拖动后自动记住位置、显示器和尺寸。外接屏暂时断开时会移回可用屏幕。").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("启动时继续上次监测", isOn: $model.settings.resumeOnLaunch)
            }.formStyle(.grouped).tabItem { Label("视频预览", systemImage: "video") }
            Form {
                Section("个人校准") {
                    Picker("观看情境", selection: $model.selectedContext) { ForEach(ViewingContext.allCases) { Text($0.label).tag($0) } }
                        .disabled(model.calibrationProgress != nil || model.oralSamples.isRecording)
                    if let progress = model.calibrationProgress {
                        ProgressView(value: progress)
                        Button("取消校准") { model.cancelCalibration() }
                    } else {
                        Button(model.profile == nil ? "校准 20 秒" : "重新校准 20 秒") { model.beginCalibration() }.disabled(!model.canCalibrate)
                    }
                    Text(model.calibrationMessage).font(.caption).foregroundStyle(.secondary)
                }
                Section("性能") {
                    HStack {
                        Button("节能") { model.settings.tuning.faceHertz = 4; model.settings.tuning.bodyHertz = 2 }
                        Button("均衡") { model.settings.tuning.faceHertz = 6; model.settings.tuning.bodyHertz = 3 }
                        Button("更高频率") { model.settings.tuning.faceHertz = 10; model.settings.tuning.bodyHertz = 5 }
                    }
                    numeric("头部分析频率", $model.settings.tuning.faceHertz, 2...12, 1, "Hz")
                    numeric("肩部分析频率", $model.settings.tuning.bodyHertz, 1...6, 1, "Hz")
                    Picker("原生识别计算偏好", selection: $model.settings.tuning.computePreference) {
                        ForEach(ComputePreference.allCases) { Text($0 == .automatic ? "自动（推荐）" : $0.deviceName + " 优先").tag($0) }
                    }
                    Text("偏好用于 Apple Vision；不支持的阶段自动选择设备。肩部 MediaPipe 使用 CPU。视频预览和缩放由系统及 Metal 处理。").font(.caption).foregroundStyle(.secondary)
                    Text(model.computeSummary).font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "脸部分析 %.1f Hz · p95 %.0f ms", model.analysisHz, model.p95Milliseconds)).font(.caption)
                    if let seconds = model.firstVideoSeconds { Text(String(format: "本次摄像头首帧 %.2f 秒", seconds)).font(.caption) }
                    Text(String(format: "本次应用平均 CPU %.1f%%（不含独立肩部进程）", model.averageAppCPU)).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("高级诊断") {
                    Picker("肩部模型", selection: $model.bodyBackend) {
                        Text(BodyBackend.appleVision.label).tag(BodyBackend.appleVision)
                        if model.mediaPipeAvailable { Text(BodyBackend.mediaPipe.label).tag(BodyBackend.mediaPipe) }
                    }.disabled(model.isDemo || model.calibrationProgress != nil)
                        .onChange(of: model.bodyBackend) { _, _ in model.backendDidChange() }
                    Button("导出数值摘要和参数") { model.exportSummary() }.disabled(model.frameCount == 0)
                    Button("预览提醒样式") { desktop.previewReminder() }
                    Button("查看演示画面") { model.startDemo() }
                    if model.isDemo {
                        Picker("演示情景", selection: $model.demoScenario) { ForEach(DemoScenario.allCases) { Text($0.label).tag($0) } }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("校准与性能", systemImage: "slider.horizontal.3") }
            AppUpdateSettingsView(updater: desktop.updater)
                .tabItem { Label("应用更新", systemImage: "arrow.triangle.2.circlepath") }
        }.padding(12).frame(minWidth: 600, minHeight: 620)
    }
    private func numeric(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String) -> some View {
        let bounded = Binding<Double>(get: { value.wrappedValue }, set: {
            value.wrappedValue = $0.isFinite ? min(range.upperBound, max(range.lowerBound, $0)) : range.lowerBound
            model.settings.tuning = model.settings.tuning.normalized
        })
        return HStack {
            Text(title)
            Spacer()
            TextField(title, value: bounded, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 18)
            Stepper(title, value: bounded, in: range, step: step).labelsHidden()
        }.help("可调整范围：\(range.lowerBound)–\(range.upperBound) \(unit)")
    }
}
