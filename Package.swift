// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySSH",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MySSH",
            targets: ["MySSH"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
    ],
    targets: [
        .executableTarget(
            name: "MySSH",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/MySSH",
            exclude: ["Info.plist", "AppIcon.png"]
        )
    ]
)
