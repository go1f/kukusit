import AppKit

/// The running application's Dock icon follows the system appearance. Finder and
/// Launch Services continue to use the supplied transparent artwork in the ICNS.
@MainActor
final class AppAppearance {
    private var observation: NSKeyValueObservation?
    private var lightImage: NSImage?
    private var darkImage: NSImage?

    func start() {
        guard observation == nil else { return }
        lightImage = icon(named: "KukusitLight")
        darkImage = icon(named: "KukusitDark")
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        updateIcon()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    static func usesDarkBackground(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func icon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func updateIcon() {
        let image = Self.usesDarkBackground(NSApplication.shared.effectiveAppearance) ? darkImage : lightImage
        // A missing resource retains the transparent bundle icon instead of a generic icon.
        if let image { NSApplication.shared.applicationIconImage = image }
    }
}
