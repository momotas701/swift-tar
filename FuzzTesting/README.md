# Fuzz Testing

This directory contains [libFuzzer](https://www.llvm.org/docs/LibFuzzer.html)-based
fuzz targets for **swift-tar**.

> [!WARNING]
> libFuzzer does not work with Xcode toolchains. Use the
> [open-source Swift toolchain](https://swift.org/install) on Linux.

## Targets

| Target | Description |
|---|---|
| **FuzzArchive** | Parses arbitrary bytes as a tar archive, exercising all entry-reading code paths (GNU long-name, PAX extensions, sparse headers...). |
| **FuzzRoundTrip** | Constructs a tar archive from fuzz input, reads it back, and verifies the round-trip. |

## Quick Start

```sh
cd FuzzTesting

# 1. Generate seed corpus
./fuzz.py seed

# 2. Run a fuzz target
./fuzz.py run FuzzArchive
```

## Building Manually

```sh
# Build (compiles with -sanitize=fuzzer,address)
./fuzz.py build FuzzArchive

# The fuzzer executable is at:
./.build/debug/FuzzArchive
```

## Reproducing Crashes

Crash inputs are saved to `FailCases/<target>/`. To reproduce:

```sh
./fuzz.py build FuzzArchive
./.build/debug/FuzzArchive FailCases/FuzzArchive/<crash-file>
```

## How It Works

Each fuzz target is a **static library** that exports the standard
libFuzzer entry point:

```swift
@_cdecl("LLVMFuzzerTestOneInput")
public func FuzzCheck(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt
```

The `fuzz.py` script:
1. Builds the library with `-sanitize=fuzzer,address`
2. Links it with `swiftc` (which pulls in `libclang_rt.fuzzer.a`)
3. Runs the resulting executable against the corpus

This follows the same approach used by
[WasmKit](https://github.com/swiftwasm/WasmKit/tree/main/FuzzTesting).
