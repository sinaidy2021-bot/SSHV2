// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySSH",
    platforms: [
        .iOS(.v16),
        .macOS(.v14) // 明确指定 macOS 14，解决 Citadel 依赖版本冲突
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
            exclude: ["Info.plist"] // 排除 Info.plist 避免编译器解析警告
        )
    ]
)
