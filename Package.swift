// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"])
    ],
    targets: [
        .executableTarget(
            name: "Cadence",
            path: "Sources/Cadence"
        ),
        .testTarget(
            name: "CadenceTests",
            dependencies: ["Cadence"],
            path: "Tests/CadenceTests"
        )
    ]
)
