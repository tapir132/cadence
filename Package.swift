// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS("14.2")],
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
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "NOTICES", "README.md"],
            sources: ["mdf.c", "fftwrap.c", "smallft.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"), .define("FLOATING_POINT"),
                .define("USE_SMALLFT"), .define("EXPORT", to: "")
            ]
        ),
        .executableTarget(
            name: "Cadence",
            dependencies: [
                "CSpeexDSP",
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
