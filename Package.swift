// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stoplight",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable lives here; the executable is a four-line shim.
        .target(name: "StoplightCore", path: "Sources/StoplightCore"),
        .executableTarget(name: "Stoplight", dependencies: ["StoplightCore"], path: "Sources/Stoplight"),
        .testTarget(name: "StoplightCoreTests", dependencies: ["StoplightCore"], path: "Tests/StoplightCoreTests"),
    ]
)
