// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeamsMicFloat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TeamsMicFloat", targets: ["TeamsMicFloat"])
    ],
    targets: [
        .executableTarget(
            name: "TeamsMicFloat",
            path: "Sources/TeamsMicFloat"
        ),
    ]
)
