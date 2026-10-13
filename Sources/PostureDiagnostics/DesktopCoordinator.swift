import AppKit
import SwiftUI
import Combine
import PostureCore

@MainActor
final class DesktopCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let model: DiagnosticModel
    let updater: AppUpdater
    let router = DisplayRouter()
    lazy var reminders = ReminderPanelController(router: router)
    @Published private(set) var pipVisible = false
    private var mainVisible = false
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pipPanel: MonitorPanel?
    private var placingPiP = false
    private var lastPlacedFrame: NSRect?
    private var placementWork: DispatchWorkItem?
    private var spaceMonitor: Any?
    private lazy var statusPanel = StatusPanelController(model: model, desktop: self)
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    init(model: DiagnosticModel) {
        self.model = model
        updater = AppUpdater(enabled: CommandLine.arguments.contains("--update-qa") || !model.isDemo && !CommandLine.arguments.contains("--demo") && !CommandLine.arguments.contains("--ui-smoke") && !CommandLine.arguments.contains("--background-check") && !CommandLine.arguments.contains("--camera-check") && !CommandLine.arguments.contains("--layout-check"))
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let statusImage = Bundle.main.url(forResource: "StatusIcon", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "figure.seated.side", accessibilityDescription: "坐姿监测")
        statusImage?.size = NSSize(width: 20, height: 20)
        statusImage?.accessibilityDescription = "坐姿监测"
        item.button?.image = statusImage
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "坐姿监测 · 点击查看状态，⌥点击切换画中画"
        model.onReminderEvent = { [weak self] event in self?.reminders.handle(event) }
        model.onReminderAlertsChanged = { [weak self] alerts, recovered, ongoing in
            self?.reminders.synchronize(alerts, recovered: recovered, ongoingIDs: ongoing)
        }
        model.onSettingsChanged = { [weak self] old, new in
            guard let self else { return }
            if self.pipPanel == nil {
                if old.pipCorner != new.pipCorner || old.pipScreenID != new.pipScreenID {
                    self.model.settings.pipPlacement = nil
                } else if old.pipSize != new.pipSize, let saved = self.model.settings.pipPlacement {
                    self.model.settings.pipPlacement = saved.changingWidth(new.pipSize.width)
                }
            }
            if old.pipSize != new.pipSize || old.pipCorner != new.pipCorner || old.pipScreenID != new.pipScreenID
                || old.pipShowsVideo != new.pipShowsVideo || old.pipShowsSkeleton != new.pipShowsSkeleton {
                self.placePiP(presetSize: old.pipSize != new.pipSize,
                              explicitPosition: old.pipCorner != new.pipCorner || old.pipScreenID != new.pipScreenID)
            }
            self.pipPanel?.level = new.pipOnTop ? .floating : .normal
            self.updateRendering()
        }
        model.onWindowClosed = { [weak self] in self?.mainVisible = false; self?.updateRendering() }
        model.$previewExpanded.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateRendering() }
        }.store(in: &subscriptions)
        model.$monitorState.removeDuplicates().sink { [weak self] state in
            self?.statusItem?.button?.toolTip = "坐姿监测 · \(state.label) · ⌥点击切换画中画"
            DispatchQueue.main.async { self?.statusPanel.updateGeometry() }
        }.store(in: &subscriptions)
        model.$metrics.map { $0?.shoulderReason ?? "" }.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.statusPanel.updateGeometry() }
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                self?.placementWork?.cancel(); self?.placementWork = nil; self?.placePiP()
            } }
        updater.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                self.statusItem?.length = self.updater.available == nil ? NSStatusItem.squareLength : 32
                self.statusItem?.button?.title = self.updater.available == nil ? "" : "·"
                self.statusPanel.updateGeometry()
            }
        }.store(in: &subscriptions)
        installApplicationMenu()
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let window = event.window, window.isKeyWindow,
                      window === self.mainWindow || window === self.pipPanel,
                      window.attachedSheet == nil, NSApplication.shared.modalWindow == nil,
                      RunLoop.current.currentMode != .eventTracking,
                      !((window.firstResponder as? NSTextView)?.isEditable ?? false) else { return false }
                if !event.isARepeat { self.model.toggleMonitoringFromKeyboard() }
                return true
            }
            return consumed ? nil : event
        }
        updateRendering()
    }

    @objc func togglePopover() {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true { togglePiP(); return }
        guard let button = statusItem?.button else { return }
        _ = router.workingScreen()
        statusPanel.toggle(relativeTo: button)
    }
    @objc func openMain() { showMain(expandPreview: true) }
    @objc func showSettings() {
        statusPanel.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "坐姿设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsWindowView(model: model, desktop: self, router: router))
            window.center(); settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func showMain(expandPreview: Bool) {
        statusPanel.hide()
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "坐姿监测"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MonitorWindowView(model: model, desktop: self))
            window.contentMinSize = NSSize(width: 720, height: 520)
            window.delegate = self
            window.center()
            mainWindow = window
            model.attachWindow(window)
        }
        mainVisible = true
        model.previewExpanded = true
        updateRendering()
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    func hideMain() {
        mainVisible = false; model.previewExpanded = false
        mainWindow?.orderOut(nil); updateRendering()
    }
    @objc func togglePiP() { pipVisible ? hidePiP() : showPiP() }
    func showPiP() {
        statusPanel.hide()
        if pipPanel == nil {
            let panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "坐姿画中画"; panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentMinSize = NSSize(width: 320, height: 240)
            panel.contentMaxSize = NSSize(width: 800, height: 720)
            panel.contentView = NSHostingView(rootView: PiPView(model: model, desktop: self))
            panel.delegate = self
            pipPanel = panel
        }
        pipVisible = true
        pipPanel?.level = model.settings.pipOnTop ? .floating : .normal
        placePiP(); updateRendering()
        pipPanel?.orderFrontRegardless()
    }
    func hidePiP() { flushPiPPlacement(); pipVisible = false; pipPanel?.orderOut(nil); updateRendering() }
    func expandPiP() { hidePiP(); showMain(expandPreview: true) }
    func collapseMainToPiP() { showPiP(); hideMain() }
    func windowDidMove(_ notification: Notification) { queuePiPPlacement(notification) }
    func windowDidResize(_ notification: Notification) { queuePiPPlacement(notification) }
    private func queuePiPPlacement(_ notification: Notification) {
        guard !placingPiP, pipVisible, let panel = notification.object as? NSWindow,
              panel === pipPanel, panel.isVisible, panel.frame != lastPlacedFrame else { return }
        lastPlacedFrame = nil
        placementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPiPPlacement() }
        }
        placementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3, execute: work)
    }
    private func flushPiPPlacement() {
        guard placementWork != nil, let panel = pipPanel, let screen = panel.screen else { return }
        placementWork?.cancel(); placementWork = nil
        let placement = FloatingWindowPlacement(displayID: router.identifier(screen), frame: panel.frame,
            visibleFrame: screen.visibleFrame, contentWidth: panel.contentRect(forFrameRect: panel.frame).width)
        if model.settings.pipPlacement != placement { model.settings.pipPlacement = placement }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === pipPanel { flushPiPPlacement(); pipVisible = false; updateRendering() }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow { mainVisible = false; updateRendering() }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow { mainVisible = true; updateRendering() }
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === pipPanel else { return frameSize }
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let width = max(320, min(800, proposed.width))
        let visual = model.settings.pipShowsVideo || model.settings.pipShowsSkeleton
        let height = WindowLayout.pipHeight(width: width, visual: visual, demo: model.isDemo)
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
    }
    private func placePiP(presetSize: Bool = false, explicitPosition: Bool = false) {
        guard let panel = pipPanel else { return }
        flushPiPPlacement()
        let saved = model.settings.pipPlacement
        let screen = (!explicitPosition ? saved.flatMap { placement in
            NSScreen.screens.first { router.identifier($0) == placement.displayID }
        } : nil) ?? router.screen(preference: model.settings.pipScreenID)
        guard let screen else { return }
        placingPiP = true; defer { placingPiP = false }
        let visual = model.settings.pipShowsVideo || model.settings.pipShowsSkeleton
        let requestedWidth = presetSize ? model.settings.pipSize.width : saved?.contentWidth ?? model.settings.pipSize.width
        let chrome = panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
        let heightBound = visual ? max(320, 20 + (screen.visibleFrame.height - 36 - chrome - 108 - (model.isDemo ? 20 : 0)) * 16 / 9) : 800
        let width = min(screen.visibleFrame.width - 36, heightBound, requestedWidth)
        panel.contentMinSize = NSSize(width: 320, height: visual ? 260 : 100)
        panel.setContentSize(NSSize(width: width, height: WindowLayout.pipHeight(width: width, visual: visual, demo: model.isDemo)))
        let area = screen.visibleFrame, frame = panel.frame
        if !explicitPosition, let saved {
            panel.setFrameOrigin(saved.origin(visibleFrame: area, windowSize: frame.size))
        } else {
            let left = model.settings.pipCorner == .topLeft || model.settings.pipCorner == .bottomLeft
            let top = model.settings.pipCorner == .topLeft || model.settings.pipCorner == .topRight
            panel.setFrameOrigin(NSPoint(x: left ? area.minX + 18 : area.maxX - frame.width - 18,
                                        y: top ? area.maxY - frame.height - 18 : area.minY + 18))
        }
        lastPlacedFrame = panel.frame
        if explicitPosition || presetSize {
            model.settings.pipPlacement = FloatingWindowPlacement(displayID: router.identifier(screen),
                frame: panel.frame, visibleFrame: area, contentWidth: width)
        }
    }
    private func updateRendering() {
        let full = mainVisible && model.previewExpanded
        model.setRendering(image: full || (pipVisible && model.settings.pipShowsVideo),
                           skeleton: full || (pipVisible && model.settings.pipShowsSkeleton))
    }
    func previewReminder() { reminders.preview() }
    func shutdown() {
        flushPiPPlacement(); placementWork?.cancel()
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        reminders.hide(); statusPanel.hide(); pipPanel?.orderOut(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
    private func installApplicationMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(title: "坐姿监测", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "坐姿监测")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let status = NSMenuItem(title: "显示菜单栏状态", action: #selector(togglePopover), keyEquivalent: "M")
        status.keyEquivalentModifierMask = [.command, .shift]; status.target = self; menu.addItem(status)
        let open = NSMenuItem(title: "打开监测窗口", action: #selector(openMain), keyEquivalent: "D")
        open.keyEquivalentModifierMask = [.command, .shift]; open.target = self; menu.addItem(open)
        let pip = NSMenuItem(title: "切换画中画", action: #selector(togglePiP), keyEquivalent: "p")
        pip.keyEquivalentModifierMask = [.command, .option]; pip.target = self; menu.addItem(pip)
        menu.addItem(.separator())
        let update = NSMenuItem(title: "检查更新…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater; menu.addItem(update)
        updater.$canCheck.receive(on: RunLoop.main).sink { update.isEnabled = $0 }.store(in: &subscriptions)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出坐姿监测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = menu; root.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit; root.addItem(editItem)
        NSApplication.shared.mainMenu = root
    }
    var presentationSnapshot: [String: Any] {
        ["pipVisible": pipVisible, "mainVisible": mainVisible, "previewExpanded": model.previewExpanded,
         "popoverVisible": statusPanel.visible, "statusPanel": statusPanel.snapshot,
         "statusItemVisible": statusItem?.isVisible ?? false,
         "pipOnTop": pipPanel?.level == .floating, "pipCanBecomeKey": pipPanel?.canBecomeKey ?? false,
         "previewImageRequested": model.renderingImageRequested, "skeletonRenderingRequested": model.renderingSkeletonRequested,
         "lastFrameHasImage": model.frame?.image != nil,
         "pipFrame": pipPanel.map { NSStringFromRect($0.frame) } ?? "",
         "pipDisplayID": pipPanel?.screen.map { router.identifier($0) } ?? ""]
    }
}
