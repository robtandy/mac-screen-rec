// Renders the app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift IconGen.swift <output.png>
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift IconGen.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])

let size = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}

let s = CGFloat(size)

// Rounded-square background with a subtle vertical gradient.
let radius = s * 0.2245
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let gradientColors = [
    CGColor(srgbRed: 0.24, green: 0.24, blue: 0.28, alpha: 1),
    CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: sRGB, colors: gradientColors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: s),
                       end: CGPoint(x: 0, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Dashed "region" rectangle.
let region = CGRect(x: s * 0.20, y: s * 0.20, width: s * 0.60, height: s * 0.60)
ctx.addPath(CGPath(rect: region, transform: nil))
ctx.setLineWidth(s * 0.018)
ctx.setLineDash(phase: 0, lengths: [s * 0.07, s * 0.045])
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
ctx.strokePath()

// Recording dot.
let dotRadius = s * 0.115
ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1))
ctx.fillEllipse(in: CGRect(x: s / 2 - dotRadius, y: s / 2 - dotRadius,
                           width: dotRadius * 2, height: dotRadius * 2))

// System-audio bars under the dot.
let barHeights: [CGFloat] = [s * 0.035, s * 0.07, s * 0.045, s * 0.055]
let barWidth = s * 0.022
let gap = s * 0.016
let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
var x = s / 2 - totalWidth / 2
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82))
for h in barHeights {
    ctx.fill(CGRect(x: x, y: s * 0.28, width: barWidth, height: h))
    x += barWidth + gap
}

ctx.restoreGState()

let image = ctx.makeImage()!
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
