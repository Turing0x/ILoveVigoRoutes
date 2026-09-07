// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VigoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VigoCore", targets: ["VigoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "VigoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/footpaths.csv"),
                        .copy("Resources/holidays-vigo.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VigoCoreTests",
            dependencies: ["VigoCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
