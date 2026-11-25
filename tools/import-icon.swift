// Fits generated icon art (a rounded tile on a plain light background, as
// image generators produce) onto the standard macOS icon grid:
// finds the tile, crops it, and redraws it as an 824pt rounded square with a
// 100pt transparent margin and a soft shadow, on a 1024×1024 canvas.
//
//   swift tools/import-icon.swift <input.png> <output.png>
//
// tools/make-icon.sh <input.png> runs this and installs every size.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: import-icon.swift <input.png> <output.png>\n".utf8))
    exit(2)
}
let inputPath = arguments[arguments.startIndex]
let outputPath = arguments[arguments.startIndex + 1]

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("could not read \(inputPath)") }

// Render into a known RGBA layout to inspect pixels.
let width = art.width
let height = art.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(art, in: CGRect(x: 0, y: 0, width: width, height: height))
}

/// The tile is every pixel that is clearly not the light background.
func isBackground(x: Int, y: Int) -> Bool {
    let i = (y * width + x) * 4
    let alpha = pixels[i + 3]
    return alpha < 16 || (pixels[i] > 225 && pixels[i + 1] > 225 && pixels[i + 2] > 225)
}

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where !isBackground(x: x, y: y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fatalError("no tile found in \(inputPath)") }

// Trim a little so soft tile edges and leftover background don't show.
let trim = Int(Double(maxX - minX) * 0.012)
// Pixel rows above were scanned top-down in a bottom-up context, so flip y.
let crop = CGRect(
    x: minX + trim,
    y: height - 1 - maxY + trim,
    width: maxX - minX + 1 - 2 * trim,
    height: maxY - minY + 1 - 2 * trim
)
guard let tileArt = art.cropping(to: crop) else { fatalError("crop failed") }
print("tile found at \(crop.integral) in \(width)×\(height) source")

// Draw onto the macOS icon grid.
let canvas: CGFloat = 1024
let context = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
context.addPath(tile)
context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 1))
context.fillPath()
context.restoreGState()

context.addPath(tile)
context.clip()
context.interpolationQuality = .high
context.draw(tileArt, in: tileRect)

let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(outputPath)") }
print("wrote \(outputPath)")
