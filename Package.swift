// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTT",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "YTT", path: "Sources/YTT")
    ]
)
