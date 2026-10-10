import AppKit

// Keep the supplied artwork intact; pad its small aspect-ratio difference to a square.
let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("Usage: swift scripts/build_icons.swift source.png output.iconset")
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.white.setFill()
        canvas.fill()
        let ratio = CGFloat(pixels) / max(source.size.width, source.size.height)
        let size = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
        source.draw(in: NSRect(x: (canvas.width - size.width) / 2,
                              y: (canvas.height - size.height) / 2,
                              width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
