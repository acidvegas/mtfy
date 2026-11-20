// Renders the 1024x1024 app icon PNG: swift scripts/make-icon.swift Resources/MenuBarIcon.svg out.png
// It's the official ntfy logo (white ">_" speech bubble on ntfy's teal gradient), laid out on the
// standard macOS icon grid.
import AppKit

let size = 1024
guard let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    fatalError("Couldn't load \(CommandLine.arguments[1])")
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile: ntfy's gradient (#348878 → #52BCA6), dark at the top left.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0x34 / 255.0, green: 0x88 / 255.0, blue: 0x78 / 255.0, alpha: 1),
                    NSColor(srgbRed: 0x52 / 255.0, green: 0xBC / 255.0, blue: 0xA6 / 255.0, alpha: 1)])!
    .draw(in: shape, angle: -45)

// The outline logo, recolored white, with the soft shadow the official icon has.
let glyph = NSImage(size: logo.size, flipped: false) { rect in
    logo.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    return true
}
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
shadow.shadowOffset = NSSize(width: 12, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
glyph.draw(in: tile.insetBy(dx: 120, dy: 120))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
