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
                if let frame = model.frame, let image = frame.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                    LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: model.mirrored)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 40, weight: .light))
                        Text(model.hasStarted ? "等待清晰画面" : "监测已暂停").font(.headline)
                        if !model.hasStarted { Button("开始监测") { model.start() }.buttonStyle(.borderedProminent) }
                    }.foregroundStyle(.white.opacity(0.85))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 24) {
                metric("头部偏移", model.rollDeviation)
                metric("肩线偏移", model.shoulderDeviation)
                Spacer()
                Text(model.monitorSummary).font(.callout).foregroundStyle(.secondary)
                Button(model.hasStarted ? "暂停监测" : "开始监测") { model.hasStarted ? model.pause() : model.start() }
                    .buttonStyle(.borderedProminent)
            }
            if case .recovering(_, let seconds) = model.monitorState {
                Text("待确认恢复 · 已累计偏离 \(seconds) 秒；连续回正 2 秒后才清零。")
                    .font(.caption).foregroundStyle(.secondary)
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
        Form {
            Section("轻提醒") {
                Toggle("自动轻提醒", isOn: $model.settings.automaticReminders)
                Stepper("连续偏离 \(Int(model.settings.sustainedSeconds)) 秒后提醒", value: $model.settings.sustainedSeconds, in: 20...60, step: 5)
                Picker("再次提醒间隔", selection: $model.settings.cooldownSeconds) {
                    Text("2 分钟").tag(120.0); Text("3 分钟").tag(180.0); Text("5 分钟").tag(300.0)
                }
                Text("短暂回正不足 2 秒保留计时；提醒静音、约 4 秒淡出。").font(.caption).foregroundStyle(.secondary)
            }
            Section("画中画") {
                Toggle("保持置顶", isOn: $model.settings.pipOnTop)
                Toggle("显示摄像头", isOn: $model.settings.pipShowsVideo)
                Toggle("显示骨架", isOn: $model.settings.pipShowsSkeleton)
                Toggle("镜像预览", isOn: $model.mirrored)
                Picker("大小", selection: $model.settings.pipSize) { ForEach(PiPSize.allCases) { Text($0.label).tag($0) } }
                Picker("显示器", selection: $model.settings.pipScreenID) {
                    Text("当前工作显示器").tag("automatic")
                    ForEach(router.displays) { Text($0.name).tag($0.id) }
                }
                Picker("位置", selection: $model.settings.pipCorner) { ForEach(PiPCorner.allCases) { Text($0.label).tag($0) } }
            }
            Section("个人校准") {
                Picker("观看情境", selection: $model.selectedContext) { ForEach(ViewingContext.allCases) { Text($0.label).tag($0) } }
                    .disabled(model.calibrationProgress != nil)
                if let progress = model.calibrationProgress {
                    ProgressView(value: progress)
                    Button("取消校准") { model.cancelCalibration() }
                } else {
                    Button(model.profile == nil ? "校准 20 秒" : "重新校准 20 秒") { model.beginCalibration() }.disabled(!model.canCalibrate)
                }
                Text(model.calibrationMessage).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("高级与诊断") {
                Picker("肩部模型", selection: $model.bodyBackend) {
                    Text(BodyBackend.appleVision.label).tag(BodyBackend.appleVision)
                    if model.mediaPipeAvailable { Text(BodyBackend.mediaPipe.label).tag(BodyBackend.mediaPipe) }
                }.disabled(model.isDemo || model.calibrationProgress != nil)
                    .onChange(of: model.bodyBackend) { _, _ in model.backendDidChange() }
                Text(String(format: "分析 %.1f Hz · 管线 p95 %.0f ms", model.analysisHz, model.p95Milliseconds)).font(.caption)
                Button("导出数值摘要") { model.exportSummary() }.disabled(model.frameCount == 0)
                Button("预览提醒样式") { desktop.previewReminder() }
                Button("查看演示画面") { model.startDemo() }
            }
        }.formStyle(.grouped).padding(12).frame(minWidth: 520, minHeight: 480)
    }
}
