// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HLLKit",
    platforms: [.iOS(.v27), .watchOS(.v27), .macOS(.v27)],
    products: [.library(name: "HLLKit", targets: ["HLLKit"])],
    targets: [
        .target(name: "HLLKit"),
        .testTarget(name: "HLLKitTests", dependencies: ["HLLKit"])
    ]
)
