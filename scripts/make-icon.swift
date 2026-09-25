// Renders the application icon as a 1024x1024 PNG.
//
//   swift scripts/make-icon.swift <output.png>
//
// Design constraints, deliberately chosen:
//
//   * No text. The previous icon carried a "7z" wordmark, which is a
//     third-party mark and made the icon resemble the 7-Zip logo.
//   * No resemblance to any existing product's icon. The mark here is a plain
//     arrow descending into an open box — a generic "extract" metaphor.
//   * Its own palette (violet/indigo), not the blue associated with 7-Zip.
//
// Written as a script rather than shipping a binary blob so the icon is
// reproducible and reviewable from the repository.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <输出.png>\n".utf8))
    exit(2)
}
let outputPath = arguments[1]
let side = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("无法创建位图上下文\n".utf8))
    exit(1)
}
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}
NSGraphicsContext.current = context
let cg = context.cgContext

let full = CGRect(x: 0, y: 0, width: side, height: side)
let plate = full.insetBy(dx: 56, dy: 56)
let squircle = CGPath(roundedRect: plate, cornerWidth: 208, cornerHeight: 208, transform: nil)

// 1. Rounded plate with a violet/indigo gradient.
cg.saveGState()
cg.addPath(squircle)
cg.clip()
let plateColors = [
    NSColor(srgbRed: 0.56, green: 0.44, blue: 0.96, alpha: 1).cgColor,
    NSColor(srgbRed: 0.29, green: 0.19, blue: 0.74, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: plateColors,
    locations: [0, 1]
) {
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.minY),
        options: []
    )
}
cg.restoreGState()

// 2. Soft top highlight.
cg.saveGState()
cg.addPath(squircle)
cg.clip()
cg.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
cg.setLineWidth(6)
cg.addPath(CGPath(roundedRect: plate.insetBy(dx: 10, dy: 10),
                  cornerWidth: 198, cornerHeight: 198, transform: nil))
cg.strokePath()
cg.restoreGState()

cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 34,
             color: NSColor.black.withAlphaComponent(0.26).cgColor)

// 3. Open tray, drawn as a stroked U so the top stays genuinely open.
//    (An even-odd cut was tried first; the arrow then merged with the box's top
//    edge into a plus sign, which read as neither an arrow nor a box.)
let tray = CGMutablePath()
tray.move(to: CGPoint(x: 250, y: 300))
tray.addLine(to: CGPoint(x: 250, y: 170))
tray.addLine(to: CGPoint(x: 774, y: 170))
tray.addLine(to: CGPoint(x: 774, y: 300))

cg.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
cg.setLineWidth(96)
cg.setLineCap(.round)
cg.setLineJoin(.round)
cg.addPath(tray)
cg.strokePath()

// 4. Arrow descending toward the tray, with a clear gap so the two shapes stay
//    legible on their own.
let shaft = CGRect(x: 452, y: 590, width: 120, height: 290)
let arrow = CGMutablePath()
arrow.addPath(CGPath(roundedRect: shaft, cornerWidth: 60, cornerHeight: 60, transform: nil))
arrow.move(to: CGPoint(x: 362, y: 600))
arrow.addLine(to: CGPoint(x: 662, y: 600))
arrow.addLine(to: CGPoint(x: 512, y: 420))
arrow.closeSubpath()

cg.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
cg.addPath(arrow)
cg.fillPath()

cg.setShadow(offset: .zero, blur: 0, color: nil)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("已生成图标：\(outputPath) (\(png.count) 字节)")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(1)
}
