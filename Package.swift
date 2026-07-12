// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TildeDiagnostics", targets: ["TildeDiagnosticsApp"]),
        .executable(name: "tilde-probe", targets: ["TildeProbe"]),
        .executable(name: "tilde-fan", targets: ["TildeFanCLI"]),
        .library(name: "TildeCore", targets: ["TildeCore"]),
    ],
    targets: [
        .target(
            name: "TildeCore",
            exclude: ["Monitoring/Fan/SMC/NOTICE.md"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "TildeDiagnosticsApp",
            dependencies: ["TildeCore"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "TildeProbe",
            dependencies: ["TildeCore"]
        ),
        .executableTarget(
            name: "TildeFanCLI",
            dependencies: ["TildeCore"]
        ),
        .testTarget(
            name: "TildeCoreTests",
            dependencies: ["TildeCore"]
        ),
    ]
)
