// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecryptoCipher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RecryptoCipher", targets: ["RecryptoCipher"]),
    ],
    targets: [
        .executableTarget(
            name: "RecryptoCipher",
            path: "Sources/RecryptoCipher",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
    ]
)
