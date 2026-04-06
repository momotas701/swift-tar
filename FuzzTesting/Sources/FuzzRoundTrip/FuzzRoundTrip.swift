// FuzzRoundTrip - libFuzzer target for tar archive round-trip.
//
// Takes arbitrary bytes, constructs a tar archive from slices of the
// input, reads the archive back, and verifies the data survives the
// round-trip. Must never crash on any input.

import Tar

/// Derive a short, safe path component from a few fuzz bytes.
private func makePath(from bytes: ArraySlice<UInt8>, index: Int) -> String {
    var chars: [UInt8] = []
    for b in bytes.prefix(30) {
        // Map to printable ASCII '!'...'~', replacing '/' with '_'.
        let c = (b % 94) + 33
        chars.append(c == UInt8(ascii: "/") ? UInt8(ascii: "_") : c)
    }
    if chars.isEmpty {
        return "fuzz/entry_\(index).dat"
    }
    return "fuzz/" + String(decoding: chars, as: UTF8.self)
}

@_cdecl("LLVMFuzzerTestOneInput")
public func FuzzCheck(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let data = Array(UnsafeBufferPointer(start: start, count: count))

    // Cap input size to keep execution fast.
    let usable = Array(data.prefix(16384))

    // Decide how many entries to create (1-8), driven by the first byte.
    let entryCount: Int
    if usable.isEmpty {
        entryCount = 0
    } else {
        entryCount = Int(usable[0] % 8) + 1
    }

    guard entryCount > 0 else {
        // Empty input -> empty archive round-trip.
        var writer = TarWriter(mode: .deterministic)
        let archiveBytes = writer.finish()
        let entries = Array(Archive(data: archiveBytes))
        assert(entries.isEmpty, "Empty archive should have no entries")
        return 0
    }

    // Split the remaining bytes among entries.
    let remaining = Array(usable.dropFirst())
    let chunkSize = remaining.isEmpty ? 0 : max(1, remaining.count / entryCount)

    // -- Build phase --
    var writer = TarWriter(mode: .deterministic)
    var expected: [(path: String, data: [UInt8])] = []

    for i in 0..<entryCount {
        let lo = min(i * chunkSize, remaining.count)
        let hi = min(lo + chunkSize, remaining.count)
        let entryData = Array(remaining[lo..<hi])

        let pathSeed: ArraySlice<UInt8> = entryData.count >= 2
            ? entryData[entryData.startIndex..<min(entryData.startIndex + 8, entryData.endIndex)]
            : ArraySlice<UInt8>()
        let path = makePath(from: pathSeed, index: i)

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: path, data: entryData)
        expected.append((path: path, data: entryData))
    }

    // Exercise directory creation.
    if remaining.count > 2 {
        writer.appendDir(path: "fuzz/dir_\(remaining[remaining.count / 2])/")
    }

    // Exercise PAX extensions.
    if remaining.count > 10 {
        let paxValue = Array(remaining.suffix(min(64, remaining.count)))
        writer.appendPaxExtensions([
            (key: "fuzz.test", value: paxValue),
            (key: "comment", value: Array("fuzz-generated".utf8)),
        ])
    }

    let archiveBytes = writer.finish()

    // -- Verify phase --
    let archive = Archive(data: archiveBytes)

    // Walk processed entries; verify regular-file entries match.
    var fileIndex = 0
    for entry in archive {
        let _ = entry.fields.path()
        let _ = entry.data
        let _ = try? entry.fields.header.validateChecksum()

        if entry.fields.header.entryType == .regular, fileIndex < expected.count {
            let exp = expected[fileIndex]
            assert(entry.fields.path() == exp.path,
                   "Path mismatch at \(fileIndex)")
            assert(entry.data.elementsEqual(exp.data),
                   "Data mismatch at \(fileIndex)")
            fileIndex += 1
        }
    }
    assert(fileIndex == expected.count,
           "Entry count mismatch: \(fileIndex) vs \(expected.count)")

    // Raw iteration for extra coverage.
    for entry in archive {
        let _ = entry.fields.path()
        let _ = entry.data
    }

    // Double round-trip: re-build from raw entries and compare counts.
    var writer2 = TarWriter(mode: .complete)
    for entry in archive {
        writer2.append(header: entry.fields.header, data: entry.data)
    }
    let archive2 = Archive(data: writer2.finish())
    let c1 = Array(archive).count
    let c2 = Array(archive2).count
    assert(c1 == c2, "Double round-trip entry count mismatch: \(c1) vs \(c2)")

    return 0
}
