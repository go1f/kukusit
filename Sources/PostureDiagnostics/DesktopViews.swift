import SwiftUI
import AppKit
import PostureCore

struct MonitorPopover: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("坐姿监测", systemImage: "figure.seated.side").font(.headline)
                Spacer()
                Button { desktop.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
            }
            Text(model.monitorSummary).font(.callout).foregroundStyle(.secondary)
            Button { desktop.showMain(expandPreview: true) } label: { Label("打开监控窗口", systemImage: "video") }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            HStack {
                Button(model.hasStarted ? "暂停监测" : "开始监测") { model.hasStarted ? model.pause() : model.start() }
                Button(desktop.pipVisible ? "收起画中画" : "画中画") { desktop.togglePiP() }
            }
            Divider()
            Picker("校准情境", selection: $model.selectedContext) {
                ForEach(ViewingContext.allCases) { Text($0.label).tag($0) }
            }.disabled(model.calibrationProgress != nil)
            if let progress = model.calibrationProgress {
                ProgressView(value: progress)
                Button("取消校准") { model.cancelCalibration() }
            } else {
                Button(model.profile == nil ? "校准 20 秒" : "重新校准") { model.beginCalibration() }.disabled(!model.canCalibrate)
            }
            HStack {
                Text("仅在本机处理").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.font(.caption)
            }
        }.padding(14).frame(width: 300).fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PiPView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(model.isDemo ? "演示输入" : model.monitorSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { desktop.expandPiP() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).frame(width: 28, height: 28).help("放大到完整窗口").accessibilityLabel("放大到完整窗口")
                Menu {
                    Toggle("显示摄像头", isOn: $model.settings.pipShowsVideo)
                    Toggle("显示骨架", isOn: $model.settings.pipShowsSkeleton)
                    Toggle("保持置顶", isOn: $model.settings.pipOnTop)
                    Divider()
                    ForEach(PiPSize.allCases) { size in Button("\(size.label)尺寸") { model.settings.pipSize = size } }
                    Divider()
                    Button("收起画中画") { desktop.hidePiP() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
            }
            if model.settings.pipShowsVideo || model.settings.pipShowsSkeleton {
                PiPPreview(model: model)
                    .aspectRatio(16.0 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 14) {
                value("头部偏移", model.rollDeviation)
                Divider().frame(height: 36)
                value("肩线偏移", model.shoulderDeviation)
                Spacer(minLength: 0)
                Button { model.hasStarted ? model.pause() : model.start() } label: {
                    Image(systemName: model.hasStarted ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).help(model.hasStarted ? "暂停监测" : "开始监测")
                    .accessibilityLabel(model.hasStarted ? "暂停监测" : "开始监测")
            }
            if model.isDemo { Text("合成输入 · 摄像头未启动").font(.caption2).foregroundStyle(.secondary) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .top)
            .background(.regularMaterial)
    }
    private func value(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—").font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }
    }
}

private struct PiPPreview: View {
    @ObservedObject var model: DiagnosticModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
            if model.settings.pipShowsVideo, let image = model.frame?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
            }
            if model.settings.pipShowsSkeleton, let frame = model.frame {
                LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: model.mirrored)
            }
            if model.frame == nil {
                Label(model.hasStarted ? "等待清晰画面" : "已暂停", systemImage: "camera")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
