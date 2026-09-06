// Draws Resources/AppIcon.png, the source art for the app icon.
//
//   swiftc -O -o /tmp/iconrender scripts/make-icon-art.swift
//   /tmp/iconrender Resources/AppIcon-glyph.svg Resources/AppIcon.png
//   scripts/make-icon.sh
//
// The blue is #0050E2, sampled from the official Reolink app's own icon so the
// two sit together in the Dock. The glyph is Material Symbols
// "nest_cam_iq_outdoor" (sharp, filled), Apache 2.0, from
// https://github.com/google/material-design-icons — a wall-mounted camera, and
// nothing of Reolink's, because this is not their app.
//
// Filled, not outline: outline strokes fill in by 32pt and are unreadable at
// 16pt. Compared side by side before choosing.
import AppKit

let S: CGFloat = 1024
let brand       = NSColor(srgbRed: 0x00/255, green: 0x50/255, blue: 0xE2/255, alpha: 1)
let brandTop    = NSColor(srgbRed: 0x2E/255, green: 0x78/255, blue: 0xFF/255, alpha: 1)
let brandBottom = NSColor(srgbRed: 0x00/255, green: 0x37/255, blue: 0xB4/255, alpha: 1)

let svgPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let coverage = CGFloat(CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 0.62)

// Render the glyph alone, then measure its ink. A diagonal mark like the Nest
// camera fills far less of its square viewBox than an upright one, so scaling
// by the viewBox makes it look small and off-centre next to the others.
let probeSide = 512
let probe = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: probeSide, pixelsHigh: probeSide,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let glyph = NSImage(contentsOfFile: svgPath)!
glyph.size = NSSize(width: probeSide, height: probeSide)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: probe)
glyph.draw(in: NSRect(x: 0, y: 0, width: probeSide, height: probeSide))
NSGraphicsContext.restoreGraphicsState()

var minX = probeSide, minY = probeSide, maxX = -1, maxY = -1
for y in 0..<probeSide {
    for x in 0..<probeSide {
        if let c = probe.colorAt(x: x, y: y), c.alphaComponent > 0.06 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// colorAt uses a top-left origin; convert to the bottom-left space we draw in.
let inkW = CGFloat(maxX - minX + 1), inkH = CGFloat(maxY - minY + 1)
let inkX = CGFloat(minX), inkY = CGFloat(probeSide - 1 - maxY)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2),
                         xRadius: 185, yRadius: 185)
NSGradient(colors: [brandTop, brand, brandBottom], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    .draw(in: plate, angle: -90)

let target = (S - inset*2) * coverage
let scale = target / max(inkW, inkH)
let drawSide = CGFloat(probeSide) * scale
let originX = S/2 - (inkX + inkW/2) * scale
let originY = S/2 - (inkY + inkH/2) * scale
let box = NSRect(x: originX, y: originY, width: drawSide, height: drawSide)

ctx.beginTransparencyLayer(auxiliaryInfo: nil)
glyph.size = NSSize(width: drawSide, height: drawSide)
glyph.draw(in: box)
ctx.setBlendMode(.sourceIn)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: S, height: S).fill()
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
