// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySSH",
    platforms: [
        .iOS(.v16)
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
            path: "Sources/MySSH"
        )
    ]
)
