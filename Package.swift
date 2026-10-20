// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WeChatMulti",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WeChatMulti",
            path: "Sources/WeChatMulti"
        )
    ]
)
