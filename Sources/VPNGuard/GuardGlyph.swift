import AppKit
import SwiftUI

/// The one shield shape VPN Guard uses everywhere (menu bar, popover, windows, app icon),
/// with one mark per state. Geometry is in a 24 × 24 box, the same numbers as the design file.
enum GlyphKind: Equatable {
    case lock     // filled shield, lock cut out: protected
    case check    // trusted network
    case dots     // connecting / checking
    case cross    // blocked
    case pause    // paused
    case dashed   // protection off
    case bang     // needs attention
    case empty    // no network
}

enum GlyphGeometry {
    static var shield: Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 2.75))
        p.addLine(to: CGPoint(x: 5, y: 5.5))
        p.addLine(to: CGPoint(x: 5, y: 11))
        p.addCurve(to: CGPoint(x: 12, y: 21.25), control1: CGPoint(x: 5, y: 15.6), control2: CGPoint(x: 8, y: 19.4))
        p.addCurve(to: CGPoint(x: 19, y: 11), control1: CGPoint(x: 16, y: 19.4), control2: CGPoint(x: 19, y: 15.6))
        p.addLine(to: CGPoint(x: 19, y: 5.5))
        p.closeSubpath()
        return p
    }

    static var lockBody: Path {
        Path(roundedRect: CGRect(x: 9.25, y: 11, width: 5.5, height: 4.6), cornerRadius: 1)
    }

    static var lockShackle: Path {
        var p = Path()
        p.move(to: CGPoint(x: 10.3, y: 11))
        p.addLine(to: CGPoint(x: 10.3, y: 9.7))
        p.addRelativeArc(center: CGPoint(x: 12, y: 9.7), radius: 1.7, startAngle: .degrees(180), delta: .degrees(180))
        p.addLine(to: CGPoint(x: 13.7, y: 11))
        return p
    }

    static func mark(_ kind: GlyphKind) -> Path {
        var p = Path()
        switch kind {
        case .check:
            p.move(to: CGPoint(x: 8.9, y: 12.1))
            p.addLine(to: CGPoint(x: 11.1, y: 14.3))
            p.addLine(to: CGPoint(x: 15.2, y: 9.9))
        case .cross:
            p.move(to: CGPoint(x: 9.6, y: 9.6))
            p.addLine(to: CGPoint(x: 14.4, y: 14.4))
            p.move(to: CGPoint(x: 14.4, y: 9.6))
            p.addLine(to: CGPoint(x: 9.6, y: 14.4))
        case .pause:
            p.move(to: CGPoint(x: 10.3, y: 9.5))
            p.addLine(to: CGPoint(x: 10.3, y: 14.5))
            p.move(to: CGPoint(x: 13.7, y: 9.5))
            p.addLine(to: CGPoint(x: 13.7, y: 14.5))
        case .bang:
            p.move(to: CGPoint(x: 12, y: 8.25))
            p.addLine(to: CGPoint(x: 12, y: 12.85))
        default:
            break
        }
        return p
    }

    static func dots(_ kind: GlyphKind) -> [CGPoint] {
        switch kind {
        case .dots: return [CGPoint(x: 9, y: 12), CGPoint(x: 12, y: 12), CGPoint(x: 15, y: 12)]
        case .bang: return [CGPoint(x: 12, y: 15.6)]
        default: return []
        }
    }
}

enum GlyphRenderer {
    /// Draws a glyph centred in `rect` of a y-down context. `lineWidth` is in 24-unit space.
    static func draw(_ kind: GlyphKind, in ctx: CGContext, rect: CGRect, color: CGColor, lineWidth: CGFloat) {
        let scale = min(rect.width, rect.height) / 24
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)

        switch kind {
        case .lock:
            ctx.addPath(GlyphGeometry.shield.cgPath)
            ctx.fillPath()
            ctx.setBlendMode(.destinationOut)
            ctx.addPath(GlyphGeometry.lockBody.cgPath)
            ctx.fillPath()
            ctx.setLineWidth(1.35)
            ctx.addPath(GlyphGeometry.lockShackle.cgPath)
            ctx.strokePath()
        case .dashed:
            ctx.setLineDash(phase: 0, lengths: [2.2, 2.2])
            ctx.addPath(GlyphGeometry.shield.cgPath)
            ctx.strokePath()
        default:
            ctx.addPath(GlyphGeometry.shield.cgPath)
            ctx.strokePath()
            ctx.addPath(GlyphGeometry.mark(kind).cgPath)
            ctx.strokePath()
            for c in GlyphGeometry.dots(kind) {
                ctx.fillEllipse(in: CGRect(x: c.x - 1.05, y: c.y - 1.05, width: 2.1, height: 2.1))
            }
        }
        ctx.restoreGState()
    }

    private static var menuBarCache: [String: NSImage] = [:]

    /// Template image for the menu bar (macOS tints it for light and dark menu bars).
    @MainActor
    static func menuBarImage(_ kind: GlyphKind, description: String) -> NSImage {
        let key = "\(kind)"
        if let cached = menuBarCache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(kind, in: ctx, rect: rect, color: NSColor.black.cgColor, lineWidth: 1.9)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        menuBarCache[key] = image
        return image
    }
}

/// SwiftUI view of a glyph in any color and size.
struct GuardGlyph: View {
    let kind: GlyphKind
    var color: Color
    var lineWidth: CGFloat = 1.6
    @Environment(\.self) private var environment

    var body: some View {
        let cg = color.resolve(in: environment).cgColor
        Canvas { ctx, size in
            ctx.withCGContext { cgContext in
                GlyphRenderer.draw(kind, in: cgContext, rect: CGRect(origin: .zero, size: size), color: cg, lineWidth: lineWidth)
            }
        }
        .accessibilityHidden(true)
    }
}
