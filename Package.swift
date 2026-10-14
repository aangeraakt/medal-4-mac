// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Medal4Mac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Medal4Mac",
            path: "Sources/Medal4Mac"
        )
    ]
)
