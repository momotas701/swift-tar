import Foundation
import Testing

@testable import Tar

@Suite("Pax Parsing")
struct PaxExtensionsTests {
    @Test("parse simple extension")
    func parseSimple() throws {
        // PAX format: "<length> <key>=<value>\n" where length includes itself
        // "18 path=hello.txt\n" = 18 bytes
        let record = "18 path=hello.txt\n"
        let data = [UInt8](record.utf8)
        var iterator = PaxIterator(data: data[...])
        let ext = try #require(try iterator.nextExtension())
        #expect(ext.key == "path")
        #expect(ext.value == "hello.txt")
        #expect(try iterator.nextExtension() == nil)
    }

    @Test("parse multiple extensions")
    func parseMultiple() throws {
        // "18 path=hello.txt\n" = 18 bytes, "13 uid=1000\n" = 12 bytes
        let records = "18 path=hello.txt\n12 uid=1000\n"
        let data = [UInt8](records.utf8)
        var iterator = PaxIterator(data: data[...])
        var keys: [String] = []
        while let ext = try iterator.nextExtension() {
            keys.append(ext.key)
        }
        #expect(keys == ["path", "uid"])
    }

    @Test("empty data")
    func emptyData() throws {
        var iterator = PaxIterator(data: [][...])
        #expect(try iterator.nextExtension() == nil)
    }

    @Test("pax headers merge overlay values")
    func paxHeadersMergeOverlayValues() {
        var base = PaxHeaders()
        base[PaxKey.path] = "base.txt"
        base["uid"] = "123"

        var overlay = PaxHeaders()
        overlay[PaxKey.path] = "overlay.txt"
        overlay["gid"] = "456"

        base.merge(overlay)

        #expect(base[PaxKey.path] == "overlay.txt")
        #expect(base["uid"] == "123")
        #expect(base["gid"] == "456")
    }

    @Test("reject leading zero length")
    func rejectLeadingZeroLength() throws {
        var iterator = PaxIterator(data: [UInt8]("06 k=v\n".utf8)[...])
        try #require(throws: TarError.self) {
            _ = try iterator.nextExtension()
        }
    }

    @Test("reject too short length")
    func rejectTooShortLength() throws {
        var iterator = PaxIterator(data: [UInt8]("1 k=v\n".utf8)[...])
        try #require(throws: TarError.self) {
            _ = try iterator.nextExtension()
        }
    }

    @Test("reject empty key")
    func rejectEmptyKey() throws {
        var iterator = PaxIterator(data: [UInt8]("5 =\n".utf8)[...])
        try #require(throws: TarError.self) {
            _ = try iterator.nextExtension()
        }
    }

    @Test("reject NUL in path value")
    func rejectNulInPathValue() throws {
        var iterator = PaxIterator(data: [UInt8]("12 path=a\0\n".utf8)[...])
        try #require(throws: TarError.self) {
            _ = try iterator.nextExtension()
        }
    }
}
