// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-tar-fuzz",
    products: [
        // We build static libraries instead of executables because libFuzzer
        // (libclang_rt.fuzzer.a) provides its own `main` symbol. If we built
        // executables, SwiftPM's linker would emit a conflicting `main`.
        // Instead we compile library objects that export
        // `LLVMFuzzerTestOneInput` and then manually link them with the
        // fuzzer runtime via `fuzz.py`.
        .library(name: "FuzzRoundTrip", type: .static, targets: ["FuzzRoundTrip"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "FuzzRoundTrip",
            dependencies: [
                .product(name: "Tar", package: "swift-tar"),
            ]
        ),
    ]
)
