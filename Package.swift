// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartLockKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(name: "SmartLockKit", targets: ["SmartLockKit"])
    ],
    targets: [
        .target(
            name: "SmartLockKit",
            path: "Sources/SmartLockKit"
        ),
        .testTarget(
            name: "SmartLockKitTests",
            dependencies: ["SmartLockKit"],
            path: "Tests/SmartLockKitTests"
        )
    ]
)
