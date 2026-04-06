// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "swift-tar", path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.4.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CLibArchive",
            path: "CLibArchive",
            pkgConfig: "libarchive",
            providers: [
                .apt(["libarchive-dev"]),
                .brew(["libarchive"]),
            ]
        ),
        .executableTarget(
            name: "TarBenchmark",
            dependencies: [
                .product(name: "Tar", package: "swift-tar"),
                .product(name: "Benchmark", package: "package-benchmark"),
                "CLibArchive",
            ],
            path: "Benchmarks/TarBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
