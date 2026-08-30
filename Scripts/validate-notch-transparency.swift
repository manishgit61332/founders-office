#!/usr/bin/swift

import AppKit
import Foundation

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let binaryCandidates = [
    packageRoot.appendingPathComponent(".build/release/OpenLoops"),
    packageRoot.appendingPathComponent(".build/arm64-apple-macosx/release/OpenLoops"),
    packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/release/OpenLoops")
]

guard let binaryURL = binaryCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
    fputs("Transparency validation requires a release OpenLoops build.\n", stderr)
    exit(1)
}

let validationRoot = fileManager.temporaryDirectory
    .appendingPathComponent("founder-office-transparency-\(UUID().uuidString)", isDirectory: true)
let snapshotURL = validationRoot.appendingPathComponent("settled-home.png")
try fileManager.createDirectory(at: validationRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: validationRoot) }

let process = Process()
process.executableURL = binaryURL
process.arguments = ["--snapshot", snapshotURL.path]
var environment = ProcessInfo.processInfo.environment
environment["OPENLOOPS_ROOT"] = validationRoot.path
environment["OPENLOOPS_PREVIEW_SECTION"] = "home"
process.environment = environment

let completion = DispatchSemaphore(value: 0)
process.terminationHandler = { _ in completion.signal() }
try process.run()

guard completion.wait(timeout: .now() + 15) == .success else {
    process.terminate()
    fputs("Transparency snapshot timed out.\n", stderr)
    exit(1)
}

guard process.terminationStatus == 0 else {
    fputs("Transparency snapshot failed with status \(process.terminationStatus).\n", stderr)
    exit(1)
}

guard let data = try? Data(contentsOf: snapshotURL),
      let bitmap = NSBitmapImageRep(data: data),
      bitmap.pixelsWide == 720,
      bitmap.pixelsHigh == 350 else {
    fputs("Transparency snapshot was missing or had unexpected dimensions.\n", stderr)
    exit(1)
}

let width = bitmap.pixelsWide
let height = bitmap.pixelsHigh
let exteriorSamples = [
    (0, 0), (5, 5), (0, 20),
    (width - 1, 0), (width - 6, 5), (width - 1, 20),
    (0, height - 1), (5, height - 6), (0, height - 21),
    (width - 1, height - 1), (width - 6, height - 6), (width - 1, height - 21)
]

for point in exteriorSamples {
    guard let color = bitmap.colorAt(x: point.0, y: point.1) else {
        fputs("Could not sample transparency at \(point).\n", stderr)
        exit(1)
    }
    guard color.alphaComponent <= 0.01 else {
        fputs(
            "Notch exterior is not transparent at \(point): alpha \(color.alphaComponent).\n",
            stderr
        )
        exit(1)
    }
}

guard let center = bitmap.colorAt(x: width / 2, y: height / 2),
      center.alphaComponent >= 0.95 else {
    fputs("Transparency snapshot appears blank or incomplete.\n", stderr)
    exit(1)
}

print("Notch transparency validation passed.")
