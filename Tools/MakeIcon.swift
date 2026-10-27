// Generates Page's macOS app icon: the pulse orb with its rings, on a
// macOS-grid plate. Run from the repo root:  swift Tools/MakeIcon.swift
//
// Writes:
//   Resources/AppIcon-master-1024.png   the 1024 px master
//   Resources/AppIcon.iconset/          every size the iconset format needs
//   .build/AppIcon.xcassets/            the same PNGs as a macOS asset catalog
//
// build.sh, when this file is newer than Resources/AppIcon.icns, runs it, then
// `iconutil` (iconset -> AppIcon.icns) and, when full Xcode is there, `actool`
// (asset catalog -> Resources/Assets.car). Both outputs are committed.
//
// Why both: macOS 26 draws an .icns-only icon shrunk onto a grey backing
// plate at small sizes (the widget gallery, Finder list view, Spotlight);
// an icon from an asset catalog (CFBundleIconName) is drawn as is. The .icns
// stays as the CFBundleIconFile fallback for older systems.
//
// macOS icons carry their own shape, unlike iOS, where the system masks a
// full-bleed square. Big Sur grid on a 1024 canvas: an 824 x 824
// continuous-corner plate (corner radius 185.4) centred with 100 pt margins,
// and a soft drop shadow kept inside the canvas. The iOS icon
// (iOS/Page/Assets.xcassets) stays full-bleed and is not made here.
//
// Small sizes get their own art: at 16 px the rings turn to mush, so only the
// orb is drawn; at 32 px one heavier ring; at 64 px both rings, heavier.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = root.appendingPathComponent("Resources/AppIcon.iconset")
let masterURL = root.appendingPathComponent("Resources/AppIcon-master-1024.png")

// MARK: palette (Night Watch, Sources/ClaudePowerMode/UI/Theme.swift)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let teal = 0x5EEAD4 as UInt32      // NightWatch.Palette.teal
let sky = 0x38BDF8 as UInt32       // NightWatch.Palette.sky
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// MARK: geometry (all in 1024-unit canvas space, y up)

let canvas: CGFloat = 1024
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 185.4
let centre = CGPoint(x: 512, y: 512)

