// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySSH",
    platforms: [
        .iOS(.v17), // 必须是 iOS 17，匹配 Citadel 的最低要求
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MySSH",
            targets: ["MySSH"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
    ],
    targets: [
        .target(
            name: "MySSH",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/MySSH",
            exclude: ["Info.plist"]
        )
    ]
)
