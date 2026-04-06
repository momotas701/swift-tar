import Foundation
import Testing

@testable import Tar

@Suite("Header")
struct HeaderTests {
    @Test("GNU header creation")
    func gnuHeaderCreation() {
        let header = Header(asGnu: ())
        #expect(header.isGnu)
        #expect(!header.isUstar)
        #expect(header.asBytes().count == 512)
    }

    @Test("UStar header creation")
    func ustarHeaderCreation() {
        let header = Header(asUstar: ())
        #expect(header.isUstar)
        #expect(!header.isGnu)
    }

    @Test("old header creation")
    func oldHeaderCreation() {
        let header = Header(asOldV7: ())
        #expect(!header.isUstar)
        #expect(!header.isGnu)
    }

    @Test("set and get size")
    func setGetSize() throws {
        var header = Header(asGnu: ())
        header.setSize(12345)
        #expect(try header.entrySize() == 12345)
    }

    @Test("set and get mode")
    func setGetMode() throws {
        var header = Header(asGnu: ())
        header.setMode(0o755)
        #expect(try header.mode() == 0o755)
    }

    @Test("set and get uid/gid")
    func setGetUidGid() throws {
        var header = Header(asGnu: ())
        header.setUid(1000)
        header.setGid(1000)
        #expect(try header.uid() == 1000)
        #expect(try header.gid() == 1000)
    }

    @Test("set and get mtime")
    func setGetMtime() throws {
        var header = Header(asGnu: ())
        header.setMtime(1_234_567_890)
        #expect(try header.mtime() == 1_234_567_890)
    }

    @Test("set and get username")
    func setGetUsername() throws {
        var header = Header(asGnu: ())
        try header.setUsername("testuser")
        #expect(try header.username() == "testuser")
    }

    @Test("set and get groupname")
    func setGetGroupname() throws {
        var header = Header(asGnu: ())
        try header.setGroupname("testgroup")
        #expect(try header.groupname() == "testgroup")
    }

    @Test("set and get entry type")
    func setGetEntryType() {
        var header = Header(asGnu: ())
        header.entryType = .directory
        #expect(header.entryType == .directory)
    }

    @Test("checksum")
    func checksum() throws {
        var header = Header(asGnu: ())
        header.setSize(100)
        header.setMode(0o644)
        header.entryType = .regular
        header.setChecksum()
        #expect(try header.validateChecksum())
    }

