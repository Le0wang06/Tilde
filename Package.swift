// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TildeDiagnostics", targets: ["TildeDiagnosticsApp"]),
        .library(name: "TildeCore", targets: ["TildeCore"]),
    ],
    targets: [
        .target(
            name: "TildeCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "TildeDiagnosticsApp",
            dependencies: ["TildeCore"]
        ),
        .testTarget(
            name: "TildeCoreTests",
            dependencies: ["TildeCore"]
        ),
    ]
)
