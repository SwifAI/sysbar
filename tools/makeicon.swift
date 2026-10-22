#!/usr/bin/env swift
//
// Renders a 1024×1024 SysBar app icon as a PNG.
// Output path: first CLI arg, or ./icon-1024.png
//
// Design: dark navy rounded-square, recessed dial, mint speedometer arc,
// white needle pointing to ~"high" position.
//

import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("no graphics context\n", stderr)
    exit(1)
}

let fullRect = CGRect(x: 0, y: 0, width: side, height: side)

// 1. Rounded-square background with diagonal gradient
let bgCornerRadius = side * 0.22
let bgPath = CGPath(roundedRect: fullRect, cornerWidth: bgCornerRadius, cornerHeight: bgCornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(srgbRed: 0.09, green: 0.13, blue: 0.20, alpha: 1.0),
    CGColor(srgbRed: 0.19, green: 0.25, blue: 0.36, alpha: 1.0)
] as CFArray
if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: side),
        end: CGPoint(x: side, y: 0),
        options: []
    )
}

ctx.resetClip()

// 2. Soft inner shadow at the top to give depth
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let sheenColors = [
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.00)
] as CFArray
if let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: side / 2, y: side),
        end: CGPoint(x: side / 2, y: side * 0.55),
        options: []
    )
}
ctx.restoreGState()

// 3. Recessed dial (dark inner circle)
let margin = side * 0.16
let dialRect = fullRect.insetBy(dx: margin, dy: margin)
let dialCenter = CGPoint(x: fullRect.midX, y: fullRect.midY)
let dialRadius = dialRect.width / 2

ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.07, blue: 0.11, alpha: 0.65))
ctx.fillEllipse(in: dialRect)

// 4. Track arc (dim white, wide stroke)
let trackRadius = dialRadius * 0.82
let arcStart: CGFloat = 205 * .pi / 180   // start bottom-left
let arcEnd: CGFloat   = -25 * .pi / 180   // end bottom-right (so arc sweeps across the top)

ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
ctx.setLineWidth(side * 0.055)
ctx.setLineCap(.round)
ctx.addArc(center: dialCenter, radius: trackRadius, startAngle: arcStart, endAngle: arcEnd, clockwise: true)
ctx.strokePath()

// 5. Foreground arc — mint, fills ~75% of the track
ctx.setStrokeColor(CGColor(srgbRed: 0.37, green: 0.92, blue: 0.83, alpha: 1.0))  // sbSuccess mint
ctx.setLineWidth(side * 0.055)
ctx.setLineCap(.round)
let fgEnd: CGFloat = 65 * .pi / 180
ctx.addArc(center: dialCenter, radius: trackRadius, startAngle: arcStart, endAngle: fgEnd, clockwise: true)
ctx.strokePath()

// 6. Tick marks (small, around the outer edge of the dial)
let tickOuter = dialRadius * 0.97
let tickInner = dialRadius * 0.90
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
ctx.setLineWidth(side * 0.008)
ctx.setLineCap(.round)
let tickCount = 11
for i in 0..<tickCount {
    let frac = CGFloat(i) / CGFloat(tickCount - 1)
    let angle = arcStart + frac * (arcEnd - arcStart)
    let x1 = dialCenter.x + cos(angle) * tickOuter
    let y1 = dialCenter.y + sin(angle) * tickOuter
    let x2 = dialCenter.x + cos(angle) * tickInner
    let y2 = dialCenter.y + sin(angle) * tickInner
    ctx.move(to: CGPoint(x: x1, y: y1))
    ctx.addLine(to: CGPoint(x: x2, y: y2))
}
ctx.strokePath()

// 7. Needle — pointing to ~75% (honey-tinted for contrast against mint)
let needleAngleDeg: CGFloat = 40
let needleAngle = needleAngleDeg * .pi / 180
let needleLength = dialRadius * 0.86
let needleTip = CGPoint(
    x: dialCenter.x + cos(needleAngle) * needleLength,
    y: dialCenter.y + sin(needleAngle) * needleLength
)

// Needle shadow for depth
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -side * 0.008),
    blur: side * 0.02,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
)
ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.78, blue: 0.34, alpha: 1.0))  // sbWarning honey
ctx.setLineWidth(side * 0.028)
ctx.setLineCap(.round)
ctx.move(to: dialCenter)
ctx.addLine(to: needleTip)
ctx.strokePath()
ctx.restoreGState()

// 8. Center hub — white disc with subtle ring
let hubRadius = side * 0.055
let hubRect = CGRect(
    x: dialCenter.x - hubRadius,
    y: dialCenter.y - hubRadius,
    width: hubRadius * 2,
    height: hubRadius * 2
)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1.0))
ctx.fillEllipse(in: hubRect)

// Inner hub accent
let innerHub = hubRect.insetBy(dx: hubRadius * 0.45, dy: hubRadius * 0.45)
ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.13, blue: 0.20, alpha: 1.0))
ctx.fillEllipse(in: innerHub)

image.unlockFocus()

// Save
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(png.count) bytes)")
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