    @Test("path() decodes name field as string")
    func pathDecodesNameField() throws {
        var header = Header(asGnu: ())
        try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
            try h.setName(Array("hello.txt".utf8))
        }
        #expect(header.path() == "hello.txt")
    }

    @Test("usernameBytes returns field for UStar headers")
    func usernameBytesUstar() throws {
        var header = Header(asUstar: ())
        try header.setUsername("alice")
        #expect(header.usernameBytes() == Array("alice".utf8))
    }

    @Test("usernameBytes returns nil for V7 headers")
    func usernameBytesNilForV7() {
        let header = Header(asOldV7: ())
        #expect(header.usernameBytes() == nil)
    }

    @Test("setUsername throws for names longer than 32 bytes")
    func setUsernameTooLong() {
        var header = Header(asGnu: ())
        #expect(throws: TarError.self) {
            try header.setUsername(String(repeating: "a", count: 33))
        }
    }

    @Test("groupnameBytes returns field for UStar headers")
    func groupnameBytesUstar() throws {
        var header = Header(asUstar: ())
        try header.setGroupname("staff")
        #expect(header.groupnameBytes() == Array("staff".utf8))
    }

    @Test("groupnameBytes returns nil for V7 headers")
    func groupnameBytesNilForV7() {
        let header = Header(asOldV7: ())
        #expect(header.groupnameBytes() == nil)
    }

    @Test("setGroupname throws for names longer than 32 bytes")
    func setGroupnameTooLong() {
        var header = Header(asGnu: ())
        #expect(throws: TarError.self) {
            try header.setGroupname(String(repeating: "g", count: 33))
        }
    }

    @Test("deviceMajor and deviceMinor via GNU header")
    func deviceNumbersGnu() throws {
        var header = Header(asGnu: ())
        try header.setDeviceMajor(7)
        try header.setDeviceMinor(8)
        #expect(try header.deviceMajor() == 7)
        #expect(try header.deviceMinor() == 8)
    }

    @Test("deviceMajor and deviceMinor return nil for V7 headers")
    func deviceNumbersNilForV7() throws {
        let header = Header(asOldV7: ())
        #expect(try header.deviceMajor() == nil)
        #expect(try header.deviceMinor() == nil)
    }

    @Test("OldV7Header setName throws when name exceeds 100 bytes")
    func oldV7SetNameTooLong() {
        var header = Header(asOldV7: ())
        #expect(throws: TarError.self) {
            try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
                try h.setName(Array(repeating: UInt8(ascii: "a"), count: 101))
            }
        }
    }

    @Test("OldV7Header decode throws for invalid octal in mode, uid, gid, size")
    func oldV7InvalidOctalFields() {
        // Build a header with 0xFF in each numeric field so decodeOctalField returns nil.
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[100] = 0xFF  // mode field
        bytes[108] = 0xFF  // uid field
        bytes[116] = 0xFF  // gid field
        bytes[124] = 0xFF  // size field
        let old = Header(bytes: bytes).asOldV7()
        #expect(throws: TarError.self) { try old.mode() }
        #expect(throws: TarError.self) { try old.uid() }
        #expect(throws: TarError.self) { try old.gid() }
        #expect(throws: TarError.self) { try old.size() }
    }

    @Test("link name")
    func linkName() throws {
        var header = Header(asGnu: ())
        try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
            try h.setLinkName(Array("target.txt".utf8))
        }
        #expect(header.linkName() == "target.txt")
    }

    @Test("zero block detection")
    func zeroBlock() {
        let header = Header(bytes: [UInt8](repeating: 0, count: 512))
        #expect(header.isZero)
    }

    @Test("large uid with binary encoding")
    func largeUidBinary() throws {
        var header = Header(asGnu: ())
        let largeUid: UInt64 = 0x1_FFFF_FFFF  // too large for 8-byte octal
        header.setUid(largeUid)
        #expect(try header.uid() == largeUid)
    }

    @Test("GNU header views")
    func gnuHeaderViews() throws {
        var header = Header(asGnu: ())
        #expect(header.asGnu() != nil)
        #expect(header.asUstar() == nil)

        var gnu = header.asGnu()!
        gnu.setRealSize(999)
        // Need to copy back
        header = Header(bytes: gnu.bytes)
        let gnu2 = header.asGnu()!
        #expect(try gnu2.realSize() == 999)
    }

    @Test("old header view exposes base fields")
    func oldHeaderView() throws {
        var header = Header(asOldV7: ())
        try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
            try h.setName(Array("plain.txt".utf8))
        }
        header.setMode(0o600)
        header.setUid(12)
        header.setGid(34)
        header.setSize(56)
        header.setMtime(78)
        header.entryType = .link
        try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
            try h.setLinkName(Array("target.txt".utf8))
        }
        header.setChecksum()

        let old = header.asOldV7()
        #expect(String(decoding: old.name, as: UTF8.self) == "plain.txt")
        #expect(try old.mode() == 0o600)
        #expect(try old.uid() == 12)
        #expect(try old.gid() == 34)
        #expect(try old.size() == 56)
        #expect(try old.mtime() == 78)
        #expect(try old.checksum() == header.computeChecksum())
        #expect(old.entryType == .link)
        #expect(String(decoding: old.linkName(), as: UTF8.self) == "target.txt")
    }

    @Test("header device numbers and views")
    func headerDeviceNumbersAndViews() throws {
        var ustar = Header(asUstar: ())
        try ustar.setDeviceMajor(12)
        try ustar.setDeviceMinor(34)
        try ustar.setUsername("user")
        try ustar.setGroupname("group")

        #expect(try ustar.deviceMajor() == 12)
        #expect(try ustar.deviceMinor() == 34)

        let ustarView = try #require(ustar.asUstar())
        #expect(ustarView.magic == Array("ustar\0".utf8))
        #expect(ustarView.version == Array("00".utf8))
        #expect(String(decoding: ustarView.username, as: UTF8.self) == "user")
        #expect(String(decoding: ustarView.groupname, as: UTF8.self) == "group")
        #expect(try ustarView.deviceMajor() == 12)
        #expect(try ustarView.deviceMinor() == 34)

        var gnu = Header(asGnu: ())
        try gnu.setDeviceMajor(56)
        try gnu.setDeviceMinor(78)
        try gnu.setUsername("gnuuser")
        try gnu.setGroupname("gnugroup")

        let gnuView = try #require(gnu.asGnu())
        #expect(gnuView.magic == Array("ustar ".utf8))
        #expect(gnuView.version == [UInt8(ascii: " "), 0])
        #expect(String(decoding: gnuView.username, as: UTF8.self) == "gnuuser")
        #expect(String(decoding: gnuView.groupname, as: UTF8.self) == "gnugroup")
        #expect(try gnuView.deviceMajor() == 56)
        #expect(try gnuView.deviceMinor() == 78)
    }

    @Test("old header rejects extended fields")
    func oldHeaderRejectsExtendedFields() {
        var header = Header(asOldV7: ())
        #expect(throws: TarError.self) {
            try header.setUsername("user")
        }
        #expect(throws: TarError.self) {
            try header.setGroupname("group")
        }
        #expect(throws: TarError.self) {
            try header.setDeviceMajor(1)
        }
        #expect(throws: TarError.self) {
            try header.setDeviceMinor(2)
        }
    }

    @Test("GNU sparse helpers")
    func gnuSparseHelpers() throws {
        var sparse = GnuSparseHeader()
        #expect(sparse.isEmpty)
        sparse.setOffset(123)
        sparse.setLength(456)
        #expect(try sparse.offset() == 123)
        #expect(try sparse.length() == 456)
        #expect(!sparse.isEmpty)

        var gnu = Header(asGnu: ())
        var gnuView = try #require(gnu.asGnu())
        gnuView.setAtime(11)
        gnuView.setCtime(22)
        gnuView.setIsExtended(true)
        gnuView.setRealSize(789)
        gnu = Header(bytes: gnuView.bytes)
        gnu.entryType = .gnuSparse

        let reread = try #require(gnu.asGnu())
        #expect(try reread.atime() == 11)
        #expect(try reread.ctime() == 22)
        #expect(reread.isExtended)
        #expect(reread.sparseHeaders().count == 4)
        #expect(try gnu.size() == 789)
    }

    @Test("pax extension hasKey helper")
    func paxExtensionHasKey() throws {
        var iterator = PaxIterator(
            data: encodePaxData([
                (key: "path", value: [UInt8]("value".utf8))
            ])[...]
        )
        let ext = try #require(try iterator.nextExtension())
        #expect(ext.hasKey(.path))
    }

    @Test("decodeOctalField returns nil for non-octal ASCII digit")
    func decodeOctalFieldNonOctalDigit() {
        // '8' and '9' are outside the valid octal range 0-7 and must trigger
        // the invalid-digit branch in decodeOctalField (the octal path, not
        // the base-256 path triggered by 0xFF).
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[100] = UInt8(ascii: "8")  // mode field offset 100
        let old = Header(bytes: bytes).asOldV7()
        #expect(throws: TarError.self) { try old.mode() }
    }

    @Test("Header.size returns entrySize for non-sparse headers")
    func headerSizeNonSparse() throws {
        var header = Header(asGnu: ())
        header.entryType = .regular
        header.setSize(99)
        #expect(try header.size() == 99)
    }

    @Test("OldV7Header mtime throws for invalid octal")
    func oldV7MtimeInvalid() {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[136] = UInt8(ascii: "9")  // mtime field starts at offset 136
        let old = Header(bytes: bytes).asOldV7()
        #expect(throws: TarError.self) { try old.mtime() }
    }

    @Test("OldV7Header checksum throws for invalid octal and overflow")
    func oldV7ChecksumInvalidAndOverflow() {
        // Invalid octal
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[148] = UInt8(ascii: "9")  // checksum field starts at offset 148
        #expect(throws: TarError.self) { try Header(bytes: bytes).asOldV7().checksum() }

        // base-256 encode a value > UInt32.max into the checksum field (148..156)
        var bytes2 = [UInt8](repeating: 0, count: 512)
        bytes2[148] = 0x80  // base-256 marker
        bytes2[151] = 0x01  // sets bit at position 32 -> decoded value = 4_294_967_296 > UInt32.max
        #expect(throws: TarError.self) { try Header(bytes: bytes2).asOldV7().checksum() }
    }

    @Test("OldV7Header setLinkName throws when link name exceeds 100 bytes")
    func oldV7SetLinkNameTooLong() {
        var header = Header(asOldV7: ())
        #expect(throws: TarError.self) {
            try header.withMutatingOldV7 { (h: inout OldV7Header) throws(TarError) in
                try h.setLinkName(Array(repeating: UInt8(ascii: "a"), count: 101))
            }
        }
    }

    @Test("UstarHeader setPrefix throws when prefix exceeds 155 bytes")
    func ustarSetPrefixTooLong() {
        var header = Header(asUstar: ())
        #expect(throws: TarError.self) {
            try header.withMutatingUstar { (u: inout UstarHeader) throws(TarError) in
                try u.setPrefix(Array(repeating: UInt8(ascii: "a"), count: 156))
            }
        }
    }

    @Test("GnuHeader atime and ctime throw for invalid octal")
    func gnuHeaderAtimeCtimeInvalid() {
        let header = Header(asGnu: ())
        var view = header.asGnu()!
        view.bytes[345] = UInt8(ascii: "9")  // first byte of atime field (345..357)
        view.bytes[357] = UInt8(ascii: "9")  // first byte of ctime field (357..369)
        #expect(throws: TarError.self) { try view.atime() }
        #expect(throws: TarError.self) { try view.ctime() }
    }

    @Test("GnuHeader offset and longnames are accessible")
    func gnuHeaderOffsetAndLongnames() throws {
        let view = try #require(Header(asGnu: ()).asGnu())
        // All-zero fields decode as 0
        #expect(try view.offset() == 0)
        #expect(view.longnames.count == 4)
    }

    @Test("GnuHeader realSize throws for invalid octal")
    func gnuHeaderRealSizeInvalid() {
        var view = Header(asGnu: ()).asGnu()!
        view.bytes[483] = UInt8(ascii: "9")  // first byte of realSize field (483..495)
        #expect(throws: TarError.self) { try view.realSize() }
    }

    @Test("GnuSparseHeader offset and length throw for invalid octal")
    func gnuSparseHeaderErrors() {
        var sparse = GnuSparseHeader()
        sparse.bytes[0] = UInt8(ascii: "9")  // first byte of offset field (0..12)
        sparse.bytes[12] = UInt8(ascii: "9")  // first byte of length field (12..24)
        #expect(throws: TarError.self) { try sparse.offset() }
        #expect(throws: TarError.self) { try sparse.length() }
    }

    @Test("PaxKey mtime atime ctime schilyXattr static vars")
    func paxKeyTimestampAndSchilyVars() throws {
        // Record format: "<total_length> <key>=<value>\n", length includes itself.
        // "15 mtime=12345\n" = 2 (len digits) + 1 (space) + 5 (mtime) + 1 (=) + 5 (value) + 1 (\n) = 15
        var mtimeIterator = PaxIterator(data: [UInt8]("15 mtime=12345\n".utf8)[...])
        var atimeIterator = PaxIterator(data: [UInt8]("15 atime=99999\n".utf8)[...])
        var ctimeIterator = PaxIterator(data: [UInt8]("15 ctime=77777\n".utf8)[...])
        #expect(try mtimeIterator.nextExtension()?.hasKey(.mtime) == true)
        #expect(try mtimeIterator.nextExtension() == nil)
        #expect(try atimeIterator.nextExtension()?.hasKey(.atime) == true)
        #expect(try atimeIterator.nextExtension() == nil)
        #expect(try ctimeIterator.nextExtension()?.hasKey(.ctime) == true)
        #expect(try ctimeIterator.nextExtension() == nil)
        // schilyXattr matches exactly "SCHILY.xattr."
        #expect(PaxKey.schilyXattr.equals([UInt8]("SCHILY.xattr.".utf8)[...]))
    }

    @Test("device major and minor overflow UInt32")
    func deviceMajorMinorOverflow() {
        // Place a base-256 encoded value > UInt32.max in devmajor (329..337)
        // and devminor (337..345) fields of a GNU header.
        var view = Header(asGnu: ()).asGnu()!
        // bytes[329] = 0x80 (marker), bytes[332] = 0x01 -> value = 4,294,967,296 > UInt32.max
        view.bytes[329] = 0x80
        view.bytes[332] = 0x01
        view.bytes[337] = 0x80
        view.bytes[340] = 0x01
        #expect(throws: TarError.self) { try view.deviceMajor() }
        #expect(throws: TarError.self) { try view.deviceMinor() }
    }
}

extension PaxExtension {
    fileprivate func hasKey(_ key: PaxKey) -> Bool {
        self.key == key.value
    }
}
