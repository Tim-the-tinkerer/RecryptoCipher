#!/usr/bin/env swift
import AppKit
import Foundation

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.saveGraphicsState()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let inset = rect.insetBy(dx: size * 0.07, dy: size * 0.07)
    let radius = size * 0.22
    let bg = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
    bg.addClip()
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1).setFill()
    inset.fill()

    let card = inset.insetBy(dx: size * 0.08, dy: size * 0.10)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: size * 0.06, yRadius: size * 0.06)
    NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.88, alpha: 1).setFill()
    cardPath.fill()

    let spine = NSRect(x: card.minX, y: card.minY, width: max(2, size * 0.045), height: card.height)
    NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.22, alpha: 1).setFill()
    spine.fill()

    if size >= 48 {
        let text = "R/1" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: size * 0.18, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        ]
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: card.midX - textSize.width / 2 + size * 0.02,
            y: card.midY - textSize.height / 2 + size * 0.04,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)

        if size >= 96 {
            let slots = ["1", "2", "3", "4"]
            let slotFont = NSFont.monospacedSystemFont(ofSize: size * 0.07, weight: .bold)
            let gap = size * 0.09
            let total = gap * CGFloat(slots.count - 1)
            var x = card.midX - total / 2 + size * 0.02
            let y = card.minY + size * 0.08
            for slot in slots {
                let slotAttrs: [NSAttributedString.Key: Any] = [
                    .font: slotFont,
                    .foregroundColor: NSColor(calibratedRed: 0.40, green: 0.42, blue: 0.48, alpha: 1),
                ]
                (slot as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: slotAttrs)
                x += gap
            }
        }
    }

    NSGraphicsContext.current?.restoreGraphicsState()

    let border = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.22, alpha: 1).setStroke()
    border.lineWidth = max(1, size * 0.025)
    border.stroke()

    image.unlockFocus()
    return image
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for item in sizes {
    let img = drawIcon(size: item.px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("Failed to render \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(item.name).png"))
    print("Wrote \(item.name).png")
}

let master = drawIcon(size: 1024)
if let tiff = master.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Created \(icns.path)")
