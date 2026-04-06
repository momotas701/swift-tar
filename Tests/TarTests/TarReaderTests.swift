import Foundation
import Testing

@testable import Tar

// MARK: - Helpers

/// Collect all events from a TarReader fed with `data` in chunks of `chunkSize`.
private func collectEvents(
    _ data: [UInt8], chunkSize: Int, readConcatenatedArchives: Bool = false,
    mergeMacMetadata: Bool = false
) throws -> [TarReader.Event] {
    var reader = TarReader(
        readConcatenatedArchives: readConcatenatedArchives, mergeMacMetadata: mergeMacMetadata)
    var events: [TarReader.Event] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        events.append(contentsOf: try reader.append(Array(data[offset..<end])))
        offset = end
    }
    events.append(contentsOf: try reader.finish())
    return events
}

/// Reconstruct entries with full data from an event stream, for comparison
/// with the batch `Archive` reader.
private struct ReconstructedEntry {
    let entry: EntryFields
    let data: [UInt8]

    var path: String { entry.path() }
    var size: UInt64 { entry.size }
    var entryType: EntryType { entry.header.entryType }
    var linkName: String? { entry.linkName() }
}

private func reconstructEntries(from events: [TarReader.Event]) -> [ReconstructedEntry] {
    var results: [ReconstructedEntry] = []
    var current: EntryFields? = nil
    var currentData: [UInt8] = []

    for event in events {
        switch event {
        case .entryStart(let entry):
            current = entry
            currentData = []
        case .data(let chunk):
            currentData.append(contentsOf: chunk)
        case .entryEnd:
            if let entry = current {
                results.append(ReconstructedEntry(entry: entry, data: currentData))
            }
            current = nil
            currentData = []
        }
    }
    return results
}

// MARK: - TarReader Streaming Tests

@Suite("TarReader")
struct TarReaderTests {
    @Test("streaming merges repeated local and global pax headers")
    func streamingMergesRepeatedLocalAndGlobalPaxHeaders() throws {
        var writer = TarWriter()

        let globalPaxData = encodePaxData([
            (key: "path", value: [UInt8]("global.txt".utf8)),
            (key: "uid", value: [UInt8]("123".utf8)),
            (key: "uname", value: [UInt8]("global-user".utf8)),
        ])
        writer.append(
            header: makePaxHeader(entryType: .paxGlobalExtensions, data: globalPaxData),
            data: globalPaxData
        )

        let localPaxData1 = encodePaxData([
            (key: "path", value: [UInt8]("local-1.txt".utf8)),
            (key: "gid", value: [UInt8]("7".utf8)),
        ])
        writer.append(
            header: makePaxHeader(entryType: .paxLocalExtensions, data: localPaxData1),
            data: localPaxData1
        )

        let localPaxData2 = encodePaxData([
            (key: "path", value: [UInt8]("local-2.txt".utf8)),
            (key: "gid", value: [UInt8]("8".utf8)),
            (key: "gname", value: [UInt8]("local-group".utf8)),
            (key: "mtime", value: [UInt8]("42".utf8)),
        ])
        writer.append(
            header: makePaxHeader(entryType: .paxLocalExtensions, data: localPaxData2),
            data: localPaxData2
        )

        var firstHeader = Header(asUstar: ())
        firstHeader.entryType = .regular
        firstHeader.setMode(0o644)
        writer.appendData(header: firstHeader, path: "base.txt", data: [UInt8]("body".utf8))

        var secondHeader = Header(asUstar: ())
        secondHeader.entryType = .regular
        secondHeader.setMode(0o644)
        writer.appendData(header: secondHeader, path: "fallback.txt", data: [UInt8]("next".utf8))

        let events = try collectEvents(writer.finish(), chunkSize: 13)
        let entries = reconstructEntries(from: events)

        #expect(entries.count == 2)
        #expect(entries[0].path == "local-2.txt")
        #expect(try entries[0].entry.uid() == 123)
        #expect(try entries[0].entry.gid() == 8)
        #expect(try entries[0].entry.mtime() == 42)
        #expect(try entries[0].entry.username() == "global-user")
        #expect(try entries[0].entry.groupname() == "local-group")
        #expect(entries[0].entry.paxHeaders?["uid"] == "123")
        #expect(entries[0].entry.paxHeaders?["gid"] == "8")
        #expect(entries[1].path == "global.txt")
        #expect(try entries[1].entry.uid() == 123)
        #expect(try entries[1].entry.gid() == 0)
        #expect(try entries[1].entry.username() == "global-user")
        #expect(try entries[1].entry.groupname() == "")
        #expect(entries[1].entry.paxHeaders?["uid"] == "123")
        #expect(entries[1].entry.paxHeaders?["gid"] == nil)
    }

    // MARK: - Special archives

    @Test("empty archive")
    func emptyArchive() throws {
        let data = [UInt8](repeating: 0, count: 1024)
        let events = try collectEvents(data, chunkSize: 512)
        let entries = reconstructEntries(from: events)
        #expect(entries.isEmpty)
    }

    @Test("single zero block at eof is accepted")
    func singleZeroBlockAtEof() throws {
        let data = [UInt8](repeating: 0, count: 512)
        let events = try collectEvents(data, chunkSize: 512)
        let entries = reconstructEntries(from: events)
        #expect(entries.isEmpty)
    }

