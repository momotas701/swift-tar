// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-tar-examples",
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "ListEntries",
            dependencies: [
                .product(name: "Tar", package: "swift-tar"),
            ],
            path: "ListEntries"
        ),
        .executableTarget(
            name: "CreateArchive",
            dependencies: [
                .product(name: "Tar", package: "swift-tar"),
            ],
            path: "CreateArchive"
        ),
        .executableTarget(
            name: "ExtractArchive",
            dependencies: [
                .product(name: "Tar", package: "swift-tar"),
            ],
            path: "ExtractArchive"
        ),
    ]
)
