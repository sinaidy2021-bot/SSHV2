// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySSH",
    platforms: [
        .iOS(.v17), 
        .macOS(.v14)
    ],
    products: [
        // 这里必须是 executable，否则不会生成可执行二进制文件
        .executable(
            name: "MySSH",
            targets: ["MySSH"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
    ],
    targets: [
        // 这里必须是 executableTarget
        .executableTarget(
            name: "MySSH",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/MySSH",
            exclude: ["Info.plist"]
        )
    ]
)
