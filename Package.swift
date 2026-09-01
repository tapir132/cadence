// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b"
        )
    ],
    targets: [
        .executableTarget(
            name: "Cadence",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Cadence"
        ),
        .testTarget(
            name: "CadenceTests",
            dependencies: [
                "Cadence",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Tests/CadenceTests"
        )
    ]
)
