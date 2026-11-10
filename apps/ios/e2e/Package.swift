// swift-tools-version:5.10
import PackageDescription

// Drives the real PiosClient against a running daemon (normally
// `pnpm sandbox --no-web`), so the wire can be checked without a Mac.
let package = Package(
    name: "pios-e2e",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../PiOSCore")],
    targets: [
        .executableTarget(name: "pios-e2e", dependencies: [.product(name: "PiOSCore", package: "PiOSCore")]),
    ]
)
