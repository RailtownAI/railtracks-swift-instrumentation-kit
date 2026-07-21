// swift-tools-version: 6.0
//
// RailtracksInstrumentationKit
//
// Public API for emitting Railtracks Instrumentation signposts that the
// matching Instruments package (RailtracksInstrumentation.instrpkg) renders
// as Flow Tree / Flow Object Graph / Tool I/O views. Also ships the
// RTSFlowGraph Codable data contract so producers and consumers agree on
// the JSON shape.

import PackageDescription

let package = Package(
    name: "RailtracksInstrumentationKit",
    platforms: [
        .macOS(.v15), .iOS(.v18)
    ],
    products: [
        .library(
            name: "RailtracksInstrumentationKit",
            targets: ["RailtracksInstrumentationKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "RailtracksInstrumentationKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/RailtracksInstrumentationKit"
        )
    ]
)
