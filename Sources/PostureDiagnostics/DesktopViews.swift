import SwiftUI
import AppKit
import PostureCore

struct PiPView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(model.isDemo ? "演示输入" : model.monitorSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.monitorDetail.map { model.monitorSummary + "\n" + $0 } ?? model.monitorSummary)
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
                Button { model.toggleMonitoring() } label: {
                    Image(systemName: model.hasStarted ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).help((model.hasStarted ? "暂停监测" : "开始监测") + "（聚焦后可按空格）")
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
            if model.settings.pipShowsVideo {
                if model.isDemo, let image = model.frame?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                } else if model.status.isActive {
                    CameraPreview(session: model.cameraSession, mirrored: model.mirrored, enabled: model.renderingImageRequested)
                }
            }
            if model.settings.pipShowsSkeleton, let frame = model.frame {
                LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: model.mirrored)
            }
            if model.frame == nil && (model.isDemo || !model.status.isActive || model.firstVideoSeconds == nil) {
                Label(model.hasStarted ? (model.status.isActive || model.isDemo ? "等待清晰画面" : "等待系统恢复") : "已暂停", systemImage: "camera")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
