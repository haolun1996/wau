// Draws the Wau app icon (a wau bulan kite against a dusk sky) as a 1024×1024 PNG.
//
//   swift tools/make-icon.swift <output.png>
//
// tools/make-icon.sh turns that PNG into every size the asset catalog needs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "icon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linearGradient(ctx, colors, from: from, to: to)
    ctx.restoreGState()
}

/// Strokes only the inside half of the outline, as a decorative border.
func innerStroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width * 2)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Work in top-left coordinates, like a design tool.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: Tile — the standard macOS icon grid: 824pt rounded square, 100pt margin.

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x000000, 0.35))
ctx.addPath(tile)
ctx.setFillColor(rgb(0x1B2A5C))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
// Dusk sky: deep indigo above, warm teal at the horizon.
linearGradient(ctx, [rgb(0x172452), rgb(0x2B4C86), rgb(0x3E8C9C)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// Soft moonlight glow behind the kite.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFD98A, 0.45), rgb(0xFFD98A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 400, options: [])
// The kite string, running off to the lower left.
ctx.setStrokeColor(rgb(0xFFF3D6, 0.55))
ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: 520, y: 560))
ctx.addCurve(to: CGPoint(x: 60, y: 1010), control1: CGPoint(x: 420, y: 860), control2: CGPoint(x: 240, y: 900))
ctx.strokePath()
ctx.restoreGState()

// MARK: Kite — tilted slightly, as if caught by the wind.

ctx.saveGState()
ctx.translateBy(x: 512, y: 500)
ctx.rotate(by: -7 * .pi / 180)
ctx.translateBy(x: -512, y: -500)

// Busur: the bow arched over the head that makes a wau hum in the wind.
ctx.setStrokeColor(rgb(0xF6C453))
ctx.setLineCap(.round)
ctx.setLineWidth(10)
ctx.move(to: CGPoint(x: 372, y: 262))
ctx.addQuadCurve(to: CGPoint(x: 652, y: 262), control: CGPoint(x: 512, y: 120))
ctx.strokePath()

// Kepala: the small pointed head.
let head = CGMutablePath()
head.move(to: CGPoint(x: 512, y: 196))
head.addCurve(to: CGPoint(x: 540, y: 262), control1: CGPoint(x: 530, y: 214), control2: CGPoint(x: 540, y: 236))
head.addLine(to: CGPoint(x: 484, y: 262))
head.addCurve(to: CGPoint(x: 512, y: 196), control1: CGPoint(x: 484, y: 236), control2: CGPoint(x: 494, y: 214))
head.closeSubpath()

// Sayap: broad wings tapering to tips that lift outward.
let wings = CGMutablePath()
wings.move(to: CGPoint(x: 512, y: 252))
wings.addCurve(to: CGPoint(x: 830, y: 318), control1: CGPoint(x: 630, y: 250), control2: CGPoint(x: 760, y: 270))
wings.addCurve(to: CGPoint(x: 532, y: 470), control1: CGPoint(x: 770, y: 364), control2: CGPoint(x: 640, y: 436))
wings.addLine(to: CGPoint(x: 492, y: 470))
wings.addCurve(to: CGPoint(x: 194, y: 318), control1: CGPoint(x: 384, y: 436), control2: CGPoint(x: 254, y: 364))
wings.addCurve(to: CGPoint(x: 512, y: 252), control1: CGPoint(x: 264, y: 270), control2: CGPoint(x: 394, y: 250))
wings.closeSubpath()

// Pinggang: the narrow waist joining wings and tail.
let waist = CGMutablePath()
waist.move(to: CGPoint(x: 528, y: 470))
waist.addLine(to: CGPoint(x: 522, y: 608))
waist.addLine(to: CGPoint(x: 502, y: 608))
waist.addLine(to: CGPoint(x: 496, y: 470))
waist.closeSubpath()

// Ekor bulan: the crescent-moon tail that gives the wau bulan its name.
let crescent = CGMutablePath()
crescent.move(to: CGPoint(x: 270, y: 480))
crescent.addCurve(to: CGPoint(x: 512, y: 724), control1: CGPoint(x: 290, y: 642), control2: CGPoint(x: 404, y: 724))
crescent.addCurve(to: CGPoint(x: 754, y: 480), control1: CGPoint(x: 620, y: 724), control2: CGPoint(x: 734, y: 642))
crescent.addCurve(to: CGPoint(x: 512, y: 602), control1: CGPoint(x: 700, y: 570), control2: CGPoint(x: 604, y: 602))
crescent.addCurve(to: CGPoint(x: 270, y: 480), control1: CGPoint(x: 420, y: 602), control2: CGPoint(x: 324, y: 570))
crescent.closeSubpath()

ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x0A0F2A, 0.5))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setShadow(offset: .zero, blur: 0, color: nil)

fill(ctx, waist, [rgb(0xB5172F), rgb(0x8E1024)], from: CGPoint(x: 512, y: 470), to: CGPoint(x: 512, y: 608))
fill(ctx, head, [rgb(0xF0475A), rgb(0xC81D36)], from: CGPoint(x: 512, y: 196), to: CGPoint(x: 512, y: 262))
fill(ctx, wings, [rgb(0xF0475A), rgb(0xC81D36)], from: CGPoint(x: 512, y: 252), to: CGPoint(x: 512, y: 470))
fill(ctx, crescent, [rgb(0xF9D06B), rgb(0xE39A2D)], from: CGPoint(x: 512, y: 480), to: CGPoint(x: 512, y: 724))
innerStroke(ctx, wings, rgb(0xFFE7A8), width: 11)
innerStroke(ctx, head, rgb(0xFFE7A8), width: 6)
innerStroke(ctx, crescent, rgb(0xFFF3D6), width: 9)

// Motif: a four-petal bunga (flower) at the heart of the wings, like the
// hand-cut floral patterns layered on a real wau.
ctx.saveGState()
ctx.setFillColor(rgb(0xF9D06B))
let heart = CGPoint(x: 512, y: 340)
for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
    ctx.saveGState()
    ctx.translateBy(x: heart.x, y: heart.y)
    ctx.rotate(by: angle * .pi / 180)
    ctx.fillEllipse(in: CGRect(x: -14, y: -52, width: 28, height: 48))
    ctx.restoreGState()
}
ctx.setFillColor(rgb(0xB5172F))
ctx.fillEllipse(in: CGRect(x: heart.x - 12, y: heart.y - 12, width: 24, height: 24))
ctx.restoreGState()

// Tulang: the bamboo spine running from head to tail.
ctx.setStrokeColor(rgb(0x5A0F1A, 0.85))
ctx.setLineWidth(7)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 512, y: 206))
ctx.addLine(to: CGPoint(x: 512, y: 712))
ctx.strokePath()

ctx.endTransparencyLayer()
ctx.restoreGState()

// MARK: Write PNG

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outputPath)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("could not write \(outputPath)")
}
print("wrote \(outputPath)")
