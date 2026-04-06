import Foundation
import Testing

@testable import Tar

@Suite("EntryType")
struct EntryTypeTests {
    @Test("byte round-trip")
    func byteRoundTrip() {
        let types: [EntryType] = [
            .regular, .link, .symlink, .char, .block,
            .directory, .fifo, .continuous, .gnuLongName,
            .gnuLongLink, .gnuSparse, .gnuVolumeLabel, .paxGlobalExtensions, .paxLocalExtensions,
        ]
        for t in types {
            #expect(EntryType(byte: t.byte) == t)
        }
    }

    @Test("null byte is regular")
    func nullByteIsRegular() {
        #expect(EntryType(byte: 0) == .regular)
    }

    @Test("unknown byte")
    func unknownByte() {
        let t = EntryType(byte: 0xFF)
        #expect(t.byte == 0xFF)
        if case .other(0xFF) = t {
        } else {
            Issue.record("Expected .other(0xFF)")
        }
    }
}
