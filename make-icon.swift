#!/usr/bin/env swift
// Generates AppIcon.icns at the path passed as first argument.
// Usage: ./make-icon.swift <out.icns>

import AppKit
import Foundation

func makeIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22

    NSGraphicsContext.current?.imageInterpolation = .high

    // Background: warm gradient (amber → deeper red), Claude-ish.
    let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    bg.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.96, green: 0.55, blue: 0.20, alpha: 1.0),
        NSColor(red: 0.84, green: 0.28, blue: 0.12, alpha: 1.0)
    ])!
    gradient.draw(in: rect, angle: -90)

    // Subtle inner highlight at top to suggest depth.
    let topHL = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0)
    ])!
    topHL.draw(in: NSRect(x: 0, y: s * 0.55, width: s, height: s * 0.45), angle: -90)

    // Foreground: monospace ">_" prompt glyph in white.
    let fontSize = s * 0.46
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .black)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: para
    ]
    let text = NSAttributedString(string: ">_", attributes: attrs)
    let textSize = text.size()
    let textRect = NSRect(
        x: (s - textSize.width) / 2,
        y: (s - textSize.height) / 2 - s * 0.04,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, size: Int, to url: URL) throws {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s),
               from: .zero,
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns>\n".utf8))
    exit(1)
}
let outICNS = URL(fileURLWithPath: args[1])

let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try? FileManager.default.removeItem(at: tmpDir)
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
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

// Render once at 1024 and downscale, OR render at native each size.
// We render at 1024 once to keep stroke proportions consistent, then save scaled PNGs.
let master = makeIcon(size: 1024)
for (name, px) in sizes {
    try savePNG(master, size: px, to: tmpDir.appendingPathComponent(name))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", tmpDir.path, "-o", outICNS.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: tmpDir)
print("Wrote \(outICNS.path)")
