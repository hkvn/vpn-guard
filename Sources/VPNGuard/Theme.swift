import AppKit
import SwiftUI

// MARK: - Colors

extension Color {
    /// One color for light mode, another for dark mode.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// State colors. `fill` is the vivid one (glyphs, buttons); `text` stays readable as text.
enum Tone: Equatable {
    case green, blue, orange, yellow, gray, red

    var fill: Color {
        switch self {
        case .green: return Color(light: NSColor(hex: 0x34C759), dark: NSColor(hex: 0x30D158))
        case .blue: return Color(light: NSColor(hex: 0x007AFF), dark: NSColor(hex: 0x0A84FF))
        case .orange: return Color(light: NSColor(hex: 0xFF9500), dark: NSColor(hex: 0xFF9F0A))
        case .yellow: return Color(light: NSColor(hex: 0xFFCC00), dark: NSColor(hex: 0xFFD60A))
        case .gray: return Color(light: NSColor(hex: 0x8E8E93), dark: NSColor(hex: 0x98989D))
        case .red: return Color(light: NSColor(hex: 0xFF3B30), dark: NSColor(hex: 0xFF453A))
        }
    }

    var text: Color {
        switch self {
        case .green: return Color(light: NSColor(hex: 0x1E7F3A), dark: NSColor(hex: 0x5BE07F))
        case .blue: return Color(light: NSColor(hex: 0x0062CC), dark: NSColor(hex: 0x6CB4FF))
        case .orange: return Color(light: NSColor(hex: 0xB35900), dark: NSColor(hex: 0xFFB340))
        case .yellow: return Color(light: NSColor(hex: 0x8A6D00), dark: NSColor(hex: 0xFFE066))
        case .gray: return Color(light: NSColor(hex: 0x636366), dark: NSColor(hex: 0xAEAEB2))
        case .red: return Color(light: NSColor(hex: 0xC4271C), dark: NSColor(hex: 0xFF7A70))
        }
    }
}

enum Palette {
    // Settings window (light values from the design canvas, dark ones to match).
    static let window = Color(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x1E1E20))
    static let header = Color(light: NSColor(hex: 0xECECEE), dark: NSColor(hex: 0x2A2A2D))
    static let sheet = Color(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x232326))
    static let cardFill = Color(light: NSColor.white, dark: NSColor(hex: 0x2C2C2F))
    static let cardStroke = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))
    static let listBar = Color(light: NSColor(hex: 0xFAFAFB), dark: NSColor(hex: 0x29292C))
    static let separator = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))

    static let footer = Color(light: NSColor(white: 0, alpha: 0.03), dark: NSColor(white: 0, alpha: 0.14))
    static let card = Color.primary.opacity(0.05)
    static let cardBorder = Color.primary.opacity(0.07)
    static let tile = Color.primary.opacity(0.08)
    static let control = Color.primary.opacity(0.09)
    static let controlHover = Color.primary.opacity(0.14)
    /// Dark text on the vivid state colors (green, orange, yellow, gray, red).
    static let onFill = Color(hex: 0x1C1C1E)
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tone: Tone
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, tone: tone, height: height)
    }

    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        let tone: Tone
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.onFill)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.fill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.12 : 0)))
                .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.55))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, height: height, fullWidth: fullWidth)
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        let height: CGFloat
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && isEnabled ? Palette.controlHover : Palette.control))
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, filled: filled)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        let filled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Palette.controlHover : (filled ? Palette.control : Color.clear)))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Small parts

struct Pill: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.fill.opacity(0.16)))
            .fixedSize()
    }
}

/// The WireGuard tunnel mark: two chevrons and a bar (24-unit box, same as the design).
struct TunnelGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var p = Path()
        p.move(to: pt(5, 8)); p.addLine(to: pt(9, 12)); p.addLine(to: pt(5, 16))
        p.move(to: pt(11, 8)); p.addLine(to: pt(15, 12)); p.addLine(to: pt(11, 16))
        p.move(to: pt(17, 6)); p.addLine(to: pt(17, 18))
        return p
    }
}

struct IconTile: View {
    /// Pass this as `symbol` to draw the WireGuard tunnel mark.
    static let tunnelSymbol = "vpnguard.tunnel"

    let symbol: String
    var tone: Tone?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if symbol == Self.tunnelSymbol {
                TunnelGlyph()
                    .stroke(style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.56, height: size * 0.56)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.47, weight: .medium))
            }
        }
            .foregroundStyle(tone?.text ?? Color.primary.opacity(0.85))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(tone.map { $0.fill.opacity(0.16) } ?? Palette.tile))
            .accessibilityHidden(true)
    }
}

/// A rounded card row: icon tile, title, one line of detail, something on the right.
struct InfoCard<Trailing: View>: View {
    let symbol: String
    var tone: Tone?
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.cardBorder))
        .accessibilityElement(children: .combine)
    }
}

/// The big round status badge with the shield glyph.
struct StatusOrb: View {
    let glyph: GlyphKind
    let tone: Tone
    var size: CGFloat = 76
    var pulsing = false

    var body: some View {
        ZStack {
            Circle().fill(tone.fill.opacity(0.14))
            Circle().strokeBorder(tone.fill.opacity(0.45), lineWidth: 1)
            GuardGlyph(kind: glyph, color: tone.fill, lineWidth: 1.6)
                .frame(width: size * 0.53, height: size * 0.53)
                .phaseAnimator(pulsing ? [1.0, 0.45] : [1.0]) { view, phase in
                    view.opacity(phase)
                } animation: { _ in
                    .easeInOut(duration: 0.75)
                }
        }
        .frame(width: size, height: size)
        .shadow(color: tone.fill.opacity(0.22), radius: 14, y: 10)
        .accessibilityHidden(true)
    }
}

/// Soft light behind the orb, in the state color.
struct StateGlow: View {
    let tone: Tone
    var width: CGFloat = 300
    var height: CGFloat = 220

    var body: some View {
        EllipticalGradient(colors: [tone.fill.opacity(0.30), tone.fill.opacity(0.12), tone.fill.opacity(0)],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
