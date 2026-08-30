import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: make-qa-comparison.swift SOURCE IMPLEMENTATION OUTPUT\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let implementationURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let source = NSImage(contentsOf: sourceURL),
      let implementation = NSImage(contentsOf: implementationURL) else {
    fputs("Could not open one of the input images.\n", stderr)
    exit(1)
}

func pixelSize(of image: NSImage) -> NSSize {
    if let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
        return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
    return image.size
}

let sourcePixels = pixelSize(of: source)
let implementationPixels = pixelSize(of: implementation)
let targetHeight = max(sourcePixels.height, implementationPixels.height)
let sourceWidth = targetHeight * sourcePixels.width / sourcePixels.height
let implementationWidth = targetHeight * implementationPixels.width / implementationPixels.height
let canvasSize = NSSize(width: sourceWidth + implementationWidth, height: targetHeight)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.current = context
NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

source.draw(
    in: NSRect(x: 0, y: 0, width: sourceWidth, height: targetHeight),
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1
)

let implementationRect = NSRect(
    x: sourceWidth,
    y: 0,
    width: implementationWidth,
    height: targetHeight
)
implementation.draw(
    in: implementationRect,
    from: NSRect(origin: .zero, size: implementation.size),
    operation: .copy,
    fraction: 1
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: outputURL, options: .atomic)
