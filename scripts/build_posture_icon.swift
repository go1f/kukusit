import AppKit

// Native SF Symbol used by the original menu bar design; render vector artwork
// at icon resolution instead of enlarging the user's small screenshot.
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let symbol = NSImage(systemSymbolName: "figure.seated.side", accessibilityDescription: nil)!
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 640, weight: .medium))!
let ratio = min(720 / symbol.size.width, 720 / symbol.size.height)
let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
symbol.draw(in: NSRect(x: (1024-size.width)/2, y: (1024-size.height)/2, width: size.width, height: size.height))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
