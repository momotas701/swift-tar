import Foundation
import Testing

@testable import Tar

#if os(WASI)
    import WASILibc
#elseif canImport(Android)
    import Android
#endif

@Suite("TarExtractor")
struct TarExtractorTests {
    @Test("extract regular files and directories")
    func extractRegularFilesAndDirectories() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()
        writer.appendDir(path: root.archivePath("subdir"))

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: root.archivePath("subdir/hello.txt"),
            data: Array("hello\n".utf8)
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let extractor = TarExtractor()
            let result = try extractor.extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 2)
            #expect(result.skippedEntries == 0)

            let extractedPath = destination.path("subdir/hello.txt")
            let data = try Data(contentsOf: extractedPath)
            #expect(String(decoding: data, as: UTF8.self) == "hello\n")
            #expect(FileManager.default.fileExists(atPath: destination.path("subdir").path))
        }
    }

    @Test("extract symlinks and hard links")
    func extractLinks() throws {
        #if os(Windows) || os(WASI)
            return
        #else
            let root = try makeTemporaryExtractionRoot()
            var writer = TarWriter()

            var fileHeader = Header(asGnu: ())
            fileHeader.entryType = .regular
            fileHeader.setMode(0o644)
            writer.appendData(
                header: fileHeader,
                path: root.archivePath("target.txt"),
                data: Array("payload".utf8)
            )

            var symlinkHeader = Header(asGnu: ())
            symlinkHeader.entryType = .symlink
            symlinkHeader.setMode(0o777)
            writer.appendLink(
                header: symlinkHeader,
                path: root.archivePath("link.txt"),
                target: root.archivePath("target.txt")
            )

            var hardLinkHeader = Header(asGnu: ())
            hardLinkHeader.entryType = .link
            hardLinkHeader.setMode(0o644)
            writer.appendLink(
                header: hardLinkHeader,
                path: root.archivePath("hard.txt"),
                target: root.archivePath("target.txt")
            )

            let archive = Archive(data: writer.finish())
            try withTemporaryExtractionRoot(root) { destination in
                let extractor = TarExtractor()
                let result = try extractor.extract(archive, to: destination.root.path)
                #expect(result.extractedEntries == 3)
                #expect(result.skippedEntries == 0)

                let symlinkDestination = destination.path("link.txt")
                let hardLinkDestination = destination.path("hard.txt")
                #expect(
                    try readSymbolicLink(at: symlinkDestination.path)
                        == root.archivePath("target.txt"))
                let hardLinkData = try Data(contentsOf: hardLinkDestination)
                #expect(String(decoding: hardLinkData, as: UTF8.self) == "payload")
            }
        #endif
    }

    @Test("skip entries with parent directory traversal")
    func skipTraversalEntries() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "../evil.txt", data: Array("bad".utf8))

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let extractor = TarExtractor()
            let result = try extractor.extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 0)
            #expect(result.skippedEntries == 1)
            #expect(
                !FileManager.default.fileExists(
                    atPath: destination.root.deletingLastPathComponent().appending(path: "evil.txt")
                        .path))
        }
    }

    @Test("strip leading slash during extraction")
    func stripLeadingSlash() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: "/\(root.prefix)/nested/file.txt",
            data: Array("ok".utf8)
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let extractor = TarExtractor()
            let result = try extractor.extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 1)
            #expect(result.skippedEntries == 0)
            let data = try Data(contentsOf: destination.path("nested/file.txt"))
            #expect(String(decoding: data, as: UTF8.self) == "ok")
        }
    }

    @Test("extract streamingly from TarReader")
    func extractStreaminglyFromTarReader() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()
        writer.appendDir(path: root.archivePath("subdir"))

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: root.archivePath("subdir/hello.txt"),
            data: Array("hello\n".utf8)
        )

        let archiveData = writer.finish()

        try withTemporaryExtractionRoot(root) { destination in
            var reader = TarReader()
            var extractor = try TarExtractor().streamingExtractor(to: destination.root.path)

            var offset = 0
            while offset < archiveData.count {
                let end = min(offset + 13, archiveData.count)
                let events = try reader.append(archiveData[offset..<end])
                try extractor.consume(events)
                offset = end
            }

            let finalEvents = try reader.finish()
            try extractor.consume(finalEvents)
            let result = try extractor.finish()

            #expect(result.extractedEntries == 2)
            #expect(result.skippedEntries == 0)

            let extractedPath = destination.path("subdir/hello.txt")
            let data = try Data(contentsOf: extractedPath)
            #expect(String(decoding: data, as: UTF8.self) == "hello\n")
        }
    }

    @Test("extract streamingly from file path")
    func extractStreaminglyFromFilePath() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: root.archivePath("hello.txt"),
            data: Array("hello from file".utf8)
        )

        let archiveData = Data(writer.finish())
        let archivePath = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString + ".tar")
        try archiveData.write(to: archivePath)
        defer { try? FileManager.default.removeItem(at: archivePath) }

        try withTemporaryExtractionRoot(root) { destination in
            var extractor = try TarExtractor().streamingExtractor(to: destination.root.path)
            try extractor.consume(contentsOfFileAtPath: archivePath.path, chunkSize: 7)
            let result = try extractor.finish()

            #expect(result.extractedEntries == 1)
            #expect(result.skippedEntries == 0)
            let extracted = try Data(contentsOf: destination.path("hello.txt"))
            #expect(String(decoding: extracted, as: UTF8.self) == "hello from file")
        }
    }

    @Test("streaming extractor rejects invalid call order")
    func streamingExtractorRejectsInvalidCallOrder() throws {
        let root = try makeTemporaryExtractionRoot()
        try withTemporaryExtractionRoot(root) { destination in
            var extractor = try TarExtractor().streamingExtractor(to: destination.root.path)

            #expect(throws: TarError.self) {
                try extractor.consume(.data([1, 2, 3]))
            }
            #expect(throws: TarError.self) {
                try extractor.consume(.entryEnd)
            }
            #expect(throws: TarError.self) {
                try extractor.consume(contentsOfFileAtPath: destination.root.path, chunkSize: 0)
            }

            let result = try extractor.finish()
            #expect(result.extractedEntries == 0)
            #expect(result.skippedEntries == 0)

            #expect(throws: TarError.self) {
                try extractor.finish()
            }
            #expect(throws: TarError.self) {
                try extractor.consume(.entryEnd)
            }
        }
    }

    @Test("overwrite existing file when enabled")
    func overwriteExistingFileWhenEnabled() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: root.archivePath("hello.txt"),
            data: Array("new".utf8)
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            try FileManager.default.createDirectory(
                at: destination.path(""),
                withIntermediateDirectories: true
            )
            try Data("old".utf8).write(to: destination.path("hello.txt"))

            let result = try TarExtractor(overwrite: true).extract(
                archive, to: destination.root.path)
            #expect(result.extractedEntries == 1)

            let extracted = try Data(contentsOf: destination.path("hello.txt"))
            #expect(String(decoding: extracted, as: UTF8.self) == "new")
        }
    }

    @Test("reject overwrite when disabled")
    func rejectOverwriteWhenDisabled() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: root.archivePath("hello.txt"),
            data: Array("new".utf8)
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            try FileManager.default.createDirectory(
                at: destination.path(""),
                withIntermediateDirectories: true
            )
            try Data("old".utf8).write(to: destination.path("hello.txt"))

            #expect(throws: TarError.self) {
                try TarExtractor(overwrite: false).extract(archive, to: destination.root.path)
            }
        }
    }

    @Test("reject extraction through symlinked parent")
    func rejectExtractionThroughSymlinkedParent() throws {
        #if os(Windows) || os(WASI)
            return
        #else
            let root = try makeTemporaryExtractionRoot()
            var writer = TarWriter()

            var header = Header(asGnu: ())
            header.entryType = .regular
            header.setMode(0o644)
            writer.appendData(
                header: header,
                path: root.archivePath("linked/hello.txt"),
                data: Array("payload".utf8)
            )

            let archive = Archive(data: writer.finish())
            try withTemporaryExtractionRoot(root) { destination in
                try FileManager.default.createDirectory(
                    at: destination.path(""),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: destination.path("linked"),
                    withDestinationURL: destination.root
                )

                #expect(throws: TarError.self) {
                    try TarExtractor().extract(archive, to: destination.root.path)
                }
            }
        #endif
    }

    @Test("skip unsupported entry kinds and malformed links")
    func skipUnsupportedEntriesAndMalformedLinks() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var charHeader = Header(asGnu: ())
        charHeader.entryType = .char
        charHeader.setMode(0o644)
        writer.appendData(
            header: charHeader, path: root.archivePath("char-device"), data: [UInt8]())

        var symlinkHeader = Header(asGnu: ())
        symlinkHeader.entryType = .symlink
        symlinkHeader.setMode(0o777)
        writer.appendData(
            header: symlinkHeader, path: root.archivePath("empty-link"), data: [UInt8]())

        var hardLinkHeader = Header(asGnu: ())
        hardLinkHeader.entryType = .link
        hardLinkHeader.setMode(0o644)
        writer.appendLink(
            header: hardLinkHeader,
            path: root.archivePath("missing-hardlink"),
            target: root.archivePath("missing-target")
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let result = try TarExtractor().extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 0)
            #expect(result.skippedEntries == 3)
        }
    }

    @Test("skips hard link when target path contains traversal")
    func skipHardLinkWithTraversalTarget() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var hardLinkHeader = Header(asGnu: ())
        hardLinkHeader.entryType = .link
        // Target with ".." causes sanitizedComponents to return nil -> skipped.
        writer.appendLink(
            header: hardLinkHeader,
            path: root.archivePath("hard.txt"),
            target: "../escape/file.txt"
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let result = try TarExtractor().extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 0)
            #expect(result.skippedEntries == 1)
        }
    }

    @Test("strip leading dot path component during extraction")
    func stripLeadingDotPathComponent() throws {
        let root = try makeTemporaryExtractionRoot()
        var writer = TarWriter()

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(
            header: header,
            path: "./\(root.archivePath("nested/file.txt"))",
            data: Array("ok".utf8)
        )

        let archive = Archive(data: writer.finish())
        try withTemporaryExtractionRoot(root) { destination in
            let result = try TarExtractor().extract(archive, to: destination.root.path)
            #expect(result.extractedEntries == 1)
            #expect(result.skippedEntries == 0)
            let data = try Data(contentsOf: destination.path("nested/file.txt"))
            #expect(String(decoding: data, as: UTF8.self) == "ok")
        }
    }
}

