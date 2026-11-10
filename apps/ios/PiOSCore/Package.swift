// swift-tools-version:5.10
import PackageDescription

// Platform-free client logic: wire types, supervisor, outbox, session store.
// No UIKit or SwiftUI here, so it builds and tests on Linux as well as iOS.
let package = Package(
    name: "PiOSCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PiOSCore", targets: ["PiOSCore"]),
    ],
    targets: [
        .target(name: "PiOSCore"),
        .testTarget(name: "PiOSCoreTests", dependencies: ["PiOSCore"]),
    ]
)
