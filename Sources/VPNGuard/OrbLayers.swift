import AppKit
import QuartzCore
import SwiftUI

/// The popover's moving parts (the orb's halo and light arc, the glow behind it) run as Core
/// Animation layers: macOS animates them itself, so the app does no work per frame. Drawn by SwiftUI
/// every frame they cost about 6 % CPU while the popover was open.
enum OrbAnimation {
    /// Off for the preview renderer: it copies views into a bitmap, which does not include layers.
    /// The orb then draws one still frame with SwiftUI.
    @MainActor static var live = true

    /// The sine wave of `OrbMotion.wave` as a Core Animation curve (ease in-out sine).
    static let breath = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)

    /// Frames per second: a slow breath looks the same at 20, a fast spin needs 30. Without a limit
    /// Core Animation draws at the screen's full rate (up to 120 on ProMotion screens).
    static func frames(fast: Bool) -> CAFrameRateRange {
        fast ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
             : CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
    }
}

/// One of the popover's endless animations, run by Core Animation.
struct LayerPulse: NSViewRepresentable {
    enum Content: Equatable {
        /// A blurred disk of this diameter, breathing in scale and opacity (behind the orb).
        case halo(diameter: CGFloat)
        /// The light arc on a circle of this diameter, turning.
        case arc(diameter: CGFloat)
        /// The elliptical glow behind the orb, breathing in opacity.
        case glow(width: CGFloat, height: CGFloat)
    }

    let content: Content
    let tone: Tone
    let motion: OrbMotion

    /// Room around the halo for its blur and its largest scale.
    static let haloMargin: CGFloat = 56

    /// The frame the view needs. The SwiftUI layout around it does not change: the orb places it
    /// in a ZStack with a fixed frame.
    var size: CGSize {
        switch content {
        case .halo(let d): return CGSize(width: d + Self.haloMargin * 2, height: d + Self.haloMargin * 2)
        case .arc(let d): return CGSize(width: d + 8, height: d + 8)
        case .glow(let w, let h): return CGSize(width: w, height: h)
        }
    }

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        let color = tone.fill.resolve(in: context.environment).cgColor
        view.update(content: content, color: color, motion: motion)
    }
}

final class PulseView: NSView {
    private let holder = CALayer()
    private var content: LayerPulse.Content?
    private var color: CGColor?
    private var motion: OrbMotion?
    private var haloKey: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(holder)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Same coordinates as SwiftUI (y down), so the arc starts and turns like the SwiftUI drawing.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.bounds = bounds
        holder.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for sub in holder.sublayers ?? [] { sub.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        haloKey = nil
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are removed when a layer leaves the window; start them again.
        if window != nil { rebuild() }
    }

    func update(content: LayerPulse.Content, color: CGColor, motion: OrbMotion) {
        guard content != self.content || motion != self.motion || color != self.color else { return }
        let onlyColor = content == self.content && motion == self.motion
        self.content = content
        self.color = color
        self.motion = motion
        if onlyColor, let sub = holder.sublayers, !sub.isEmpty {
            // A new state color: fade to it like the orb does.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            paint(color)
            CATransaction.commit()
        } else {
            rebuild()
        }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Builds the layers and starts their animation in step with the wall clock, so the halo and the
    /// glow breathe together (as `OrbMotion.wave` does).
    private func rebuild() {
        guard let content, let color, let motion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.sublayers?.forEach { $0.removeFromSuperlayer() }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let now = holder.convertTime(CACurrentMediaTime(), from: nil)
        let t = Date().timeIntervalSinceReferenceDate

        switch content {
        case .halo(let diameter):
            guard let period = motion.haloPeriod else { break }
            let layer = CALayer()
            let side = diameter + LayerPulse.haloMargin * 2
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = center
            layer.contentsScale = scale
            layer.contents = haloImage(diameter: diameter, color: color)
            holder.addSublayer(layer)
            layer.add(breathing("transform.scale", motion.haloScale.lowerBound, motion.haloScale.upperBound,
                                period: period, now: now, t: t), forKey: "scale")
            layer.add(breathing("opacity", motion.haloOpacity.lowerBound, motion.haloOpacity.upperBound,
                                period: period, now: now, t: t), forKey: "opacity")

        case .arc(let diameter):
            guard let period = motion.arcPeriod else { break }
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.position = center
            let path = Circle().path(in: CGRect(x: 0, y: 0, width: diameter, height: diameter)).cgPath
            for (from, to, alpha) in [(0.0, 0.146, 0.9), (0.2, 0.233, 0.35)] {
                let stroke = CAShapeLayer()
                stroke.frame = ring.bounds
                stroke.path = path
                stroke.fillColor = nil
                stroke.lineWidth = 2.5
                stroke.lineCap = .round
                stroke.strokeStart = from
                stroke.strokeEnd = to
                stroke.contentsScale = scale
                stroke.setValue(alpha, forKey: "vgAlpha")
                ring.addSublayer(stroke)
            }
            holder.addSublayer(ring)
            paint(color)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            spin.beginTime = now - t.truncatingRemainder(dividingBy: period)
            spin.isRemovedOnCompletion = false
            spin.preferredFrameRateRange = OrbAnimation.frames(fast: period < 2)
            ring.add(spin, forKey: "spin")

        case .glow(let width, let height):
            guard let period = motion.haloPeriod else { break }
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            glow.position = center
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = [0, 0.5, 1]
            holder.addSublayer(glow)
            paint(color)
            glow.add(breathing("opacity", 0.7, 1, period: period, now: now, t: t), forKey: "opacity")
        }
        CATransaction.commit()
    }

    /// Sets the state color on the layers that draw it themselves (arc strokes, glow gradient).
    private func paint(_ color: CGColor) {
        for layer in holder.sublayers ?? [] {
            if let glow = layer as? CAGradientLayer {
                glow.colors = [0.30, 0.12, 0].map { color.copy(alpha: $0) ?? color }
            }
            for case let stroke as CAShapeLayer in layer.sublayers ?? [] {
                let alpha = (stroke.value(forKey: "vgAlpha") as? Double) ?? 1
                stroke.strokeColor = color.copy(alpha: alpha)
            }
            if case .halo(let diameter) = content, !(layer is CAGradientLayer), layer.sublayers == nil {
                layer.contents = haloImage(diameter: diameter, color: color)
            }
        }
    }

    /// low -> high -> low over `period`, in phase with `OrbMotion.wave` (low at whole periods).
    private func breathing(_ keyPath: String, _ low: Double, _ high: Double, period: Double,
                           now: CFTimeInterval, t: TimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = low
        a.toValue = high
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = OrbAnimation.breath
        a.beginTime = now - t.truncatingRemainder(dividingBy: period)
        a.isRemovedOnCompletion = false
        a.preferredFrameRateRange = OrbAnimation.frames(fast: false)
        return a
    }

    /// The halo as a picture, drawn once by SwiftUI exactly like the still version (blurred disk).
    private func haloImage(diameter: CGFloat, color: CGColor) -> CGImage? {
        let key = "\(diameter) \(color.components ?? []) \(scale)"
        if key == haloKey, let image = cachedHalo { return image }
        let side = diameter + LayerPulse.haloMargin * 2
        let view = Circle()
            .fill(Color(cgColor: color))
            .frame(width: diameter, height: diameter)
            .blur(radius: 14)
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        cachedHalo = renderer.cgImage
        haloKey = key
        return cachedHalo
    }

    private var cachedHalo: CGImage?
}
