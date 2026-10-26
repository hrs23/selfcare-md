// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SelfcareCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SelfcareCore", targets: ["SelfcareCore"])
    ],
    targets: [
        .target(name: "SelfcareCore"),
        .testTarget(name: "SelfcareCoreTests", dependencies: ["SelfcareCore"])
    ]
)