/// Apple's continuous-corner rounded rect (the same curve SwiftUI and the
/// system use for app icons), not a circular-arc rounded rect.
func platePath(inset: CGFloat = 0) -> CGPath {
    let r = plateRect.insetBy(dx: inset, dy: inset)
    return RoundedRectangle(cornerRadius: plateRadius - inset, style: .continuous).path(in: r).cgPath
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

// MARK: level of detail

struct Detail {
    var orbRadius: CGFloat
    /// (radius, stroke width, colour, alpha) for each ring, inner first.
    var rings: [(CGFloat, CGFloat, UInt32, CGFloat)]
    var halo: Bool
    var shadow: Bool
    var rim: Bool

    /// Widths are in canvas units; at small sizes they are set so a ring is
    /// at least ~1.3 px wide and lands as a clean line rather than a smear.
    static func forPixels(_ px: Int) -> Detail {
        switch px {
        case ...16:
            return Detail(orbRadius: 232, rings: [], halo: true, shadow: false, rim: false)
        case ...32:
            return Detail(orbRadius: 200, rings: [(318, 46, teal, 0.80)],
                          halo: true, shadow: true, rim: false)
        case ...64:
            return Detail(orbRadius: 190, rings: [(266, 24, sky, 0.85), (336, 22, teal, 0.66)],
                          halo: true, shadow: true, rim: true)
        default:
            return Detail(orbRadius: 180, rings: [(254, 13, sky, 0.85), (322, 11, teal, 0.62)],
                          halo: true, shadow: true, rim: true)
        }
    }
}

// MARK: drawing

func draw(in ctx: CGContext, detail d: Detail) {
    let plate = platePath()

    // 1. Drop shadow, inside the canvas (Big Sur template: y 10 down, blur ~20).
    if d.shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, 0.32))
        ctx.addPath(plate)
        ctx.setFillColor(rgb(0x05070D))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    // 2. Plate: Night Watch ink, lit from the top.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x1B2A35)), (0.45, rgb(0x0D151D)), (1, rgb(0x05070D))]),
        start: CGPoint(x: 0, y: plateRect.maxY), end: CGPoint(x: 0, y: plateRect.minY), options: [])

    // 3. Aurora: a teal bloom behind the orb, pooling slightly upward.
    if d.halo {
        ctx.drawRadialGradient(
            gradient([(0, rgb(teal, 0.30)), (0.45, rgb(0x1BA8B8, 0.12)), (1, rgb(0x0B1B24, 0))]),
            startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
            endCenter: CGPoint(x: 512, y: 530), endRadius: 430, options: [])
    }

    // 4. Rings: the pulse, brighter at the top where the plate is lit.
    for (radius, width, hex, alpha) in d.rings {
        ctx.saveGState()
        ctx.addEllipse(in: circle(centre, radius))
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(hex, alpha)), (1, rgb(hex, alpha * 0.55))]),
            start: CGPoint(x: 0, y: centre.y + radius), end: CGPoint(x: 0, y: centre.y - radius),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // 5. Orb glow: a clean cyan falloff around the orb.
    let orb = circle(centre, d.orbRadius)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x4FE3E0, 0.55)), (0.35, rgb(sky, 0.20)), (1, rgb(sky, 0))]),
        startCenter: centre, startRadius: d.orbRadius * 0.95,
        endCenter: centre, endRadius: d.orbRadius * 1.6, options: [])

    // 6. Orb body: mint at the lit top-left, teal, then sky at the rim.
    ctx.saveGState()
    ctx.addEllipse(in: orb)
    ctx.clip()
    let lit = CGPoint(x: centre.x - d.orbRadius * 0.30, y: centre.y + d.orbRadius * 0.34)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xE8FFFA)), (0.28, rgb(0x9AF2E4)), (0.62, rgb(0x4FD3EA)), (1, rgb(0x1E9BE0))]),
        startCenter: lit, startRadius: 0, endCenter: centre, endRadius: d.orbRadius, options: [.drawsAfterEndLocation])
    // Bottom bounce light, so the orb reads as glass rather than a flat disc.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xB8FFF4, 0.24)), (1, rgb(0xB8FFF4, 0))]),
        startCenter: CGPoint(x: centre.x + d.orbRadius * 0.12, y: centre.y - d.orbRadius * 1.05), startRadius: 0,
        endCenter: CGPoint(x: centre.x + d.orbRadius * 0.12, y: centre.y - d.orbRadius * 1.05),
        endRadius: d.orbRadius * 0.7, options: [])
    ctx.restoreGState()

    // 7. Specular highlight: a soft oval up and to the left.
    let hi = CGPoint(x: centre.x - d.orbRadius * 0.36, y: centre.y + d.orbRadius * 0.44)
    ctx.saveGState()
    ctx.translateBy(x: hi.x, y: hi.y)
    ctx.rotate(by: .pi / 5)
    ctx.scaleBy(x: 1, y: 0.68)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.85)), (0.5, rgb(0xFFFFFF, 0.35)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: d.orbRadius * 0.42, options: [])
    ctx.restoreGState()

    // 8. Top sheen across the plate.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.07)), (1, rgb(0xFFFFFF, 0))]),
        start: CGPoint(x: 0, y: plateRect.maxY), end: CGPoint(x: 0, y: plateRect.midY + 60), options: [])

    // 9. Hairline rim: light along the top edge, a faint glass glow along the bottom.
    if d.rim {
        ctx.saveGState()
        ctx.addPath(plate)
        ctx.setLineWidth(5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, 0.22)), (0.5, rgb(0xFFFFFF, 0.05)), (1, rgb(0x5FD0C8, 0.16))]),
            start: CGPoint(x: 0, y: plateRect.maxY), end: CGPoint(x: 0, y: plateRect.minY), options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    ) else { fatalError("Failed to create bitmap rep") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: ctx, detail: .forPixels(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let srgb = rep.retagging(with: .sRGB),
          let png = srgb.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    return png
}

// MARK: output

// Apple's iconset naming. Each entry = (filename, pixel size).
let variants: [(String, Int)] = [
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

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

var rendered: [Int: Data] = [:]
for (filename, px) in variants {
    let data = rendered[px] ?? render(pixels: px)
    rendered[px] = data
    try data.write(to: iconsetDir.appendingPathComponent(filename))
    print("wrote \(filename) (\(px)px)")
}
try rendered[1024]!.write(to: masterURL)
print("wrote \(masterURL.lastPathComponent)")

// Asset catalog for actool: the same files, described by a Contents.json.
let catalogDir = root.appendingPathComponent(".build/AppIcon.xcassets")
let appIconSet = catalogDir.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: catalogDir)
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (filename, px) in variants {
    try rendered[px]!.write(to: appIconSet.appendingPathComponent(filename))
    let points = filename.dropFirst("icon_".count).prefix { $0 != "x" }
    images.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)",
                   "scale": filename.contains("@2x") ? "2x" : "1x"])
}
let info = ["author": "xcode", "version": 1] as [String: Any]
func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
try writeJSON(["info": info], to: catalogDir.appendingPathComponent("Contents.json"))
try writeJSON(["images": images, "info": info], to: appIconSet.appendingPathComponent("Contents.json"))
print("wrote \(catalogDir.path)")

print("\niconset ready at \(iconsetDir.path)")
print("next:  iconutil -c icns \(iconsetDir.path) -o Resources/AppIcon.icns")
