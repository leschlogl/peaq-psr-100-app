// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RingProtocol",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "RingProtocol", targets: ["RingProtocol"])],
    targets: [
        .target(name: "RingProtocol"),
        .testTarget(name: "RingProtocolTests", dependencies: ["RingProtocol"])
    ]
)
