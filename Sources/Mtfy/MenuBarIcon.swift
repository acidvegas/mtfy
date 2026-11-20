import AppKit

/// The menu bar icon: ntfy's official outline logo (Resources/MenuBarIcon.svg, Apache-2.0,
/// from the ntfy project) with a small badge for unread, paused or a problem. Template images,
/// so macOS tints them for light and dark menu bars.
@MainActor
enum MenuBarIcon {
    enum Badge {
        case none, unread, paused, problem
    }

    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [Badge: NSImage] = [:]

    private static let logo: NSImage? = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    static func image(_ badge: Badge) -> NSImage {
        if let cached = cache[badge] { return cached }
        let image = logo.map { draw($0, badge) } ?? fallback(badge)
        image.isTemplate = true
        image.accessibilityDescription = "Mtfy"
        cache[badge] = image
        return image
    }

    private static func draw(_ logo: NSImage, _ badge: Badge) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            logo.draw(in: rect)
            guard badge != .none, let ctx = NSGraphicsContext.current else { return true }

            switch badge {
            case .paused:
                // A slash across the logo, with a cut-out border so it reads clearly.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: rect.maxY - 1))
                slash.line(to: NSPoint(x: rect.maxX - 1, y: 1))
                slash.lineCapStyle = .round
                ctx.compositingOperation = .clear
                slash.lineWidth = 4
                slash.stroke()
                ctx.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                slash.lineWidth = 1.6
                slash.stroke()
            case .unread, .problem:
                // A dot in the top-right corner, cut out from the logo behind it.
                let dot = NSRect(x: rect.maxX - 7.5, y: rect.maxY - 7.5, width: 7.5, height: 7.5)
                ctx.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.4, dy: -1.4)).fill()
                ctx.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
                if badge == .problem {
                    // "!" knocked out of the dot.
                    ctx.compositingOperation = .clear
                    NSRect(x: dot.midX - 0.6, y: dot.minY + 3, width: 1.2, height: 3).fill()
                    NSRect(x: dot.midX - 0.6, y: dot.minY + 1.4, width: 1.2, height: 1.1).fill()
                    ctx.compositingOperation = .sourceOver
                }
            case .none:
                break
            }
            return true
        }
    }

    /// Only if the logo resource is missing from the bundle.
    private static func fallback(_ badge: Badge) -> NSImage {
        let name = switch badge {
        case .none: "bell"
        case .unread: "bell.badge"
        case .paused: "bell.slash"
        case .problem: "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Mtfy") ?? NSImage(size: size)
    }
}
