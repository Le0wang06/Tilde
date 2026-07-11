// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TildeDiagnostics", targets: ["TildeDiagnosticsApp"]),
        .executable(name: "tilde-probe", targets: ["TildeProbe"]),
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
        .executableTarget(
            name: "TildeProbe",
            dependencies: ["TildeCore"]
        ),
        .testTarget(
            name: "TildeCoreTests",
            dependencies: ["TildeCore"]
        ),
    ]
)
