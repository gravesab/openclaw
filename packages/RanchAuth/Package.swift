// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RanchAuth",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RanchAuth", targets: ["RanchAuth"])
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "RanchAuth",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")
            ]
        ),
        .testTarget(
            name: "RanchAuthTests",
            dependencies: ["RanchAuth"]
        ),
    ]
)
