import AppKit
import SwiftUI
import QuartzCore
import PostureCore

final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class BannerContent: ObservableObject {
    @Published var text = ""
    @Published var recovered = false
    @Published var alerts: [MonitoringAlert] = []
    @Published var width: CGFloat = 460
    @Published var height: CGFloat = 72
}

private struct BannerView: View {
    @ObservedObject var content: BannerContent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.recovered ? "checkmark.circle.fill" : "figure.seated.side")
                .font(.title2).foregroundStyle(content.recovered ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(content.recovered ? "已恢复" : (!content.alerts.isEmpty && content.alerts.allSatisfy(\.recovering) ? "保持一下" : "调整一下"))
                    .font(.caption).foregroundStyle(.secondary)
                if content.alerts.isEmpty {
                    Text(content.text).font(.body.weight(.medium))
                } else {
                    ForEach(content.alerts) { alert in
                        if alert.recovering {
                            HStack(spacing: 10) {
                                Text(alert.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                RecoveryLights(progress: alert.recoveryProgress)
                            }
                        } else {
                            Text(alert.message).font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: content.width, height: content.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private struct RecoveryLights: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3) { index in
                let amount = min(1, max(0, (progress - Double(index) * 0.27) / 0.2))
                Text("🟢").font(.system(size: 17))
                    .opacity(0.15 + 0.85 * amount)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: amount)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在确认恢复")
        .accessibilityValue("\(Int(min(1, max(0, progress))*100))%")
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
    private var activeAlerts: [MonitoringAlert] = []
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
        case .correction(let kind): habitBanner = false; show(kind.message, recovered: false, duration: nil)
        case .recovered:
            if visible && !habitBanner && !content.recovered { recoveryCount += 1; show("保持放松", recovered: true, duration: 1.8) }
        case .quiet: if activeAlerts.isEmpty && !habitBanner { hide() }
        case .nudge(let message):
            guard activeAlerts.isEmpty, ProcessInfo.processInfo.systemUptime - lastShownAt >= 10 else { return }
            habitBanner = true; show(message, recovered: false, duration: 4)
        }
    }
    func preview() {
        guard activeAlerts.isEmpty else { return }
        habitBanner = true
        show("坐正，放松肩膀", recovered: false, duration: 4)
    }
    func synchronize(_ alerts: [MonitoringAlert], recovered: Bool) {
        let previous = activeAlerts
        activeAlerts = alerts
        guard !alerts.isEmpty else {
            guard !previous.isEmpty else { return }
            content.alerts = []
            if recovered && visible {
                recoveryCount += 1
                show("保持放松", recovered: true, duration: 1.8)
            } else { hide() }
            return
        }
        habitBanner = false
        content.alerts = alerts
        if !visible || content.recovered || previous.map(\.id) != alerts.map(\.id) {
            show("", recovered: false, duration: nil)
        } else {
            content.recovered = false
            placePanel()
        }
    }
    private func placePanel() {
        guard let screen = router.workingScreen() else { return }
        lastScreenName = screen.localizedName
        let area = screen.visibleFrame
        let width = min(460, max(240, area.width - 24))
        let textWidth = width - 72
        let rows = content.alerts.map { alert in
            alert.recovering ? alert.title + " 🟢 🟢 🟢" : alert.message
        }
        let textHeight = rows.reduce(CGFloat(0)) { total, text in
            total + ceil((text as NSString).boundingRect(with: NSSize(width: textWidth, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).height) + 4
        }
        let height = min(area.height - 24, max(72, textHeight + 48))
        content.width = width; content.height = height
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.maxY - height - 12, width: width, height: height), display: true)
    }
    private func show(_ text: String, recovered: Bool, duration: Double?) {
        guard router.workingScreen() != nil else { return }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyBefore = NSApplication.shared.keyWindow
        token += 1; let current = token
        lastShownAt = ProcessInfo.processInfo.systemUptime
        hideWork?.cancel()
        content.text = text; content.recovered = recovered
        if activeAlerts.isEmpty { content.alerts = [] }
        placePanel()
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
        guard let duration else { hideWork = nil; return }
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
        ["windowID": panel.windowNumber, "visible": visible, "showCount": showCount, "recoveryCount": recoveryCount,
         "focusPreserved": focusPreserved, "canBecomeKey": panel.canBecomeKey,
         "ignoresMouseEvents": panel.ignoresMouseEvents, "screenName": lastScreenName,
         "persistent": !activeAlerts.isEmpty, "activeAlertIDs": activeAlerts.map(\.id), "alertCount": activeAlerts.count,
         "panelHeight": panel.frame.height,
         "recoveryProgress": activeAlerts.filter(\.recovering).map(\.recoveryProgress)]
    }
}