private struct TemporaryExtractionRoot {
    let root: URL
    let prefix: String

    func archivePath(_ relativePath: String) -> String {
        "\(prefix)/\(relativePath)"
    }

    func path(_ relativePath: String) -> URL {
        root.appending(path: "\(prefix)/\(relativePath)")
    }
}

private func makeTemporaryExtractionRoot() throws -> TemporaryExtractionRoot {
    let prefix = "tmp-tarextract-\(UUID().uuidString)"
    #if os(WASI)
        return TemporaryExtractionRoot(root: URL(fileURLWithPath: "."), prefix: prefix)
    #else
        let root = FileManager.default.temporaryDirectory.appending(path: prefix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TemporaryExtractionRoot(root: root, prefix: "archive-root")
    #endif
}

private func withTemporaryExtractionRoot(
    _ temporaryRoot: TemporaryExtractionRoot,
    _ body: (TemporaryExtractionRoot) throws -> Void
) throws {
    #if os(WASI)
        defer {
            try? FileManager.default.removeItem(
                at: temporaryRoot.root.appending(path: temporaryRoot.prefix))
        }
    #else
        defer { try? FileManager.default.removeItem(at: temporaryRoot.root) }
    #endif
    try body(temporaryRoot)
}

private func readSymbolicLink(at path: String) throws -> String {
    #if os(Windows)
        return try FileManager.default.destinationOfSymbolicLink(atPath: path)
    #else
        var buffer = [UInt8](repeating: 0, count: 1024)
        let length = buffer.withUnsafeMutableBufferPointer { storage in
            guard let baseAddress = storage.baseAddress else { return -1 }
            return path.withCString { pointer in
                readlink(pointer, baseAddress, storage.count)
            }
        }
        guard length >= 0 else {
            throw TarError("failed to read symlink")
        }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    #endif
}
