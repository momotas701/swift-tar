# swift-tar

A library for reading and writing TAR archives in Swift.

## Features

- Read & write - iterate over archive entries or build new archives
- Foundation-free - works without Foundation or any system framework
- Cross-platform - macOS, Linux, Windows, WebAssembly, Embedded Swift
- GNU & PAX extensions - transparent handling of long paths, long link names, and PAX extended headers

## Installation

Add swift-tar as a dependency in your `Package.swift`:

```console
swift package add-dependency https://github.com/kateinoigakukun/swift-tar --up-to-next-minor-from 0.1.0
swift package add-target-dependency Tar <your-package-target-name> --package swift-tar
```

## Quick Start

### Reading an Archive

```swift
import Tar

// `archiveBytes` is a [UInt8] containing the tar data
let archive = Archive(data: archiveBytes)

for entry in archive {
    let path = entry.fields.path()
    let size = entry.fields.size
    print("\(path) (\(size) bytes)")

    if entry.fields.effectiveEntryType().isFile {
        let contents = entry.data  // ArraySlice<UInt8>
        // process file contents...
    }
}
```

### Streaming Reader

```swift
import Tar

var reader = TarReader()

for chunk in chunks {
    let events = try reader.append(chunk)
    for event in events {
        switch event {
        case .entryStart(let fields):
            print("\(fields.path()) (\(fields.size) bytes)")
        case .data(let data):
            // process streamed file contents...
            print("received \(data.count) bytes")
        case .entryEnd:
            print("entry complete")
        }
    }
}

for event in try reader.finish() {
    print(event)
}
```

### Extracting an Archive

```swift
import Tar

let archive = Archive(data: archiveBytes)
let result = try TarExtractor().extract(archive, to: "output-directory")

print("Extracted \(result.extractedEntries) entries")
print("Skipped \(result.skippedEntries) entries")
```

### Streaming Extraction

```swift
import Tar

var reader = TarReader()
var extractor = try TarExtractor().streamingExtractor(to: "output-directory")

for chunk in chunks {
    let events = try reader.append(chunk)
    try extractor.consume(events)
}

try extractor.consume(reader.finish())
let result = try extractor.finish()

print("Extracted \(result.extractedEntries) entries")
print("Skipped \(result.skippedEntries) entries")
```

### Creating an Archive

```swift
import Tar

var writer = TarWriter(mode: .deterministic)

// Add a file
let fileData: [UInt8] = Array("Hello, world!\n".utf8)
var header = Header(asGnu: ())
header.entryType = .regular
header.setSize(UInt64(fileData.count))
header.setMode(0o644)
writer.appendData(header: header, path: "hello.txt", data: fileData)

// Add a directory
writer.appendDir(path: "subdir/")

// Finalize and get the bytes
let archiveBytes = writer.finish()
```

## Performance

Extraction benchmark of the 3.5 GB `swift-6.3-RELEASE-ubuntu24.04.tar` (from swift.org) archive on MacBook Pro with Apple M4 Max, 16 cores, 64 GB RAM, macOS 26.4 (`25E246`) with Swift 6.3. The archive was read once before
timing to warm the OS file cache. Measured with `hyperfine --warmup 2 --runs
7`. Each run extracted into a fresh temporary directory.

| Implementation | Command | Mean | Std. dev. | Median |
| --- | --- | ---: | ---: | ---: |
| `swift-tar` | `Examples/.build/release/ExtractArchive` | `2.918s` | `0.107s` | `2.896s` |
| libarchive | `bsdtar -xf` | `3.067s` | `0.054s` | `3.067s` |


## Running the Tests

The libarchive interoperability tests require test fixture files that are not
stored in the repository. Fetch them before running `swift test`:

```console
python3 Vendor/checkout-dependency libarchive
swift test
```

## License

This project is licensed under MIT License
