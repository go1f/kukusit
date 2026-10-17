import AppKit
import SwiftUI

// Render our own synthetic view hierarchy, without capturing the desktop or camera.
@MainActor enum NativeViewRender {
    static func png<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .transaction { $0.animation = nil })
        renderer.scale = 2
        guard let data = renderer.nsImage?.tiffRepresentation,
              let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "KukusitViewRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native view render unavailable"])
        }
        try png.write(to: url, options: .atomic)
    }
}
