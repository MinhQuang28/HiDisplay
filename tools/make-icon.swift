#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
//
// Drawn in code rather than committed as a binary so the icon can be tweaked in a diff, and so the
// repository carries no opaque asset whose provenance has to be explained in the source audit.
//
//   swift tools/make-icon.swift
import AppKit

/// A rounded-rect "display" glyph with a brightness gradient across it, which is what the app does.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = size / 1024

    // Squircle background, roughly matching macOS icon geometry.
    let inset = 96 * scale
    let bounds = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let background = NSBezierPath(roundedRect: bounds, xRadius: 180 * scale, yRadius: 180 * scale)
    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
            NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
        ])?
        .draw(in: background, angle: -90)

    // Screen: the brightness ramp, left dark to right bright.
    let screenInset = 220 * scale
    let screen = NSRect(
        x: screenInset, y: screenInset + 60 * scale,
        width: size - screenInset * 2, height: size - screenInset * 2 - 120 * scale)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 40 * scale, yRadius: 40 * scale)
    NSGradient(
        colors: [
            NSColor(calibratedWhite: 0.18, alpha: 1),
            NSColor(calibratedWhite: 1.0, alpha: 1),
        ])?
        .draw(in: screenPath, angle: 0)

    // Stand.
    let standWidth = 200 * scale
    let stand = NSRect(
        x: (size - standWidth) / 2, y: screenInset + 10 * scale,
        width: standWidth, height: 56 * scale)
    NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
    NSBezierPath(roundedRect: stand, xRadius: 20 * scale, yRadius: 20 * scale).fill()

    return image
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes `iconutil` expects, each as both 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scaleFactor in [1, 2] {
        let pixels = CGFloat(base * scaleFactor)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let name = scaleFactor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0
    ? "wrote Resources/AppIcon.icns"
    : "iconutil failed with status \(convert.terminationStatus)")
