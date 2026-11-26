// Draws the app icon as a 1024 px PNG: graphite tile, emerald shield, white lock.
// Same geometry as the design canvas (24-unit shield, scaled ×28 at (176, 180)).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import SwiftUI

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func shieldPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 12, y: 2.75))
    p.addLine(to: CGPoint(x: 5, y: 5.5))
    p.addLine(to: CGPoint(x: 5, y: 11))
    p.addCurve(to: CGPoint(x: 12, y: 21.25), control1: CGPoint(x: 5, y: 15.6), control2: CGPoint(x: 8, y: 19.4))
    p.addCurve(to: CGPoint(x: 19, y: 11), control1: CGPoint(x: 16, y: 19.4), control2: CGPoint(x: 19, y: 15.6))
    p.addLine(to: CGPoint(x: 19, y: 5.5))
    p.closeSubpath()
    return p
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
// y-down, like the SVG
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Tile: macOS icon grid (824 px body), continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body).cgPath

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(tile)
ctx.setFillColor(color(0x0C0E12))
ctx.fillPath()
ctx.restoreGState()

func verticalGradient(_ path: CGPath, _ stops: [(CGFloat, CGColor)], from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}

verticalGradient(tile, [(0, color(0x30353F)), (1, color(0x0C0E12))], from: 100, to: 924)
verticalGradient(tile, [(0, color(0xFFFFFF, 0.10)), (0.5, color(0xFFFFFF, 0))], from: 100, to: 924)
ctx.saveGState()
ctx.addPath(RoundedRectangle(cornerRadius: 183.5, style: .continuous).path(in: body.insetBy(dx: 1.5, dy: 1.5)).cgPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.09))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Shield, in 24-unit space.
var shieldTransform = CGAffineTransform(translationX: 176, y: 180).scaledBy(x: 28, y: 28)
let shield = shieldPath().copy(using: &shieldTransform)!

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 52, color: color(0x000000, 0.5))
ctx.addPath(shield)
ctx.setFillColor(color(0x0E9F4F))
ctx.fillPath()
ctx.restoreGState()

let shieldBox = shield.boundingBox
verticalGradient(shield, [(0, color(0x63F2A3)), (1, color(0x0E9F4F))], from: shieldBox.minY, to: shieldBox.maxY)
ctx.saveGState()
ctx.addPath(shield)
ctx.setStrokeColor(color(0xFFFFFF, 0.35))
ctx.setLineWidth(0.22 * 28)
ctx.strokePath()
ctx.restoreGState()

// Lock.
ctx.saveGState()
ctx.translateBy(x: 176, y: 180)
ctx.scaleBy(x: 28, y: 28)
ctx.setFillColor(color(0xFFFFFF))
ctx.addPath(CGPath(roundedRect: CGRect(x: 9.15, y: 11, width: 5.7, height: 4.7), cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
ctx.fillPath()
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: 10.3, y: 11))
shackle.addLine(to: CGPoint(x: 10.3, y: 9.65))
shackle.addRelativeArc(center: CGPoint(x: 12, y: 9.65), radius: 1.7, startAngle: .pi, delta: .pi)
shackle.addLine(to: CGPoint(x: 13.7, y: 11))
ctx.addPath(shackle)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(1.25)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.setFillColor(color(0x0E8F47))
ctx.fillEllipse(in: CGRect(x: 12 - 0.55, y: 12.95 - 0.55, width: 1.1, height: 1.1))
ctx.addPath(CGPath(roundedRect: CGRect(x: 11.75, y: 13.1, width: 0.5, height: 1.3), cornerWidth: 0.25, cornerHeight: 0.25, transform: nil))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
