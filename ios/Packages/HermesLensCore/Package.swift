// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesLensCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HermesLensCore", targets: ["HermesLensCore"]),
    ],
    targets: [
        .target(name: "HermesLensCore"),
        .testTarget(name: "HermesLensCoreTests", dependencies: ["HermesLensCore"]),
    ]
)

