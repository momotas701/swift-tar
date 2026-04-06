//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-tar open source project
//
// Copyright (c) 2026 Yuta Saito and the swift-tar project authors
// Licensed under MIT License
//
// See https://github.com/kateinoigakukun/swift-tar/blob/main/LICENSE for
// license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Benchmark
import Tar
import CLibArchive
import Foundation



// MARK: - Test Data Generation

/// Build a tar archive in memory with the given number of files.
/// Each file has the specified body size filled with repeating bytes.
private func buildTestArchive(fileCount: Int, bodySize: Int) -> [UInt8] {
    var writer = TarWriter(mode: .deterministic)
    let body = [UInt8](repeating: 0x41, count: bodySize)
    for i in 0..<fileCount {
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "file_\(i).txt", data: body)
    }
    return writer.finish()
}

/// Build a tar archive with PAX extended headers.
private func buildPaxArchive(fileCount: Int, bodySize: Int) -> [UInt8] {
    var writer = TarWriter(mode: .deterministic)
    let body = [UInt8](repeating: 0x42, count: bodySize)
    for i in 0..<fileCount {
        // Add PAX extensions for each file
        writer.appendPaxExtensions([
            (key: "uid", value: [UInt8]("123456".utf8)),
            (key: "gid", value: [UInt8]("789012".utf8)),
            (key: "SCHILY.xattr.user.test", value: [UInt8]("value_\(i)".utf8)),
        ])
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "pax_file_\(i).txt", data: body)
    }
    return writer.finish()
}

/// Build a tar archive with GNU long filenames.
private func buildLongNameArchive(fileCount: Int, bodySize: Int) -> [UInt8] {
    var writer = TarWriter(mode: .deterministic)
    let body = [UInt8](repeating: 0x43, count: bodySize)
    for i in 0..<fileCount {
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        let longPath = "very/long/directory/structure/that/exceeds/the/hundred/byte/limit/in/standard/tar/headers/file_\(i).txt"
        writer.appendData(header: header, path: longPath, data: body)
    }
    return writer.finish()
}

// MARK: - libarchive reading helper

/// Read all entries from a tar archive using libarchive.
/// Returns the number of entries read.
@inline(never)
private func libarchiveReadEntries(_ data: [UInt8]) -> Int {
    var entryCount = 0
    data.withUnsafeBufferPointer { buf in
        guard let a = archive_read_new() else { return }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK else {
            archive_read_free(a)
            return
        }
        var entry: OpaquePointer?
        while archive_read_next_header(a, &entry) == ARCHIVE_OK {
            entryCount += 1
            archive_read_data_skip(a)
        }
        archive_read_free(a)
    }
    return entryCount
}

/// Read all entries and their data using libarchive.
/// Returns total bytes of data read.
@inline(never)
private func libarchiveReadAllData(_ data: [UInt8]) -> Int {
    var totalBytes = 0
    data.withUnsafeBufferPointer { buf in
        guard let a = archive_read_new() else { return }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK else {
            archive_read_free(a)
            return
        }
        var entry: OpaquePointer?
        let readBuf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 8)
        defer { readBuf.deallocate() }
        while archive_read_next_header(a, &entry) == ARCHIVE_OK {
            while true {
                let n = archive_read_data(a, readBuf, 65536)
                if n <= 0 { break }
                totalBytes += n
            }
        }
        archive_read_free(a)
    }
    return totalBytes
}

// MARK: - swift-tar reading helpers

@inline(never)
private func swiftTarReadEntries(_ data: [UInt8]) -> Int {
    let archive = Archive(data: data)
    var count = 0
    for _ in archive {
        count += 1
    }
    return count
}

@inline(never)
private func swiftTarReadAllData(_ data: [UInt8]) -> Int {
    let archive = Archive(data: data)
    var totalBytes = 0
    for entry in archive {
        totalBytes += entry.data.count
    }
    return totalBytes
}

// MARK: - Benchmarks

// Pre-built archives (lazily initialized)
private let small100  = buildTestArchive(fileCount: 100,  bodySize: 64)
private let small1000 = buildTestArchive(fileCount: 1000, bodySize: 64)
private let large100  = buildTestArchive(fileCount: 100,  bodySize: 65536)
private let large1000 = buildTestArchive(fileCount: 1000, bodySize: 4096)
private let pax100    = buildPaxArchive(fileCount: 100,   bodySize: 64)
private let pax1000   = buildPaxArchive(fileCount: 1000,  bodySize: 64)
private let long100   = buildLongNameArchive(fileCount: 100,  bodySize: 64)
private let long1000  = buildLongNameArchive(fileCount: 1000, bodySize: 64)

let benchmarks: @Sendable () -> Void = {

    // =========================================================================
    // Read entries (header iteration, skip data)
    // =========================================================================

    Benchmark(
        "Read entries (100 files, 64B) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(small100))
        }
    }

    Benchmark(
        "Read entries (100 files, 64B) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(small100))
        }
    }

    Benchmark(
        "Read entries (1000 files, 64B) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(small1000))
        }
    }

    Benchmark(
        "Read entries (1000 files, 64B) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(small1000))
        }
    }

    // =========================================================================
    // Read all data
    // =========================================================================

    Benchmark(
        "Read all data (100 files, 64KB) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadAllData(large100))
        }
    }

    Benchmark(
        "Read all data (100 files, 64KB) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadAllData(large100))
        }
    }

    Benchmark(
        "Read all data (1000 files, 4KB) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadAllData(large1000))
        }
    }

    Benchmark(
        "Read all data (1000 files, 4KB) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadAllData(large1000))
        }
    }

    // =========================================================================
    // PAX extended headers
    // =========================================================================

    Benchmark(
        "Read PAX entries (100 files) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(pax100))
        }
    }

    Benchmark(
        "Read PAX entries (100 files) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(pax100))
        }
    }

    Benchmark(
        "Read PAX entries (1000 files) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(pax1000))
        }
    }

    Benchmark(
        "Read PAX entries (1000 files) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(pax1000))
        }
    }

    // =========================================================================
    // GNU long names
    // =========================================================================

    Benchmark(
        "Read GNU long names (100 files) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(long100))
        }
    }

    Benchmark(
        "Read GNU long names (100 files) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(long100))
        }
    }

    Benchmark(
        "Read GNU long names (1000 files) -- swift-tar",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(swiftTarReadEntries(long1000))
        }
    }

    Benchmark(
        "Read GNU long names (1000 files) -- libarchive",
        configuration: .init(warmupIterations: 3, scalingFactor: .kilo)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(libarchiveReadEntries(long1000))
        }
    }

}
