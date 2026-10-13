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
    @Published var width: CGFloat = 220
    @Published var height: CGFloat = 38
    @Published var island = false
    @Published var expanded = false
    var dismiss: () -> Void = {}
}

private final class BannerHostingView: NSHostingView<BannerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct BannerView: View {
    @ObservedObject var content: BannerContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var radius: CGFloat { min(content.height/2, 22) }
    var body: some View {
        Button(action: content.dismiss) {
            HStack(spacing: 9) {
                Image(systemName: content.recovered ? "checkmark.circle.fill" : "figure.seated.side")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(content.recovered ? Color.green : (content.island ? Color.white.opacity(0.85) : Color.accentColor))
                VStack(alignment: .leading, spacing: 5) {
                    if content.alerts.isEmpty {
                        Text(content.recovered ? "已恢复" : content.text).font(.system(size: 13, weight: .medium))
                    } else {
                        ForEach(content.alerts) { alert in
                            if alert.recovering {
                                HStack(spacing: 8) {
                                    Text(alert.title).font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(content.island ? Color.white.opacity(0.6) : Color.secondary)
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
            .foregroundStyle(content.island ? Color.white : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(width: content.width, height: content.height)
            .background {
                if content.island {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(content.island ? 0.08 : 0.04)))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(x: reduceMotion || content.expanded ? 1 : (content.island ? 0.62 : 0.95),
                         y: reduceMotion || content.expanded ? 1 : (content.island ? 0.12 : 0.7), anchor: .top)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: content.expanded)
        }
        .buttonStyle(.plain)
        .help("点击收起本次提醒")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "收起提醒", content.dismiss)
    }
}

private struct RecoveryLights: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                let amount = min(1, max(0, (progress - Double(index) * 0.27) / 0.2))
                Text("🟢").font(.system(size: 15))
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
    private var presentedAlerts: [MonitoringAlert] = []
    private var dismissal = ReminderDismissal()
    private var screenObserver: NSObjectProtocol?
    private var targetFrame: NSRect?
    private var reviewWindow: NSWindow?
    init(router: DisplayRouter) {
        self.router = router
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        content.dismiss = { [weak self] in self?.dismissByUser() }
        panel.contentView = BannerHostingView(rootView: BannerView(content: content))
        panel.title = "坐姿轻提醒"
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.visible == true { self?.placePanel() } }
            }
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func dismissByUser() {
        dismissal.dismiss(Set(activeAlerts.map(\.id)))
        presentedAlerts = []
        hide()
    }
    func showReviewWindow() {
        // A standard QA window renders the real component for native UI tools that
        // cannot target passive borderless windows. It is never opened in normal use.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "提示样式核验"; window.isReleasedWhenClosed = false
        window.contentView = BannerHostingView(rootView: BannerView(content: content))
        window.center(); reviewWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
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
    func synchronize(_ alerts: [MonitoringAlert], recovered: Bool, ongoingIDs: Set<String>? = nil) {
        let previous = presentedAlerts
        activeAlerts = alerts
        dismissal.reconcile(ongoingIDs: ongoingIDs ?? Set(alerts.map(\.id)))
        let presented = alerts.filter { dismissal.allows($0.id) }
        presentedAlerts = presented
        guard !presented.isEmpty else {
            guard !previous.isEmpty else { return }
            content.alerts = []
            if recovered && visible && dismissal.acknowledged.isEmpty {
                recoveryCount += 1
                show("保持放松", recovered: true, duration: 1.8)
            } else { hide() }
            return
        }
        habitBanner = false
        content.alerts = presented
        if !visible || content.recovered || previous.map(\.id) != presented.map(\.id) {
            show("", recovered: false, duration: nil)
        } else {
            content.recovered = false
            placePanel()
        }
    }
    private func placePanel() {
        guard let screen = router.workingScreen() else { return }
        lastScreenName = screen.localizedName
        let single = NSScreen.screens.count == 1 || CommandLine.arguments.contains("--banner-review")
        content.island = single
        panel.level = single ? .statusBar : .floating
        let area = screen.visibleFrame
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let rows = content.alerts.isEmpty ? [content.recovered ? "已恢复" : content.text] : content.alerts.map {
            $0.recovering ? $0.title + "  🟢 🟢 🟢" : $0.message
        }
        let longest = rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        let cutoutWidth = single && !left.isEmpty && !right.isEmpty ? max(0, right.minX-left.maxX) : 0
        let minimumWidth = max(160, min(260, cutoutWidth + 20))
        let width = min(320, area.width-24, max(minimumWidth, ceil(longest)+60))
        let textHeight = rows.reduce(CGFloat(0)) { total, text in
            total + max(17, ceil((text as NSString).boundingRect(with: NSSize(width: width-60, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height))
        } + CGFloat(max(0, rows.count-1))*5
        let height = min(area.height-24, max(38, textHeight+18))
        content.width = width; content.height = height
        // Attach just below the hardware cutout on notched Macs. Without a cutout,
        // the compact island sits at the top centre of the menu bar.
        let nextFrame = ReminderPlacement.frame(screen: screen.frame, visible: area, singleScreen: single,
            safeTop: screen.safeAreaInsets.top, size: CGSize(width: width, height: height))
        guard nextFrame != targetFrame else { return }
        targetFrame = nextFrame
        if visible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(nextFrame, display: true)
            }
        } else { panel.setFrame(nextFrame, display: true) }
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
        if !visible { panel.alphaValue = 0; content.expanded = false }
        visible = true
        if !recovered { showCount += 1 }
        panel.orderFrontRegardless() // Never activate the app or make this panel key.
        DispatchQueue.main.async { [weak self] in
            if self?.token == current { self?.content.expanded = true }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        hideWork?.cancel(); hideWork = nil; visible = false; content.expanded = false
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
         "panelHeight": panel.frame.height, "panelWidth": panel.frame.width,
         "island": content.island, "panelFrame": NSStringFromRect(panel.frame),
         "acknowledgedIDs": dismissal.acknowledged.sorted(), "presentedIDs": presentedAlerts.map(\.id),
         "recoveryProgress": activeAlerts.filter(\.recovering).map(\.recoveryProgress)]
    }
}
