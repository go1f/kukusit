import AppKit
import PostureCore

/// Separate non-key windows keep the desktop between the companion and its speech clickable.
@MainActor final class DesktopPetController {
    var onDismiss: () -> Void = {}
    private let cat = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 104, height: 174),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var bubbles: [String: (PassivePanel, ComicBubbleView)] = [:]
    private var order: [String] = []
    private var timer: Timer?
    private var enabled = false
    private var hidden = UserDefaults.standard.bool(forKey: "desktopPet.hidden")
    private var placed = false
    private let defaults = UserDefaults.standard
    private let router = DisplayRouter()
    private var screenObserver: NSObjectProtocol?
    private var catView: CatCompanionView!
    private var lastMessages: [MonitoringAlert] = []
    private var lastText = ""
    init() {
        configure(cat)
        cat.title = "KukuSeat 小灰猫"
        catView = CatCompanionView(frame: NSRect(origin: .zero, size: cat.frame.size))
        catView.onClick = { [weak self] in self?.onDismiss() }
        catView.onMove = { [weak self] delta, finished in self?.move(delta, finished: finished) }
        catView.onHide = { [weak self] in self?.toggleVisibility() }
        cat.contentView = catView
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.restore(); self?.layout() } }
    }
    deinit { timer?.invalidate(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    func setEnabled(_ value: Bool) {
        let shouldShow = value && !hidden
        if enabled == value && cat.isVisible == shouldShow { return }
        enabled = value
        guard value && !hidden else { shutdownWindows(); return }
        if !placed { restore() }
        cat.orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.catView.needsDisplay = true }
                    for (_, view) in self.bubbles.values where !view.finishedInflating { view.needsDisplay = true }
                }
            }
        }
    }
    func toggleVisibility() {
        hidden.toggle(); defaults.set(hidden, forKey: "desktopPet.hidden")
        setEnabled(enabled)
        if !hidden { present(lastMessages, text: lastText) }
    }
    func present(_ alerts: [MonitoringAlert], text: String) {
        lastMessages = alerts; lastText = text
        guard enabled && !hidden else { return }
        let items: [(String, String, Bool, Bool)] = alerts.isEmpty ? (text.isEmpty ? [] : [("nudge", text, false, false)]) :
            alerts.map { ($0.id, $0.message, $0.recovering, $0.resolved) }
        let ids = Set(items.map { $0.0 })
        for id in order where !ids.contains(id) { bubbles[id]?.0.orderOut(nil); bubbles[id] = nil }
        order.removeAll { !ids.contains($0) }
        var added = 0
        for (id, message, recovering, resolved) in items {
            if let (_, view) = bubbles[id] {
                view.update(message: message, recovering: recovering, resolved: resolved)
            } else {
                let view = ComicBubbleView(message: message, delay: Double(added) * 0.65)
                view.update(message: message, recovering: recovering, resolved: resolved)
                let panel = PassivePanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                configure(panel); panel.contentView = view
                view.onClick = { [weak self] in self?.onDismiss() }
                bubbles[id] = (panel, view); order.append(id); added += 1
            }
        }
        layout()
        for (panel, _) in bubbles.values where !panel.isVisible { panel.orderFrontRegardless() }
    }
    func hideBubbles() {
        for (panel, _) in bubbles.values { panel.orderOut(nil) }
        bubbles.removeAll(); stableFrames = [:]; order = []; lastMessages = []; lastText = ""
    }
    func shutdown() { enabled = false; shutdownWindows() }
    private func shutdownWindows() {
        timer?.invalidate(); timer = nil; cat.orderOut(nil)
        for (panel, _) in bubbles.values { panel.orderOut(nil) }
    }
    private func restore() {
        let id = defaults.string(forKey: "desktopPet.screen")
        let screen = NSScreen.screens.first { screenID($0) == id } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = defaults.object(forKey: "desktopPet.x") as? Double ?? 0.85
        let y = defaults.object(forKey: "desktopPet.y") as? Double ?? 0.18
        cat.setFrameOrigin(NSPoint(x: area.minX + min(1,max(0,x))*max(0,area.width-cat.frame.width),
            y: area.minY + min(1,max(0,y))*max(0,area.height-cat.frame.height)))
        placed = true
    }
    private func screenID(_ screen: NSScreen) -> String { router.identifier(screen) }
    private func move(_ delta: NSPoint, finished: Bool) {
        cat.setFrameOrigin(NSPoint(x: cat.frame.minX + delta.x, y: cat.frame.minY + delta.y))
        if finished {
            let screen = NSScreen.screens.max { overlap($0.visibleFrame, cat.frame) < overlap($1.visibleFrame, cat.frame) }
            if let screen {
                let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                cat.setFrameOrigin(PetPlacement.clamp(cat.frame, to: area).origin)
                defaults.set(screenID(screen), forKey: "desktopPet.screen")
                defaults.set((cat.frame.minX-area.minX)/max(1,area.width-cat.frame.width), forKey: "desktopPet.x")
                defaults.set((cat.frame.minY-area.minY)/max(1,area.height-cat.frame.height), forKey: "desktopPet.y")
            }
        }
        layout()
    }
    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat { let i = a.intersection(b); return i.isNull ? 0 : i.width*i.height }
    private var stableFrames: [String: CGRect] = [:]
    private var lastCatFrame = CGRect.zero
    private var lastArea = CGRect.zero
    private var layoutSeed = Int.random(in: 0..<8)
    private func layout() {
        guard let screen = NSScreen.screens.max(by: { overlap($0.visibleFrame, cat.frame) < overlap($1.visibleFrame, cat.frame) }) else { return }
        let area = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        if lastCatFrame != cat.frame || lastArea != area { stableFrames = [:] }
        lastCatFrame = cat.frame; lastArea = area
        stableFrames = stableFrames.filter { order.contains($0.key) }
        let frames = PetPlacement.bubbles(around: cat.frame, sizes: order.compactMap { bubbles[$0]?.0.frame.size },
            in: area, seed: layoutSeed, preferred: order.map { stableFrames[$0] })
        for (id, frame) in zip(order, frames) {
            guard let (panel, view) = bubbles[id] else { continue }
            stableFrames[id] = frame
            panel.setFrame(frame, display: true)
            view.tailOnLeft = frame.midX > cat.frame.midX
        }
    }
    var snapshot: [String: Any] { ["catVisible": cat.isVisible, "bubbleCount": bubbles.count, "catFrame": NSStringFromRect(cat.frame), "hidden": hidden] }
}

