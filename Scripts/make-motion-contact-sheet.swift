import AppKit
import Foundation

guard CommandLine.arguments.count >= 4 else {
    fputs("Usage: make-motion-contact-sheet.swift OUTPUT.png FRAME.png FRAME.png [...]\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let frameURLs = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let images = frameURLs.compactMap(NSImage.init(contentsOf:))
guard images.count == frameURLs.count else { exit(1) }

let slotSize = NSSize(width: 720, height: 350)
let canvasSize = NSSize(width: slotSize.width * CGFloat(images.count), height: slotSize.height)
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
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

for (index, image) in images.enumerated() {
    image.draw(
        in: NSRect(x: CGFloat(index) * slotSize.width, y: 0, width: slotSize.width, height: slotSize.height),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
}

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: outputURL, options: .atomic)
