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

private struct BannerPresentation: Equatable {
    var text = ""
    var alerts: [MonitoringAlert] = []
    var island = false
    var expanded = false
}
@MainActor private final class BannerContent: ObservableObject {
    @Published var presentation = BannerPresentation()
    var dismiss: () -> Void = {}
}
private final class BannerHostingView: NSHostingView<BannerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private enum BannerLayout {
    static let radius: CGFloat = 20
    static let indicator: CGFloat = 22
    static let gap: CGFloat = 9
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9
    static let rowGap: CGFloat = 5
    static let chrome = indicator + gap + horizontalPadding * 2
}

private struct RecoveryRing: View {
    let progress: Double
    let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var value: Double { min(1, max(0, progress)) }
    var body: some View {
        ZStack {
            Circle().stroke(Color.green.opacity(0.18), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.001, value))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion || !animates ? nil : .linear(duration: 0.22), value: value)
        }
        .padding(2).frame(width: BannerLayout.indicator, height: BannerLayout.indicator)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value >= 1 ? "已确认恢复" : "正在确认恢复")
        .accessibilityValue("\(Int(value * 100))%")
    }
}
private struct BannerView: View {
    @ObservedObject var content: BannerContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: BannerPresentation { content.presentation }
    var body: some View {
        Button(action: content.dismiss) {
            VStack(alignment: .leading, spacing: BannerLayout.rowGap) {
                if state.alerts.isEmpty { row(state.text, alert: nil) }
                else { ForEach(state.alerts) { alert in row(alert.message, alert: alert) } }
            }
            .padding(.horizontal, BannerLayout.horizontalPadding)
            .padding(.vertical, BannerLayout.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(state.island ? Color.white : Color.primary)
            .background {
                if state.island { Color.black }
                else { Rectangle().fill(.regularMaterial) }
            }
            .clipShape(RoundedRectangle(cornerRadius: BannerLayout.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: BannerLayout.radius, style: .continuous))
            .scaleEffect(reduceMotion || state.expanded ? 1 : 0.97, anchor: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.expanded)
        }
        .buttonStyle(.plain)
        .help("点击收起，30 秒内不再提醒")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "收起提醒", content.dismiss)
    }
    private func row(_ text: String, alert: MonitoringAlert?) -> some View {
        HStack(spacing: BannerLayout.gap) {
            if let alert, alert.recovering || alert.resolved {
                RecoveryRing(progress: alert.resolved ? 1 : alert.recoveryProgress, animates: alert.animateRecovery)
            } else {
                Image(systemName: "figure.seated.side").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(state.island ? Color.white.opacity(0.85) : Color.accentColor)
                    .frame(width: BannerLayout.indicator, height: BannerLayout.indicator)
            }
            Text(text).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor final class ReminderPanelController {
    private let panel: PassivePanel
    private let content = BannerContent()
    private let router: DisplayRouter
    private let now: () -> Double
    private let presentsOnScreen: Bool
    private var lifecycleWork: DispatchWorkItem?
    private var nudgeWork: DispatchWorkItem?
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
    private var missingSince: [String: Double] = [:]
    private var confirmedAt: [String: Double] = [:]
    private var latest = ReminderPresentationUpdate(alerts: [], ongoingIDs: [])
    private var dismissal = ReminderDismissal()
    private var screenObserver: NSObjectProtocol?
    private var targetFrame: NSRect?
    private var episodeSize = CGSize.zero
    private var reviewWindow: NSWindow?
    private let trackingGrace = 2.0
    private let completionHold = 3.0

    init(router: DisplayRouter, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, presentsOnScreen: Bool = true) {
        self.router = router; self.now = now; self.presentsOnScreen = presentsOnScreen
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        content.dismiss = { [weak self] in self?.dismissByUser() }
        let host = BannerHostingView(rootView: BannerView(content: content))
        host.sizingOptions = []
        host.wantsLayer = true; host.layer?.cornerRadius = BannerLayout.radius; host.layer?.masksToBounds = true
        panel.contentView = host; panel.title = "坐姿轻提醒"
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.visible == true { self?.placePanel() } }
            }
    }
    deinit { lifecycleWork?.cancel(); nudgeWork?.cancel(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    func dismissByUser() {
        dismissal.dismiss(Set(activeAlerts.map(\.id)), at: now())
        clearPresentation(); hide()
    }
    func synchronize(_ update: ReminderPresentationUpdate) {
        latest = update; activeAlerts = update.alerts
        lifecycleWork?.cancel(); lifecycleWork = nil
        let time = now()
        dismissal.reconcile(ongoingIDs: update.ongoingIDs, at: time)
        guard update.enabled, dismissal.allows("*", at: time) else { clearPresentation(); hide(); return }
        if habitBanner && update.alerts.isEmpty { return }
        let incoming = Dictionary(update.alerts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var rows: [MonitoringAlert] = []
        var deadlines: [Double] = []
        for old in presentedAlerts {
            if var fresh = incoming[old.id] {
                // Recovery changes only the left-hand progress indicator, never the instruction.
                if fresh.recovering { fresh.message = old.message }
                fresh.animateRecovery = old.recovering && fresh.recoveryProgress >= old.recoveryProgress
                rows.append(fresh); missingSince[old.id] = nil; confirmedAt[old.id] = nil
            } else if old.resolved || update.recoveredIDs.contains(old.id) {
                let start = confirmedAt[old.id] ?? time
                confirmedAt[old.id] = start; missingSince[old.id] = nil
                if time < start + completionHold {
                    var completed = old; completed.resolved = true; completed.suspended = false
                    completed.recovering = true; completed.recoveryProgress = 1
                    completed.animateRecovery = true
                    rows.append(completed); deadlines.append(start + completionHold)
                    if !old.resolved { recoveryCount += 1 }
                }
            } else {
                // Freeze the last appearance on short missing observations; never invent recovery progress.
                let start = missingSince[old.id] ?? time
                missingSince[old.id] = start; confirmedAt[old.id] = nil
                if time < start + trackingGrace {
                    var held = old; held.suspended = true
                    rows.append(held); deadlines.append(start + trackingGrace)
                }
            }
        }
        let oldIDs = Set(presentedAlerts.map(\.id))
        for alert in update.alerts where !oldIDs.contains(alert.id) {
            missingSince[alert.id] = nil; confirmedAt[alert.id] = nil; rows.append(alert)
        }
        let retained = Set(rows.map(\.id))
        missingSince = missingSince.filter { retained.contains($0.key) }
        confirmedAt = confirmedAt.filter { retained.contains($0.key) }
        presentedAlerts = rows
        guard !rows.isEmpty else { clearPresentation(); hide(); return }
        habitBanner = false; nudgeWork?.cancel(); nudgeWork = nil
        var state = content.presentation; state.alerts = rows; state.text = ""
        if state != content.presentation { content.presentation = state }
        if visible { placePanel() } else { show() }
        if let deadline = deadlines.min() {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { guard let self else { return }; self.synchronize(self.latest) }
            }
            lifecycleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, deadline-time), execute: work)
        }
    }
    // Diagnostic scenarios retain this convenience; production supplies explicit per-channel recovery evidence.
    func synchronize(_ alerts: [MonitoringAlert], recovered: Bool, ongoingIDs: Set<String>? = nil) {
        synchronize(ReminderPresentationUpdate(alerts: alerts, ongoingIDs: ongoingIDs ?? Set(alerts.map(\.id)),
            recoveredIDs: recovered ? Set(presentedAlerts.map(\.id)) : []))
    }
    private func clearPresentation() {
        lifecycleWork?.cancel(); lifecycleWork = nil; nudgeWork?.cancel(); nudgeWork = nil
        presentedAlerts = []; missingSince = [:]; confirmedAt = [:]; habitBanner = false
    }
    func handle(_ event: ReminderEvent) {
        switch event {
        case .correction(let kind):
            let alert = MonitoringAlert(id: "legacy", title: "", message: kind.message, seconds: 0, recovering: false)
            synchronize(ReminderPresentationUpdate(alerts: [alert], ongoingIDs: [alert.id]))
        case .recovered:
            synchronize(ReminderPresentationUpdate(alerts: [], ongoingIDs: [], recoveredIDs: Set(presentedAlerts.map(\.id))))
        case .quiet: synchronize(ReminderPresentationUpdate(alerts: [], ongoingIDs: Set(activeAlerts.map(\.id))))
        case .nudge(let message): showNudge(message)
        }
    }
    func preview() { showNudge("坐正，放松肩膀", ignoreInterval: true) }
    private func showNudge(_ message: String, ignoreInterval: Bool = false) {
        guard activeAlerts.isEmpty, presentedAlerts.isEmpty, dismissal.allows("nudge", at: now()),
              ignoreInterval || now()-lastShownAt >= 10 else { return }
        habitBanner = true
        var state = content.presentation; state.text = message; state.alerts = []; content.presentation = state
        show()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.habitBanner = false; self?.hide() } }
        nudgeWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+4, execute: work)
    }
    private func placePanel() {
        guard let screen = router.workingScreen() else { return }
        lastScreenName = screen.localizedName
        let single = NSScreen.screens.count == 1 || CommandLine.arguments.contains("--banner-review")
        var state = content.presentation; state.island = single
        if state != content.presentation { content.presentation = state }
        panel.level = single ? .statusBar : .floating
        let area = screen.visibleFrame, font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let rows = state.alerts.isEmpty ? [state.text] : state.alerts.map(\.message)
        let longest = rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        let cutoutWidth = single && !left.isEmpty && !right.isEmpty ? max(0, right.minX-left.maxX) : 0
        let width = min(320, area.width-24, max(160, min(260, cutoutWidth+20), ceil(longest)+BannerLayout.chrome))
        let textHeight = rows.reduce(CGFloat(0)) { total, text in
            total + max(BannerLayout.indicator, ceil((text as NSString).boundingRect(
                with: NSSize(width: width-BannerLayout.chrome, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).height))
        } + CGFloat(max(0, rows.count-1))*BannerLayout.rowGap
        let measured = CGSize(width: width, height: min(area.height-24, max(40, textHeight+BannerLayout.verticalPadding*2)))
        // Do not shrink while an episode is on screen. Progress and disappearing rows cannot bounce the window.
        episodeSize = visible ? CGSize(width: max(episodeSize.width, measured.width), height: max(episodeSize.height, measured.height)) : measured
        episodeSize.width = min(episodeSize.width, area.width-24); episodeSize.height = min(episodeSize.height, area.height-24)
        let frame = ReminderPlacement.frame(screen: screen.frame, visible: area, singleScreen: single,
            safeTop: screen.safeAreaInsets.top, size: episodeSize)
        guard frame != targetFrame else { return }
        targetFrame = frame
        if visible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
    private func show() {
        guard router.workingScreen() != nil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, key = NSApplication.shared.keyWindow
        token += 1; let current = token; lastShownAt = now()
        if !visible { panel.alphaValue = 0; content.presentation.expanded = false }
        placePanel(); visible = true; showCount += 1
        if presentsOnScreen { panel.orderFrontRegardless() }
        DispatchQueue.main.async { [weak self] in if self?.token == current { self?.content.presentation.expanded = true } }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; panel.animator().alphaValue = 1 }
        focusPreserved = focusPreserved && front == NSWorkspace.shared.frontmostApplication?.processIdentifier
            && key === NSApplication.shared.keyWindow && !panel.isKeyWindow
    }
    func hide() {
        guard visible else { return }
        token += 1; let current = token; visible = false; content.presentation.expanded = false
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.25; panel.animator().alphaValue = 0 },
            completionHandler: { [weak self] in MainActor.assumeIsolated { if self?.token == current { self?.panel.orderOut(nil) } } })
    }
    func showReviewWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(320, episodeSize.width), height: max(90, episodeSize.height+24)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "提示样式核验"; window.isReleasedWhenClosed = false
        let host = BannerHostingView(rootView: BannerView(content: content)); host.sizingOptions = []
        window.contentView = host; window.center(); reviewWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func renderReview(to url: URL) throws {
        var state = content.presentation; state.island = true; state.expanded = true; content.presentation = state
        try NativeViewRender.png(BannerView(content: content), size: episodeSize, to: url)
    }
    var snapshot: [String: Any] {
        ["windowID": panel.windowNumber, "visible": visible, "showCount": showCount, "recoveryCount": recoveryCount,
         "focusPreserved": focusPreserved, "canBecomeKey": panel.canBecomeKey, "ignoresMouseEvents": panel.ignoresMouseEvents,
         "screenName": lastScreenName, "persistent": !activeAlerts.isEmpty, "activeAlertIDs": activeAlerts.map(\.id),
         "alertCount": activeAlerts.count, "panelHeight": panel.frame.height, "panelWidth": panel.frame.width,
         "targetWidth": episodeSize.width, "targetHeight": episodeSize.height, "cornerRadius": panel.contentView?.layer?.cornerRadius ?? 0,
         "island": content.presentation.island, "panelFrame": NSStringFromRect(panel.frame),
         "acknowledgedIDs": dismissal.acknowledged.sorted(), "mutedUntil": dismissal.mutedUntil ?? 0,
         "presentedIDs": presentedAlerts.map(\.id), "messages": presentedAlerts.map(\.message),
         "resolvedIDs": presentedAlerts.filter(\.resolved).map(\.id), "suspendedIDs": presentedAlerts.filter(\.suspended).map(\.id),
         "recoveryProgress": presentedAlerts.filter { $0.recovering || $0.resolved }.map(\.recoveryProgress)]
    }
}
