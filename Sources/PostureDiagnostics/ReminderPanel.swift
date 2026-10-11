import AppKit
import SwiftUI
import QuartzCore
import PostureCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class BannerContent: ObservableObject {
    @Published var text = ""
    @Published var recovered = false
}

private struct BannerView: View {
    @ObservedObject var content: BannerContent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.recovered ? "checkmark.circle.fill" : "figure.seated.side")
                .font(.title2).foregroundStyle(content.recovered ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(content.recovered ? "已恢复" : "轻轻调整一下").font(.caption).foregroundStyle(.secondary)
                Text(content.text).font(.body.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: 460, height: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class ReminderPanelController {
    private let panel: PassivePanel
    private let content = BannerContent()
    private let router: DisplayRouter
    private var hideWork: DispatchWorkItem?
    private var token = 0
    private(set) var visible = false
    private(set) var showCount = 0
    private(set) var recoveryCount = 0
    private(set) var focusPreserved = true
    private(set) var lastScreenName = ""
    private var habitBanner = false
    private var lastShownAt = -Double.infinity
    init(router: DisplayRouter) {
        self.router = router
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 72),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BannerView(content: content))
        panel.title = "坐姿轻提醒"
    }
    func handle(_ event: ReminderEvent) {
        switch event {
        case .correction(let kind): habitBanner = false; show(kind.message, recovered: false, duration: 4)
        case .recovered:
            if visible && !habitBanner && !content.recovered { recoveryCount += 1; show("继续保持舒适，记得偶尔活动。", recovered: true, duration: 1.8) }
        case .quiet: if !habitBanner { hide() }
        case .nudge(let message):
            guard ProcessInfo.processInfo.systemUptime - lastShownAt >= 10 else { return }
            habitBanner = true; show(message, recovered: false, duration: 4)
        }
    }
    private func show(_ text: String, recovered: Bool, duration: Double) {
        guard let screen = router.workingScreen() else { return }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyBefore = NSApplication.shared.keyWindow
        token += 1; let current = token
        lastShownAt = ProcessInfo.processInfo.systemUptime
        hideWork?.cancel()
        content.text = text; content.recovered = recovered
        lastScreenName = screen.localizedName
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - 230, y: area.maxY - 72 - 12))
        if !visible { panel.alphaValue = 0 }
        visible = true
        if !recovered { showCount += 1 }
        panel.orderFrontRegardless() // Never activate the app or make this panel key.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
        focusPreserved = focusPreserved && frontBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier
            && keyBefore === NSApplication.shared.keyWindow && !panel.isKeyWindow
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.token == current { self?.hide() } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    func hide() {
        guard visible else { return }
        token += 1; let current = token
        hideWork?.cancel(); hideWork = nil; visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22; panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.token == current { self?.panel.orderOut(nil) } }
        })
    }
    var snapshot: [String: Any] {
        ["visible": visible, "showCount": showCount, "recoveryCount": recoveryCount,
         "focusPreserved": focusPreserved, "canBecomeKey": panel.canBecomeKey,
         "ignoresMouseEvents": panel.ignoresMouseEvents, "screenName": lastScreenName]
    }
}
