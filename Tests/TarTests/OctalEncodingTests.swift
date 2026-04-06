import Foundation
import Testing

@testable import Tar

@Suite("Octal Encoding")
struct OctalEncodingTests {
    @Test("read octal values")
    func readOctalValues() {
        // "0000755\0"
        let field: [UInt8] = [0x30, 0x30, 0x30, 0x30, 0x37, 0x35, 0x35, 0x00]
        #expect(decodeOctalField(field[0..<8]) == 0o755)
    }

    @Test("read octal with leading spaces")
    func readOctalLeadingSpaces() {
        // " 755\0"
        let field: [UInt8] = [0x20, 0x37, 0x35, 0x35, 0x00, 0x00, 0x00, 0x00]
        #expect(decodeOctalField(field[0..<8]) == 0o755)
    }

    @Test("write and read octal round trip")
    func writeReadRoundTrip() {
        var bytes = [UInt8](repeating: 0, count: 12)
        encodeOctalField(12345, into: &bytes, range: 0..<12)
        #expect(decodeOctalField(bytes[0..<12]) == 12345)
    }

    @Test("binary encoding for large values")
    func binaryEncoding() {
        var bytes = [UInt8](repeating: 0, count: 8)
        let largeVal: UInt64 = 0x1_FFFF_FFFF
        encodeOctalOrBinary(largeVal, into: &bytes, range: 0..<8)
        #expect(decodeOctalField(bytes[0..<8]) == largeVal)
    }

    @Test("GNU base-256 negative fields are rejected")
    func binaryNegativeRejected() {
        // Sign bit is bit 6 of the first byte (not only 0xFF).
        let c0: [UInt8] = [0xC0, 0, 0, 0, 0, 0, 0, 0]
        #expect(decodeOctalField(c0[0..<8]) == nil)
        let allFF: [UInt8] = [UInt8](repeating: 0xFF, count: 8)
        #expect(decodeOctalField(allFF[0..<8]) == nil)
    }

    @Test("octal overflow is rejected")
    func octalOverflowRejected() {
        // 23 octal digits of '7' exceeds UInt64.
        let field: [UInt8] = [
            0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x37,
            0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x37,
            0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x37, 0x00,
        ]
        #expect(decodeOctalField(field[0..<24]) == nil)
    }

    @Test("base-256 overflow is rejected")
    func base256OverflowRejected() {
        // Wider than a normal ustar field: enough base-256 payload to exceed UInt64.
        var b = [UInt8](repeating: 0xFF, count: 17)
        b[0] = 0x80
        #expect(decodeOctalField(b[0..<17]) == nil)
    }
}