    @Test("lone eof zero block then invalid-padding is accepted")
    func loneZeroBlockThenInvalidPaddingAccepted() throws {
        var writer = TarWriter()
        var header = Header(asUstar: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "a.txt", data: [UInt8(ascii: "x")])
        var data = writer.finish()
        // `finish()` appends 1024 zero bytes (two EOF blocks). Keep only the first 512 so the
        // stream ends with a single end marker, then non-header junk (Plexus-style padding).
        data.removeLast(512)
        data.append(contentsOf: [UInt8](repeating: 0xFE, count: 512))

        let archive = Archive(data: data)
        let entries = Array(archive)
        try #require(entries.count == 1)
        #expect(entries[0].fields.path() == "a.txt")
    }

    @Test("zero block followed by non-zero block throws")
    func zeroBlockThenNonZeroBlock() throws {
        var writer = TarWriter()
        var header = Header(asUstar: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "after-zero.txt", data: [UInt8]("body".utf8))

        let data = [UInt8](repeating: 0, count: 512) + writer.finish()
        var reader = TarReader()

        _ = try reader.append(data[..<512])
        try #require(throws: TarError.self) {
            _ = try reader.append(data[512...])
        }
    }

    // MARK: - TarWriter round-trip

    @Test("tar writer output parsed by streaming reader")
    func tarWriterRoundTrip() throws {
        var writer = TarWriter()
        var h1 = Header(asGnu: ())
        h1.entryType = .regular
        h1.setMode(0o644)
        writer.appendData(header: h1, path: "a.txt", data: [UInt8]("hello".utf8))

        var h2 = Header(asGnu: ())
        h2.entryType = .regular
        h2.setMode(0o644)
        writer.appendData(header: h2, path: "b.txt", data: [UInt8]("world".utf8))

        writer.appendDir(path: "dir")

        let archiveData = writer.finish()
        let events = try collectEvents(archiveData, chunkSize: 300)
        let entries = reconstructEntries(from: events)

        #expect(entries.count == 3)
        #expect(entries[0].path == "a.txt")
        #expect(entries[0].data == [UInt8]("hello".utf8))
        #expect(entries[1].path == "b.txt")
        #expect(entries[1].data == [UInt8]("world".utf8))
        #expect(entries[2].path == "dir/")
        #expect(entries[2].entryType == .directory)
    }

    @Test("tar writer long path parsed by streaming reader")
    func tarWriterLongPathRoundTrip() throws {
        var writer = TarWriter()
        let longPath =
            "very/long/directory/path/that/is/definitely/more/than/one/hundred/bytes/long/and/needs/GNU/extension/to/store/properly/file.txt"
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: longPath, data: [42])
        let archiveData = writer.finish()

        // byte-by-byte to stress streaming
        let events = try collectEvents(archiveData, chunkSize: 1)
        let entries = reconstructEntries(from: events)

        #expect(entries.count == 1)
        #expect(entries[0].path == longPath)
        #expect(entries[0].data == [42])
    }

    // MARK: - Streaming data delivery

    @Test("data arrives in multiple chunks for large entry")
    func multipleDataChunks() throws {
        // Build an archive with a 2KB file
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        let fileData = [UInt8](repeating: 0x42, count: 2048)
        writer.appendData(header: header, path: "big.bin", data: fileData)
        let archiveData = writer.finish()

        // Feed in 300-byte chunks -- data should arrive in pieces
        let events = try collectEvents(archiveData, chunkSize: 300)

        var dataChunkCount = 0
        for event in events {
            if case .data = event { dataChunkCount += 1 }
        }
        #expect(dataChunkCount > 1, "Expected multiple .data events, got \(dataChunkCount)")

        // Verify reassembled content
        let entries = reconstructEntries(from: events)
        #expect(entries.count == 1)
        #expect(entries[0].data == fileData)
    }

    @Test("zero-length file emits no data events")
    func zeroLengthFile() throws {
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "empty.txt", data: [])
        let archiveData = writer.finish()

        let events = try collectEvents(archiveData, chunkSize: 512)

        var dataChunkCount = 0
        for event in events {
            if case .data = event { dataChunkCount += 1 }
        }
        #expect(dataChunkCount == 0)

        let entries = reconstructEntries(from: events)
        #expect(entries.count == 1)
        #expect(entries[0].data.isEmpty)
    }

    // MARK: - Error cases

    @Test("finish with partial header throws")
    func partialHeaderThrows() throws {
        var reader = TarReader()
        let _ = try reader.append([UInt8](repeating: 0x41, count: 256))
        #expect(throws: TarError.self) {
            try reader.finish()
        }
    }

    @Test("finish with partial data throws")
    func partialDataThrows() throws {
        // Build a valid archive, then truncate mid-data
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header, path: "test.txt", data: [UInt8](repeating: 0x42, count: 1024))
        let archiveData = writer.finish()

        // Feed only the header + partial data (header=512, data partial=300)
        let truncated = Array(archiveData[0..<812])
        var reader = TarReader()
        let _ = try reader.append(truncated)
        #expect(throws: TarError.self) {
            try reader.finish()
        }
    }

    @Test("bad checksum stops streaming reader without throwing")
    func badChecksumStopsStreamingReader() throws {
        // Build a valid archive, then corrupt a byte in the name field
        // (not the checksum field itself, so the stored checksum is still
        // parseable as octal) so the stored value no longer matches.
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "test.txt", data: [UInt8]("hello".utf8))
        var archiveBytes = writer.finish()

        // Flip a bit in the name field (byte 0) - checksum mismatch.
        archiveBytes[0] ^= 0x01

        var reader = TarReader()
        let events = try reader.append(archiveBytes)
        #expect(
            !events.contains {
                if case .entryStart = $0 { return true }
                return false
            })
    }
}
