import AppKit
import CoreGraphics
import CryptoKit

struct MonitorDisplay: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class DisplayRouter: ObservableObject {
    @Published private(set) var displays: [MonitorDisplay] = []
    private var lastWorkDisplayID: String?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    init() {
        refresh()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { _ = self?.workingScreen() } }
    }
    func refresh() { displays = NSScreen.screens.map { MonitorDisplay(id: identifier($0), name: $0.localizedName) } }
    func identifier(_ screen: NSScreen) -> String {
        let id = displayID(screen)
        let hardware = "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id)):\(CGDisplayIsBuiltin(id))"
        return SHA256.hash(data: Data(hardware.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    func screen(preference: String) -> NSScreen? {
        if preference != "automatic", let chosen = NSScreen.screens.first(where: { identifier($0) == preference }) { return chosen }
        return workingScreen()
    }
    func workingScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            // Only use owner PID and geometry; never read titles or capture other apps.
            let primaryHeight = screens[0].frame.height
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == front.processIdentifier,
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                      bounds.width > 120, bounds.height > 80 else { continue }
                let appKitBounds = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
                if let selected = screens.max(by: { overlap($0.frame, appKitBounds) < overlap($1.frame, appKitBounds) }),
                   overlap(selected.frame, appKitBounds) > 0 {
                    lastWorkDisplayID = identifier(selected)
                    return selected
                }
            }
        }
        if let lastWorkDisplayID, let previous = screens.first(where: { identifier($0) == lastWorkDisplayID }) { return previous }
        return screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? screens[0]
    }
    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    private func overlap(_ first: CGRect, _ second: CGRect) -> Double {
        let rectangle = first.intersection(second)
        return rectangle.isNull ? 0 : rectangle.width * rectangle.height
    }
}
