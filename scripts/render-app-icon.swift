// Renders the Stride app icon (light, dark, tinted) at 1024x1024.
// Usage: xcrun swift scripts/render-app-icon.swift Stride/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Where the curve ends, marked with a dot.
let end = CGPoint(x: 850, y: 290)

/// Heartbeat that turns into a rising curve: data becoming progress.
func strokePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 150, y: 600))
    p.addLine(to: CGPoint(x: 330, y: 600))
    p.addLine(to: CGPoint(x: 405, y: 470))
    p.addLine(to: CGPoint(x: 495, y: 745))
    p.addLine(to: CGPoint(x: 580, y: 440))
    p.addCurve(to: end, control1: CGPoint(x: 640, y: 330), control2: CGPoint(x: 740, y: 290))
    return p
}
let lineWidth: CGFloat = 70
let dotRadius: CGFloat = 62

enum Variant { case light, dark, tinted }

func render(_ variant: Variant, to path: String) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in top-left coordinates.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    let full = CGRect(x: 0, y: 0, width: size, height: size)

    // Flat colors only: one solid background, one solid mark.
    let brand = color(0xFF4438)
    switch variant {
    case .light: ctx.setFillColor(brand)
    case .dark: ctx.setFillColor(color(0x161618))
    case .tinted: ctx.setFillColor(color(0x000000))
    }
    ctx.fill(full)

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    let dot = CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
    let mark = variant == .dark ? brand : color(0xFFFFFF)
    ctx.setStrokeColor(mark)
    ctx.setFillColor(mark)
    ctx.addPath(strokePath()); ctx.strokePath()
    ctx.fillEllipse(in: dot)

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Couldn't write \(path)") }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: render-app-icon.swift <AppIcon.appiconset>")
    exit(1)
}
let out = CommandLine.arguments[1]
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: out, isDirectory: &isDirectory), isDirectory.boolValue else {
    print("not a directory: \(out)")
    exit(1)
}
render(.light, to: "\(out)/AppIcon.png")
render(.dark, to: "\(out)/AppIcon-Dark.png")
render(.tinted, to: "\(out)/AppIcon-Tinted.png")
print("ok")