private final class CatCompanionView: NSView {
    var onClick: () -> Void = {}
    var onMove: (NSPoint, Bool) -> Void = { _,_ in }
    var onHide: () -> Void = {}
    private var down = NSPoint.zero, previous = NSPoint.zero
    private var dragging = false
    private let artwork: CGImage? = {
        guard let url = Bundle.main.url(forResource: "Companion", withExtension: "png"),
              let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return cg.cropping(to: CGRect(x: 220, y: 40, width: 540, height: 910))?
            .copy(maskingColorComponents: [245,255,245,255,245,255])
    }()
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); toolTip = "拖动小灰猫移动；点击收起提示并安静 30 秒；右键隐藏"; setAccessibilityLabel("KukuSeat 小灰猫，拖动移动，点击安静三十秒") }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { down = NSEvent.mouseLocation; previous = down; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if hypot(p.x-down.x, p.y-down.y) > 4 { dragging = true }
        if dragging { onMove(NSPoint(x: p.x-previous.x, y: p.y-previous.y), false); previous = p }
    }
    override func mouseUp(with event: NSEvent) { if dragging { onMove(.zero, true) } else { onClick() } }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(); let item = NSMenuItem(title: "隐藏小灰猫（可从菜单栏找回）", action: #selector(hidePet), keyEquivalent: "")
        item.target = self; menu.addItem(item); NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func hidePet() { onHide() }
    override func draw(_ dirtyRect: NSRect) {
        guard let artwork, let c = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 5, dy: 8)
        c.interpolationQuality = .high; c.draw(artwork, in: rect)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let phase = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 5)/5
        let t = phase < 0.4 ? phase/0.4 : (1-phase)/0.6
        let breath = (1-cos(.pi*t))/2
        // Only resample the original belly; head, chair and legs stay completely still.
        for y in stride(from: 570, to: 752, by: 2) {
            let v = Double(y-570)/182, shift = 5*breath*pow(sin(.pi*v),2)
            guard let strip = artwork.cropping(to: CGRect(x: 260, y: y, width: 220, height: 2)) else { continue }
            c.draw(strip, in: CGRect(x: rect.minX+260/540*rect.width, y: rect.maxY-CGFloat(y+2)/910*rect.height,
                width: CGFloat(220+shift)/540*rect.width, height: 2/910*rect.height))
        }
    }
}

