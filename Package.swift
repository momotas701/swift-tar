// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-tar",
    products: [
        .library(name: "Tar", targets: ["Tar"]),
    ],
    targets: [
        .target(name: "Tar"),
        .testTarget(
            name: "TarTests",
            dependencies: ["Tar"]
        ),
    ]
)
