// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RTSPPush",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RTSPPush", targets: ["RTSPPush"])
    ],
    targets: [
        .target(name: "RTSPPush", path: "Sources/RTSPPush"),
        .testTarget(name: "RTSPPushTests", dependencies: ["RTSPPush"], path: "Tests/RTSPPushTests")
    ]
)
