import AppKit
import SwiftUI

final class StatusMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class StatusPanelController {
    private let panel: StatusMenuPanel
    private let host: NSHostingView<MonitorPopover>
    private weak var anchorButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deactivation: NSObjectProtocol?
    private(set) var visible = false
    private(set) var anchorGap = 0.0
    init(model: DiagnosticModel, desktop: DesktopCoordinator) {
        host = NSHostingView(rootView: MonitorPopover(model: model, desktop: desktop))
        panel = StatusMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu
        panel.title = "坐姿菜单"; panel.contentView = host
        panel.onEscape = { [weak self] in self?.hide() }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }
    func toggle(relativeTo button: NSStatusBarButton) {
        if visible { hide(); return }
        anchorButton = button
        visible = true; updateGeometry()
        panel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.anchorButton?.window { self.hide() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
    func updateGeometry() {
        guard visible, let button = anchorButton, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? window.screen
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(max(220, ceil(host.fittingSize.height)), area.height - 24)
        panel.setContentSize(NSSize(width: 300, height: height))
        let x = min(max(area.minX + 8, anchor.midX - 150), area.maxX - 308)
        let y = max(area.minY + 8, anchor.minY - height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        anchorGap = anchor.minY - panel.frame.maxY
    }
    func hide() {
        visible = false; panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
    var snapshot: [String: Any] { ["visible": visible, "anchorGapPoints": anchorGap, "height": panel.frame.height] }
}
