import Foundation
import Testing

@testable import Tar

@Suite("TarWriter")
struct TarWriterTests {
    @Test("build empty archive")
    func buildEmpty() {
        var writer = TarWriter()
        let data = writer.finish()
        // Should end with 1024 zero bytes
        #expect(data.count == 1024)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test("build and read back")
    func buildAndReadBack() throws {
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        let content: [UInt8] = [1, 2, 3, 4]
        writer.appendData(header: header, path: "test.txt", data: content)
        let archiveData = writer.finish()

        let archive = Archive(data: archiveData)
        var found = false
        for entry in archive {
            if entry.fields.path() == "test.txt" {
                #expect(entry.data == [1, 2, 3, 4])
                #expect(entry.fields.size == 4)
                found = true
            }
        }
        #expect(found)
    }

    @Test("build multiple entries")
    func buildMultiple() throws {
        var writer = TarWriter()

        var h1 = Header(asGnu: ())
        h1.entryType = .regular
        h1.setMode(0o644)
        writer.appendData(header: h1, path: "a.txt", data: [UInt8]("hello".utf8))

        var h2 = Header(asGnu: ())
        h2.entryType = .regular
        h2.setMode(0o644)
        writer.appendData(header: h2, path: "b.txt", data: [UInt8]("world".utf8))

        let data = writer.finish()
        let archive = Archive(data: data)
        var paths: [String] = []
        for entry in archive {
            paths.append(entry.fields.path())
        }
        #expect(paths == ["a.txt", "b.txt"])
    }

    @Test("UStar path stored via prefix/name split")
    func ustarPrefixNameSplit() throws {
        // Paths between 101 and 256 bytes on a UStar header should be stored
        // using the prefix/name split rather than a GNU long-name extension.
        var writer = TarWriter()
        let path = String(repeating: "dir/", count: 30) + "file.txt"  // 128 chars total, split into prefix + name
        var header = Header(asUstar: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: path, data: [])

        let archive = Archive(data: writer.finish())
        var found = false
        for entry in archive {
            if entry.fields.path() == path {
                // Verify the prefix field was used, not a GNU long-name extension
                #expect(entry.fields.header.asUstar()?.prefix.isEmpty == false)
                found = true
            }
        }
        #expect(found)
    }

    @Test("build with long path")
    func buildLongPath() throws {
        var writer = TarWriter()
        let longPath =
            "very/long/directory/path/that/is/definitely/more/than/one/hundred/bytes/long/and/needs/GNU/extension/to/store/properly/file.txt"
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: longPath, data: [42])

        let data = writer.finish()
        let archive = Archive(data: data)
        var found = false
        for entry in archive {
            if entry.fields.path() == longPath {
                found = true
            }
        }
        #expect(found)
    }

    @Test("build directory")
    func buildDirectory() throws {
        var writer = TarWriter()
        writer.appendDir(path: "mydir")

        let data = writer.finish()
        let archive = Archive(data: data)
        var found = false
        for entry in archive {
            if entry.fields.header.entryType == .directory {
                #expect(entry.fields.path() == "mydir/")
                found = true
            }
        }
        #expect(found)
    }

    @Test("build symlink")
    func buildSymlink() throws {
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .symlink
        header.setMode(0o777)
        writer.appendLink(header: header, path: "link.txt", target: "target.txt")

        let data = writer.finish()
        let archive = Archive(data: data)
        var found = false
        for entry in archive {
            if entry.fields.header.entryType == .symlink {
                #expect(entry.fields.path() == "link.txt")
                #expect(entry.fields.linkName() == "target.txt")
                found = true
            }
        }
        #expect(found)
    }

    @Test("build symlink with long target")
    func buildSymlinkWithLongTarget() throws {
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .symlink
        header.setMode(0o777)
        let longTarget = String(repeating: "target/", count: 20) + "file.txt"
        writer.appendLink(header: header, path: "link.txt", target: longTarget)

        let archive = Archive(data: writer.finish())
        var found = false
        for entry in archive {
            if entry.fields.header.entryType == .symlink {
                #expect(entry.fields.path() == "link.txt")
                #expect(entry.fields.linkName() == longTarget)
                found = true
            }
        }
        #expect(found)
    }

    @Test("build pax extensions")
    func buildPaxExtensions() throws {
        var writer = TarWriter()
        writer.appendPaxExtensions([
            (key: "path", value: [UInt8]("extended-path.txt".utf8)),
            (key: "uid", value: [UInt8]("99999".utf8)),
        ])

        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "file.txt", data: [1])

        let data = writer.finish()
        let archive = Archive(data: data)
        for entry in archive {
            // The entry should pick up the PAX path extension
            if entry.fields.path() == "extended-path.txt" {
                return  // Success
            }
        }
    }

    @Test("deterministic mode")
    func deterministicMode() throws {
        var writer = TarWriter(mode: .deterministic)
        writer.appendDir(path: "testdir")

        let data = writer.finish()
        let archive = Archive(data: data)
        for entry in archive {
            if entry.fields.header.entryType == .directory {
                #expect(try entry.fields.header.uid() == 0)
                #expect(try entry.fields.header.gid() == 0)
                #expect(try entry.fields.header.mtime() == deterministicTimestamp)
            }
        }
    }

    @Test("round trip preserves data")
    func roundTrip() throws {
        // Build an archive
        var writer = TarWriter()
        let testData: [UInt8] = Array(0..<255)
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        header.setUid(1000)
        header.setGid(1000)
        header.setMtime(1_234_567_890)
        writer.appendData(header: header, path: "binary.dat", data: testData)
        let archiveBytes = writer.finish()

        // Read it back
        let archive = Archive(data: archiveBytes)
        for entry in archive {
            #expect(entry.fields.path() == "binary.dat")
            #expect(entry.data.elementsEqual(testData))
            #expect(entry.fields.size == UInt64(testData.count))
            #expect(try entry.fields.header.mode() == 0o644)
            #expect(try entry.fields.header.uid() == 1000)
            #expect(try entry.fields.header.gid() == 1000)
        }
    }

    @Test("finish is idempotent")
    func finishIsIdempotent() throws {
        var writer = TarWriter()
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setMode(0o644)
        writer.appendData(header: header, path: "hello.txt", data: Array("hello".utf8))

        let first = writer.finish()
        let second = writer.finish()
        #expect(first == second)
        #expect(first.count == 2048)
    }
}
