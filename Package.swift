// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniRec",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "minirec", targets: ["MiniRec"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MiniRec",
            path: "Sources/MiniRec"
        )
    ]
)
