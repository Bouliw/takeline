// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TakelineCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "TakelineCore", targets: ["TakelineCore"]),
    ],
    targets: [
        .target(name: "TakelineCore"),
        .testTarget(name: "TakelineCoreTests", dependencies: ["TakelineCore"]),
    ]
)