private final class ComicBubbleView: NSView {
    var onClick: () -> Void = {}
    var tailOnLeft = true { didSet { if oldValue != tailOnLeft { needsDisplay = true } } }
    private var message: String
    private var recovering = false, resolved = false
    private let born: Double
    private let tilt = Double.random(in: -0.025...0.025)
    var finishedInflating: Bool { ProcessInfo.processInfo.systemUptime >= born+1.8 }
    init(message: String, delay: Double) {
        self.message = message; born = ProcessInfo.processInfo.systemUptime + delay
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size(message).width, height: Self.size(message).height))
        toolTip = "点击收起所有提示，30 秒内不再提醒"
    }
    required init?(coder: NSCoder) { fatalError() }
    static func lines(_ text: String) -> String {
        guard text.count > 4, !text.contains("\n") else { return text }
        let middle = text.index(text.startIndex, offsetBy: (text.count+1)/2)
        return String(text[..<middle])+"\n　"+text[middle...]
    }
    static func size(_ text: String) -> NSSize {
        let size = (lines(text) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        return NSSize(width: min(240,max(80,ceil(size.width)+36)), height: max(64,ceil(size.height)+36))
    }
    func update(message: String, recovering: Bool, resolved: Bool) {
        guard self.message != message || self.recovering != recovering || self.resolved != resolved else { return }
        self.message = message; self.recovering = recovering; self.resolved = resolved; needsDisplay = true
        setAccessibilityLabel(message + (resolved ? "，已恢复" : recovering ? "，正在恢复" : ""))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick() }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let elapsed = max(0,ProcessInfo.processInfo.systemUptime-born)
        guard ProcessInfo.processInfo.systemUptime >= born else { return }
        let p = min(1,elapsed/1.8), eased = p*p*(3-2*p)
        let scale = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.35 + 0.65*eased
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: bounds.midX, y: bounds.midY); c.scaleBy(x: scale,y: scale); c.rotate(by: tilt)
        c.translateBy(x: -bounds.midX,y: -bounds.midY); c.setAlpha(min(1,elapsed/0.4))
        let b = bounds.insetBy(dx: 6,dy: 9), path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX+b.width*0.48,y: b.maxY))
        path.curve(to: NSPoint(x: b.maxX,y: b.midY),controlPoint1: NSPoint(x: b.maxX-5,y: b.maxY+2),controlPoint2: NSPoint(x: b.maxX+2,y: b.maxY-12))
        if !tailOnLeft { path.line(to: NSPoint(x:b.maxX-10,y:b.minY+10)); path.line(to:NSPoint(x:b.maxX-2,y:2)); path.line(to:NSPoint(x:b.maxX-21,y:b.minY+2)) }
        path.curve(to: NSPoint(x: b.midX,y: b.minY),controlPoint1: NSPoint(x: b.maxX+2,y: b.minY+8),controlPoint2: NSPoint(x: b.maxX-20,y: b.minY-2))
        if tailOnLeft { path.line(to: NSPoint(x: b.minX+9,y: 2)); path.line(to: NSPoint(x:b.minX+16,y:b.minY+8)) }
        path.curve(to: NSPoint(x: b.minX,y: b.midY),controlPoint1: NSPoint(x: b.minX+6,y: b.minY-1),controlPoint2: NSPoint(x: b.minX-3,y: b.minY+16))
        path.curve(to: NSPoint(x: b.minX+b.width*0.48,y: b.maxY),controlPoint1: NSPoint(x: b.minX-2,y: b.maxY-8),controlPoint2: NSPoint(x: b.minX+18,y: b.maxY+3)); path.close()
        NSColor.white.setFill(); path.fill()
        (resolved ? NSColor.systemGreen : NSColor(white: recovering ? 0.4 : 0.25,alpha:1)).setStroke(); path.lineWidth = 1.15; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let text = Self.lines(message)+(resolved ? " ✓" : "")
        (text as NSString).draw(in: b.insetBy(dx: 9,dy: 9), withAttributes: [.font: NSFont.systemFont(ofSize:14), .foregroundColor:NSColor(white:0.15,alpha:1), .paragraphStyle:paragraph])
    }
}

@MainActor enum DesktopPetChecks {
    static func run(directory: String) {
        _ = NSApplication.shared
        do {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1000,pixelsHigh:700,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor(white:0.93,alpha:1).setFill(); NSRect(x:0,y:0,width:1000,height:700).fill()
            let c = NSGraphicsContext.current!.cgContext
            c.scaleBy(x:2,y:2)
            let cat = CatCompanionView(frame:NSRect(x:0,y:0,width:104,height:174))
            c.saveGState(); c.translateBy(x:198,y:90); cat.draw(cat.bounds); c.restoreGState()
            let messages = ["头向左扶正","双肩放平","放松下颌","手离开嘴巴"]
            let views = messages.map { ComicBubbleView(message:$0,delay:-2) }
            let frames = PetPlacement.bubbles(around:CGRect(x:198,y:90,width:104,height:174),sizes:views.map(\.frame.size),in:CGRect(x:0,y:0,width:500,height:350),seed:3)
            for (view,frame) in zip(views,frames) {
                view.tailOnLeft = frame.midX > 250
                c.saveGState(); c.translateBy(x:frame.minX,y:frame.minY); view.draw(view.bounds); c.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("desktop-pet.png"))
            print("Rendered original-art companion and four independent native comic bubbles")
        } catch { fputs("Pet render failed: \(error)\n",stderr); exit(1) }
    }
}
