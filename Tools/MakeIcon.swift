// Generates the macOS app icon as an .iconset directory.
// Run from the repo root:  swift Tools/MakeIcon.swift
//
// Produces Resources/AppIcon.iconset/ with every size the iconset format
// requires. Pair with `iconutil -c icns Resources/AppIcon.iconset` to make
// the final .icns that goes into the .app bundle.

import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Apple's iconset naming convention. Each tuple = (filename, pixel size).
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(size: CGFloat) -> Data {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { fatalError("Failed to create bitmap rep") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // 1. Squircle background with vertical gradient (Anthropic-ish coral)
    let cornerRadius = size * 0.2237
    let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let topColor = NSColor(red: 0.96, green: 0.65, blue: 0.51, alpha: 1.0).cgColor
    let bottomColor = NSColor(red: 0.72, green: 0.27, blue: 0.16, alpha: 1.0).cgColor
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    bgPath.addClip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Subtle inner highlight at the top
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.18).cgColor,
            NSColor(white: 1, alpha: 0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: size * 0.55),
        options: []
    )
    ctx.restoreGState()

    // 2. Battery body (white stroked rounded rect)
    let batWidth = size * 0.58
    let batHeight = size * 0.34
    let batX = (size - batWidth) / 2 - size * 0.015
    let batY = (size - batHeight) / 2
    let batRect = NSRect(x: batX, y: batY, width: batWidth, height: batHeight)
    let batRadius = size * 0.045
    let batPath = NSBezierPath(roundedRect: batRect, xRadius: batRadius, yRadius: batRadius)
    let strokeWidth = size * 0.028
    batPath.lineWidth = strokeWidth
    NSColor.white.setStroke()
    batPath.stroke()

    // Battery terminal nub
    let nubWidth = size * 0.028
    let nubHeight = batHeight * 0.45
    let nubX = batX + batWidth + size * 0.008
    let nubY = batY + (batHeight - nubHeight) / 2
    let nubRect = NSRect(x: nubX, y: nubY, width: nubWidth, height: nubHeight)
    let nubRadius = nubWidth / 2.5
    let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: nubRadius, yRadius: nubRadius)
    NSColor.white.setFill()
    nubPath.fill()

    // 3. Lightning bolt cutting through the battery
    // Coordinates expressed as fractions of icon size, then scaled.
    let cx = size * 0.49
    let cy = size * 0.50
    let bw = size * 0.13
    let bh = size * 0.30
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: cx + bw * 0.15, y: cy + bh * 0.95))
    bolt.line(to: NSPoint(x: cx - bw * 0.85, y: cy - bh * 0.05))
    bolt.line(to: NSPoint(x: cx - bw * 0.05, y: cy - bh * 0.05))
    bolt.line(to: NSPoint(x: cx - bw * 0.25, y: cy - bh * 0.95))
    bolt.line(to: NSPoint(x: cx + bw * 0.85, y: cy + bh * 0.05))
    bolt.line(to: NSPoint(x: cx + bw * 0.05, y: cy + bh * 0.05))
    bolt.close()

    // Glow underneath the bolt for extra punch
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: size * 0.04,
        color: NSColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 0.7).cgColor
    )
    NSColor(red: 1.0, green: 0.93, blue: 0.45, alpha: 1.0).setFill()
    bolt.fill()
    ctx.restoreGState()

    // Crisp white outline on top
    NSColor(white: 1, alpha: 0.85).setStroke()
    bolt.lineWidth = size * 0.012
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return png
}

for (filename, pixelSize) in variants {
    let data = renderIcon(size: pixelSize)
    let url = outDir.appendingPathComponent(filename)
    try data.write(to: url)
    print("wrote \(filename) (\(Int(pixelSize))px)")
}

print("\niconset ready at \(outDir.path)")
print("next:  iconutil -c icns \(outDir.path) -o Resources/AppIcon.icns")
