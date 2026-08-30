import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: make-animated-gif.swift FRAMES_DIRECTORY OUTPUT.gif\n", stderr)
    exit(2)
}

let framesURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let frameURLs = try FileManager.default.contentsOfDirectory(
    at: framesURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
).filter { $0.pathExtension.lowercased() == "png" }
 .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !frameURLs.isEmpty,
      let destination = CGImageDestinationCreateWithURL(
          outputURL as CFURL,
          UTType.gif.identifier as CFString,
          frameURLs.count,
          nil
      ) else {
    exit(1)
}

let gifProperties: [CFString: Any] = [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0
    ]
]
CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

let frameProperties: [CFString: Any] = [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 1.0 / 30.0
    ]
]

for frameURL in frameURLs {
    guard let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        continue
    }
    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
}

guard CGImageDestinationFinalize(destination) else { exit(1) }
