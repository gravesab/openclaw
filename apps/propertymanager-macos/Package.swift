// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PropertyManagerApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "PropertyManagerApp",
            targets: ["PropertyManagerApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PropertyManagerApp"
        )
    ]
)
