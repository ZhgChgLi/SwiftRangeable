// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Rangeable",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_14)
    ],
    products: [
        .library(name: "Rangeable", targets: ["Rangeable"])
    ],
    targets: [
        .target(name: "Rangeable", path: "Sources/Rangeable"),
        .testTarget(
            name: "RangeableTests",
            dependencies: ["Rangeable"],
            path: "Tests/RangeableTests",
            resources: [
                .copy("Fixtures/cross_language.json")
            ]
        )
    ]
)
