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

/// Heartbeat that turns into a rising curve: data becoming progress.
func strokePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 150, y: 600))
    p.addLine(to: CGPoint(x: 330, y: 600))
    p.addLine(to: CGPoint(x: 405, y: 470))
    p.addLine(to: CGPoint(x: 495, y: 745))
    p.addLine(to: CGPoint(x: 580, y: 440))
    p.addCurve(to: CGPoint(x: 850, y: 290), control1: CGPoint(x: 640, y: 330), control2: CGPoint(x: 740, y: 290))
    return p
}
let end = CGPoint(x: 850, y: 290)
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

    let orange = color(0xFF8A3D), pink = color(0xFF2D55)
    switch variant {
    case .light:
        let bg = CGGradient(colorsSpace: space, colors: [orange, pink] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: size, y: size), options: [])
        let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 230, y: 180), startRadius: 0, endCenter: CGPoint(x: 230, y: 180), endRadius: 700, options: [])
    case .dark:
        let bg = CGGradient(colorsSpace: space, colors: [color(0x2C2C30), color(0x111113)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: size, y: size), options: [])
    case .tinted:
        ctx.setFillColor(color(0x000000))
        ctx.fill(full)
    }

    // Soft shadow under the mark on the colored variant.
    if variant == .light {
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x8A0F2A, 0.35))
    }
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    let dot = CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

    switch variant {
    case .light, .tinted:
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(strokePath()); ctx.strokePath()
        ctx.fillEllipse(in: dot)
        ctx.endTransparencyLayer()
    case .dark:
        // Fill the stroked outline + dot with the brand gradient.
        let outline = strokePath().copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(outline.union(CGPath(ellipseIn: dot, transform: nil)))
        ctx.clip()
        let fg = CGGradient(colorsSpace: space, colors: [orange, pink] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fg, start: CGPoint(x: 150, y: 700), end: CGPoint(x: 900, y: 250), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments[1]
render(.light, to: "\(out)/AppIcon.png")
render(.dark, to: "\(out)/AppIcon-Dark.png")
render(.tinted, to: "\(out)/AppIcon-Tinted.png")
print("ok")
