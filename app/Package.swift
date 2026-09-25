// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleUnzip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SimpleUnzip", targets: ["SimpleUnzip"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    targets: [
        .target(
            name: "ArchiveKit",
            path: "Sources/ArchiveKit"
        ),
        .executableTarget(
            name: "SimpleUnzip",
            dependencies: ["ArchiveKit"],
            path: "Sources/SimpleUnzip"
        ),
        // Command Line Tools on this machine ship no XCTest, so the checks run
        // through a small in-repo runner instead of `swift test`.
        .executableTarget(
            name: "SelfTest",
            dependencies: ["ArchiveKit"],
            path: "Sources/SelfTest"
        ),
        // Exhaustive format x level x password matrix. Long running, so it is a
        // separate product rather than part of the quick self-test.
        .executableTarget(
            name: "ExhaustiveTest",
            dependencies: ["ArchiveKit"],
            path: "Sources/ExhaustiveTest"
        ),
    ]
)
