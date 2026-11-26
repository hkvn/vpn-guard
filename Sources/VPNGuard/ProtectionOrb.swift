import SwiftUI

/// How the orb moves in each state (design canvas: "Status orb · motion").
struct OrbMotion: Equatable {
    /// Seconds for one turn of the light arc; nil = no arc.
    var arcPeriod: Double?
    /// Seconds for one breath of the halo; nil = no halo.
    var haloPeriod: Double?
    var haloScale: ClosedRange<CGFloat> = 0.92...1.18
    var haloOpacity: ClosedRange<Double> = 0.35...0.75

    var isAnimated: Bool { arcPeriod != nil || haloPeriod != nil }

    static func of(_ glyph: GlyphKind, tone: Tone) -> OrbMotion {
        switch glyph {
        case .lock: return OrbMotion(arcPeriod: 7, haloPeriod: 3.6)                       // protected: calm guard
        case .dots: return OrbMotion(arcPeriod: 1.1, haloPeriod: 1.2, haloOpacity: 0.3...0.6) // connecting / checking
        case .cross: return OrbMotion(haloPeriod: 2.6, haloScale: 0.95...1.1, haloOpacity: 0.25...0.6) // blocked
        case .check: return OrbMotion(haloPeriod: 6, haloOpacity: 0.2...0.45)              // trusted: very calm
        case .pause: return OrbMotion(haloPeriod: 4.5, haloOpacity: 0.2...0.45)
        case .bang: return OrbMotion(haloPeriod: 2, haloScale: 0.95...1.1, haloOpacity: 0.25...0.6)
        case .dashed, .empty: return OrbMotion()
        }
    }

    /// 0...1, a smooth wave with the given period.
    static func wave(_ t: TimeInterval, period: Double) -> Double {
        (sin(t * 2 * .pi / period - .pi / 2) + 1) / 2
    }
}

/// The big status orb in the popover. Press and hold it for 0.7 s to turn protection on or off:
/// a ring fills while holding, then it toggles with a ripple.
struct ProtectionOrb: View {
    let glyph: GlyphKind
    let tone: Tone
    let isOn: Bool
    /// nil = not interactive (helper not ready).
    let toggle: (() -> Void)?
    var size: CGFloat = 76

    static let holdDuration = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holding = false
    @State private var progress: CGFloat = 0
    @State private var hovering = false
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity = 0.0
    @State private var rippleTone: Tone = .green

    var body: some View {
        let motion = OrbMotion.of(glyph, tone: tone)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !motion.isAnimated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                halo(motion, t)
                ripple
                arc(motion, t)
                holdRing
                orb
            }
        }
        .frame(width: size + 36, height: size + 36)
        .contentShape(Circle().inset(by: 14))
        .onHover { hovering = toggle != nil && $0 }
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 30) {
            fire()
        } onPressingChanged: { pressing in
            guard toggle != nil else { return }
            holding = pressing
            if pressing {
                withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
            } else if progress < 1 {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .help(toggle == nil ? "" : "Press and hold to turn protection \(isOn ? "off" : "on")")
        .accessibilityElement()
        .accessibilityLabel("Protection")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(toggle == nil ? [] : .isButton)
        .accessibilityAction { if toggle != nil { fire() } }
    }

    // MARK: Layers

    @ViewBuilder private func halo(_ motion: OrbMotion, _ t: TimeInterval) -> some View {
        if let period = motion.haloPeriod {
            let w = reduceMotion ? 0.5 : OrbMotion.wave(t, period: period)
            let scale = motion.haloScale.lowerBound + (motion.haloScale.upperBound - motion.haloScale.lowerBound) * w
            let opacity = motion.haloOpacity.lowerBound + (motion.haloOpacity.upperBound - motion.haloOpacity.lowerBound) * w
            Circle()
                .fill(tone.fill)
                .frame(width: size, height: size)
                .blur(radius: 14)
                .scaleEffect(scale)
                .opacity(opacity)
        }
    }

    private var ripple: some View {
        Circle()
            .strokeBorder(rippleTone.fill, lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(rippleScale)
            .opacity(rippleOpacity)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func arc(_ motion: OrbMotion, _ t: TimeInterval) -> some View {
        if let period = motion.arcPeriod {
            let angle = reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: period) / period) * 360
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.146)
                    .stroke(tone.fill.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .trim(from: 0.2, to: 0.233)
                    .stroke(tone.fill.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(width: size + 20, height: size + 20)
            .rotationEffect(.degrees(angle))
            .transition(.opacity)
        }
    }

    private var holdRing: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(tone.fill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: size + 20, height: size + 20)
            .opacity(progress > 0 ? 1 : 0)
    }

    private var orb: some View {
        ZStack {
            Circle().fill(tone.fill.opacity(0.16))
            Circle().strokeBorder(tone.fill.opacity(0.5), lineWidth: 1)
            GuardGlyph(kind: glyph, color: tone.fill, lineWidth: 1.6)
                .frame(width: size * 0.53, height: size * 0.53)
                .id(glyph)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
        }
        .frame(width: size, height: size)
        .shadow(color: tone.fill.opacity(0.24), radius: 13, y: 10)
        .scaleEffect(holding ? 0.93 : (hovering ? 1.04 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: holding)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(.spring(response: 0.45, dampingFraction: 0.62), value: glyph)
        .animation(.easeInOut(duration: 0.4), value: tone)
    }

    // MARK: Toggle

    private func fire() {
        guard let toggle else { return }
        rippleTone = tone
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            rippleScale = 1
            rippleOpacity = 0.6
        }
        withAnimation(.easeOut(duration: 0.85)) {
            rippleScale = 2.1
            rippleOpacity = 0
        }
        holding = false
        withAnimation(.easeOut(duration: 0.3).delay(0.15)) { progress = 0 }
        toggle()
    }
}

/// The soft light behind the orb, breathing with it.
struct BreathingGlow: View {
    let tone: Tone
    let glyph: GlyphKind
    var width: CGFloat = 340
    var height: CGFloat = 260

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = OrbMotion.of(glyph, tone: tone)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || motion.haloPeriod == nil)) { context in
            let w = motion.haloPeriod.map { OrbMotion.wave(context.date.timeIntervalSinceReferenceDate, period: $0) } ?? 1
            StateGlow(tone: tone, width: width, height: height)
                .opacity(reduceMotion ? 0.85 : 0.7 + 0.3 * w)
        }
        .allowsHitTesting(false)
    }
}
