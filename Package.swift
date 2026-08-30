// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenLoops",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "FounderOfficeCore", targets: ["FounderOfficeCore"]),
        .library(name: "FounderOfficeCloud", targets: ["FounderOfficeCloud"]),
        .executable(name: "FounderOfficeCoreChecks", targets: ["FounderOfficeCoreChecks"]),
        .executable(name: "OpenLoops", targets: ["OpenLoops"])
    ],
    targets: [
        .target(
            name: "FounderOfficeCore",
            path: "Sources/FounderOfficeCore"
        ),
        .target(
            name: "FounderOfficeCloud",
            dependencies: ["FounderOfficeCore"],
            path: "Sources/FounderOfficeCloud"
        ),
        .executableTarget(
            name: "OpenLoops",
            dependencies: ["FounderOfficeCore", "FounderOfficeCloud"],
            path: "Sources/OpenLoops"
        ),
        .executableTarget(
            name: "FounderOfficeCoreChecks",
            dependencies: ["FounderOfficeCore", "FounderOfficeCloud"],
            path: "Checks/FounderOfficeCoreChecks"
        )
    ]
)
