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
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            exact: "0.10.0"
        )
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
        ),
        .testTarget(
            name: "FounderOfficeCoreTests",
            dependencies: [
                "FounderOfficeCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/FounderOfficeCoreTests"
        ),
        .testTarget(
            name: "FounderOfficeCloudTests",
            dependencies: [
                "FounderOfficeCloud",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/FounderOfficeCloudTests"
        )
    ]
)
