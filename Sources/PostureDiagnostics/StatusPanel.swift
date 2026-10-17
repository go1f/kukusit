import AppKit
import SwiftUI
import PostureCore

private struct StatusMenuHeader: View {
    @ObservedObject var model: DiagnosticModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("坐姿监测").font(.headline).frame(height: 20, alignment: .leading)
            Text(model.monitorSummary).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 34, alignment: .topLeading)
            Text(model.monitorDetail ?? " ").font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 30, alignment: .topLeading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 300, height: 112, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }
}

@MainActor final class StatusPanelController: NSObject, NSMenuDelegate {
    private let menu = NSMenu(title: "坐姿监测")
    private let model: DiagnosticModel
    private unowned let desktop: DesktopCoordinator
    private let monitor = NSMenuItem(title: "开始监测", action: nil, keyEquivalent: "")
    private let pip = NSMenuItem(title: "画中画", action: nil, keyEquivalent: "")
    private let mirror = NSMenuItem(title: "镜像预览", action: nil, keyEquivalent: "")
    private let calibrate = NSMenuItem(title: "校准 20 秒", action: nil, keyEquivalent: "")
    private var contexts: [NSMenuItem] = []
    private(set) var visible = false
    init(model: DiagnosticModel, desktop: DesktopCoordinator) {
        self.model = model; self.desktop = desktop
        super.init()
        menu.delegate = self; menu.autoenablesItems = false; menu.minimumWidth = 300; menu.showsStateColumn = true
        let header = NSMenuItem(); header.isEnabled = false
        let host = NSHostingView(rootView: StatusMenuHeader(model: model))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 300, height: 112)
        header.view = host; menu.addItem(header); menu.addItem(.separator())
        let open = NSMenuItem(title: "打开监测窗口", action: #selector(DesktopCoordinator.openMain), keyEquivalent: "")
        open.target = desktop; menu.addItem(open)
        pip.target = self; pip.action = #selector(togglePiP); menu.addItem(pip)
        monitor.target = self; monitor.action = #selector(toggleMonitoring); menu.addItem(monitor)
        mirror.target = self; mirror.action = #selector(toggleMirror); menu.addItem(mirror)
        menu.addItem(.separator())
        let contextMenu = NSMenu(title: "校准情境"); contextMenu.autoenablesItems = false
        for context in ViewingContext.allCases {
            let item = NSMenuItem(title: context.label, action: #selector(selectContext(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = context.rawValue; contextMenu.addItem(item); contexts.append(item)
        }
        let context = NSMenuItem(title: "校准情境", action: nil, keyEquivalent: "")
        context.submenu = contextMenu; menu.addItem(context)
        calibrate.target = self; calibrate.action = #selector(toggleCalibration); menu.addItem(calibrate)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(DesktopCoordinator.showSettings), keyEquivalent: "")
        settings.target = desktop; menu.addItem(settings)
        let quit = NSMenuItem(title: "退出坐姿监测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApplication.shared; menu.addItem(quit)
        updateGeometry()
    }
    func toggle(relativeTo button: NSStatusBarButton) {
        if visible { hide(); return }
        updateGeometry()
        // AppKit owns anchoring, row highlighting and tracking. No floating panel is resized by status text.
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY-4), in: button)
    }
    func updateGeometry() {
        monitor.title = model.hasStarted ? "暂停监测" : "开始监测"
        pip.state = desktop.pipVisible ? .on : .off
        mirror.state = model.mirrored ? .on : .off
        calibrate.title = model.calibrationProgress != nil ? "取消校准" : (model.profile == nil ? "校准 20 秒" : "重新校准 20 秒")
        calibrate.isEnabled = model.calibrationProgress != nil || model.canCalibrate
        for item in contexts {
            item.state = item.representedObject as? String == model.selectedContext.rawValue ? .on : .off
            item.isEnabled = model.calibrationProgress == nil && !model.oralSamples.isRecording
        }
    }
    func menuWillOpen(_ menu: NSMenu) { visible = true; updateGeometry() }
    func menuDidClose(_ menu: NSMenu) { visible = false }
    func hide() { menu.cancelTracking(); visible = false }
    @objc private func togglePiP() { desktop.togglePiP() }
    @objc private func toggleMonitoring() { model.toggleMonitoring() }
    @objc private func toggleMirror() { model.mirrored.toggle() }
    @objc private func toggleCalibration() {
        if model.calibrationProgress != nil { model.cancelCalibration() } else { model.beginCalibration() }
    }
    @objc private func selectContext(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let context = ViewingContext(rawValue: raw) else { return }
        model.selectedContext = context
    }
    var snapshot: [String: Any] {
        ["visible": visible, "nativeMenu": true, "headerHeight": menu.items.first?.view?.frame.height ?? 0,
         "width": menu.size.width, "height": menu.size.height,
         "itemTitles": menu.items.filter { !$0.isSeparatorItem && $0.view == nil }.map(\.title),
         "mirrored": mirror.state == .on]
    }
}
