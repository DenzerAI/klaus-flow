#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count >= 4 else {
    print("Usage: render-svg.swift input.svg output.png size")
    exit(1)
}
let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
guard let size = Int(CommandLine.arguments[3]) else { exit(1) }

guard let image = NSImage(contentsOfFile: input) else {
    fputs("Failed to load SVG: \(input)\n", stderr)
    exit(1)
}

let pixelSize = CGFloat(size)
image.size = NSSize(width: pixelSize, height: pixelSize)

guard let rep = NSBitmapImageRep(
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
) else { exit(1) }
rep.size = NSSize(width: pixelSize, height: pixelSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
           from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: output))
print("\(size)x\(size) → \(output)")
