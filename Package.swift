// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kato",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "KatoCore",
            path: "Sources/KatoCore"
        ),
        .executableTarget(
            name: "Kato",
            dependencies: ["KatoCore"],
            path: "Sources/Kato"
        ),
        // Tiny assertion-based smoke harness. This machine ships Command Line
        // Tools only (no XCTest/swift-testing), so unit-level checks live here
        // as well: `swift run KatoSmoke`.
        .executableTarget(
            name: "KatoSmoke",
            dependencies: ["KatoCore"],
            path: "Sources/KatoSmoke"
        ),
        // Requires a full Xcode install (XCTest is absent from Command Line
        // Tools). `swift build` does not compile this target, so CLT-only
        // machines stay green; run `swift test` where Xcode is installed.
        .testTarget(
            name: "KatoCoreTests",
            dependencies: ["KatoCore"],
            path: "Tests/KatoCoreTests"
        ),
    ]
)
