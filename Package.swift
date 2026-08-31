// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Cadence",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Cadence"
        ),
        .testTarget(
            name: "CadenceTests",
            dependencies: ["Cadence"],
            path: "Tests/CadenceTests"
        )
    ]
)
