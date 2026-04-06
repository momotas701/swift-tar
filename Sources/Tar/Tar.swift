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
//
// Tar.swift - A library for reading and writing TAR archives in pure Swift.
// Foundation-free, compatible with Embedded Swift, and all Swift-supported
// platforms.
//
// Reference:
// - POSIX.1-2024: https://pubs.opengroup.org/onlinepubs/9799919799/
// - GNU tar: https://www.gnu.org/software/tar/manual/html_node/Standard.html
//
//===----------------------------------------------------------------------===//

// MARK: - TarError

/// An error from the tar library.
public struct TarError: Error, Sendable, CustomStringConvertible {
    /// A human-readable description of the error.
    public var message: String
    /// Creates a new error with the given message.
    public init(_ message: String) {
        self.message = message
    }
    public var description: String { message }
}

// MARK: - EntryType

/// Indicates the type of file described by a tar header (known as "typeflag" in POSIX.1-2024).
public enum EntryType: Sendable, Equatable {
    /// Regular file
    case regular
    /// Hard link
    case link
    /// Symbolic link
    case symlink
    /// Character device
    case char
    /// Block device
    case block
    /// Directory
    case directory
    /// Named pipe (FIFO)
    case fifo
    /// Implementation-defined 'high-performance' type, treated as regular file
    case continuous
    /// GNU extension - long file name
    case gnuLongName
    /// GNU extension - long link name
    case gnuLongLink
    /// GNU extension - sparse file
    case gnuSparse
    /// GNU extension - volume label (multi-volume archives; not a user-visible file entry)
    case gnuVolumeLabel
    /// Global extended header (PAX)
    case paxGlobalExtensions
    /// Local extended header (PAX)
    case paxLocalExtensions
    /// Other/unknown type
    case other(UInt8)

    // MARK: - Byte conversion

    /// Creates an entry type from a raw byte value.
    public init(byte: UInt8) {
        switch byte {
        case 0, UInt8(ascii: "0"): self = .regular
        case UInt8(ascii: "1"): self = .link
        case UInt8(ascii: "2"): self = .symlink
        case UInt8(ascii: "3"): self = .char
        case UInt8(ascii: "4"): self = .block
        case UInt8(ascii: "5"): self = .directory
        case UInt8(ascii: "6"): self = .fifo
        case UInt8(ascii: "7"): self = .continuous
        case UInt8(ascii: "x"): self = .paxLocalExtensions
        case UInt8(ascii: "g"): self = .paxGlobalExtensions
        case UInt8(ascii: "L"): self = .gnuLongName
        case UInt8(ascii: "K"): self = .gnuLongLink
        case UInt8(ascii: "S"): self = .gnuSparse
        case UInt8(ascii: "V"): self = .gnuVolumeLabel
        default: self = .other(byte)
        }
    }

    /// Returns the raw byte value for this entry type.
    public var byte: UInt8 {
        switch self {
        case .regular: return UInt8(ascii: "0")
        case .link: return UInt8(ascii: "1")
        case .symlink: return UInt8(ascii: "2")
        case .char: return UInt8(ascii: "3")
        case .block: return UInt8(ascii: "4")
        case .directory: return UInt8(ascii: "5")
        case .fifo: return UInt8(ascii: "6")
        case .continuous: return UInt8(ascii: "7")
        case .paxLocalExtensions: return UInt8(ascii: "x")
        case .paxGlobalExtensions: return UInt8(ascii: "g")
        case .gnuLongName: return UInt8(ascii: "L")
        case .gnuLongLink: return UInt8(ascii: "K")
        case .gnuSparse: return UInt8(ascii: "S")
        case .gnuVolumeLabel: return UInt8(ascii: "V")
        case .other(let b): return b
        }
    }
}

// MARK: - PAX Extensions

/// Well-known PAX extended header keys defined by POSIX.1-2001 and common
/// extensions. Use these constants when reading or writing PAX headers via
/// ``PaxExtensions`` to avoid typos and aid discoverability.
public struct PaxKey: Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    /// Checks if the key is equal to the given bytes.
    internal func equals(_ other: ArraySlice<UInt8>) -> Bool {
        value.utf8.count == other.count && value.utf8.elementsEqual(other)
    }

    public static func ~= (lhs: PaxKey, rhs: ArraySlice<UInt8>) -> Bool {
        lhs.equals(rhs)
    }

    /// Overrides the path stored in the base header.
    public static var path: PaxKey { PaxKey("path") }
    /// Overrides the link target stored in the base header.
    public static var linkpath: PaxKey { PaxKey("linkpath") }
    /// Overrides the file size stored in the base header.
    public static var size: PaxKey { PaxKey("size") }
    /// Overrides the numeric user ID stored in the base header.
    public static var uid: PaxKey { PaxKey("uid") }
    /// Overrides the numeric group ID stored in the base header.
    public static var gid: PaxKey { PaxKey("gid") }
    /// Overrides the user name stored in the base header.
    public static var uname: PaxKey { PaxKey("uname") }
    /// Overrides the group name stored in the base header.
    public static var gname: PaxKey { PaxKey("gname") }
    /// Overrides the modification time stored in the base header (seconds since epoch, may include fractional part).
    public static var mtime: PaxKey { PaxKey("mtime") }
    /// Access time (seconds since epoch, may include fractional part).
    public static var atime: PaxKey { PaxKey("atime") }
    /// Inode change time (seconds since epoch, may include fractional part).
    public static var ctime: PaxKey { PaxKey("ctime") }
    /// Prefix for SCHILY extended attributes (e.g. `"SCHILY.xattr.user.foo"`).
    public static var schilyXattr: PaxKey { PaxKey("SCHILY.xattr.") }
}

/// An iterator over PAX extended-header key/value pairs.
///
/// PAX format: each record is `<length> <key>=<value>\n` where length
/// includes the entire record including the length field, space, and newline.
public struct PaxHeaders: Sendable {
    /// The raw bytes of the PAX extended header data.
    var storage: [String: String]

    public init() {
        self.storage = [:]
    }

    internal var isEmpty: Bool {
        storage.isEmpty
    }

    public subscript(_ key: String) -> String? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    public subscript(_ key: PaxKey) -> String? {
        get { storage[key.value] }
        set { storage[key.value] = newValue }
    }

    public mutating func merge(_ overlay: PaxHeaders) {
        for (key, value) in overlay.storage {
            storage[key] = value
        }
    }
}

/// Iterator that yields ``PaxExtension`` values from PAX extended header data.
struct PaxIterator {
    let data: ArraySlice<UInt8>
    var offset: Int  // absolute index into data

    init(data: ArraySlice<UInt8>) {
        self.data = data
        self.offset = data.startIndex
    }

    /// Returns the next key/value pair, or `nil` when exhausted.
    ///
    /// Throws ``TarError`` when a malformed PAX record is encountered.
    mutating func nextExtension() throws(TarError) -> PaxExtension? {
        guard offset < data.endIndex else { return nil }
        return try parseRecord()
    }

    /// Parses a single PAX record starting at the current offset.
    ///
    /// > An extended header shall consist of one or more records, each constructed as follows:
    /// > "%d %s=%s\n", <length>, <keyword>, <value>
    /// POSIX.1-2024 - "pax Extended Header"
    ///
    /// Returns the parsed record and advances `offset`.
    private mutating func parseRecord() throws(TarError) -> PaxExtension {
        let recordStartOffset = offset
        let remaining = data[offset...]
        guard !remaining.isEmpty else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): unexpected end of extended header data"
            )
        }

        // Parse the decimal length prefix.
        guard let spaceIndex = remaining.firstIndex(of: UInt8(ascii: " ")),
            spaceIndex > remaining.startIndex
        else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): expected '<length> ' prefix"
            )
        }

        let lengthBytes = remaining[remaining.startIndex..<spaceIndex]
        guard let length = _parsePaxDecimal(lengthBytes) else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): length field is not a decimal integer"
            )
        }
        guard length >= 5 else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): length \(length) is below minimum PAX record size (5)"
            )
        }
        if lengthBytes.count > 1, lengthBytes.first == UInt8(ascii: "0") {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): length field has a leading zero"
            )
        }

        // Validate we have enough data and the record ends with '\n'.
        let recordEnd = offset + length
        guard length > 0, recordEnd <= data.endIndex else {
            let available = data.endIndex - offset
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): declared length \(length) exceeds available data (\(available) byte\(available == 1 ? "" : "s"))"
            )
        }
        guard data[recordEnd - 1] == UInt8(ascii: "\n") else {
            let last = data[recordEnd - 1]
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): record must end with newline, last byte is 0x\(Self._paxByteHex(last)) (declared length \(length))"
            )
        }

        // The payload sits between the space and the trailing newline.
        let payloadStart = spaceIndex + 1  // skip the space
        let payloadEnd = recordEnd - 1  // before the newline

        guard payloadStart < payloadEnd else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): empty key=value payload (declared length \(length))"
            )
        }

        let payload = data[payloadStart..<payloadEnd]

        // Split on the first '='.
        guard let equalsIndex = payload.firstIndex(of: UInt8(ascii: "=")) else {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): payload has no '='"
            )
        }

        let keyBytes = payload[payload.startIndex..<equalsIndex]
        let valueBytes = payload[(equalsIndex + 1)..<payload.endIndex]
        if let reason = _validatePaxRecord(
            keyBytes: keyBytes, valueBytes: valueBytes)
        {
            throw TarError(
                "malformed PAX record at byte \(recordStartOffset): invalid key/value (\(reason))"
            )
        }

        offset = recordEnd
        return PaxExtension(keyBytes: keyBytes, valueBytes: valueBytes)
    }

    private static func _paxByteHex(_ b: UInt8) -> String {
        let s = String(b, radix: 16)
        return s.count == 1 ? "0" + s : s
    }

    /// Validates a PAX record key and value.
    ///
    /// Returns a human-readable reason for validation failure, or `nil` if the record is valid.
    private func _validatePaxRecord(
        keyBytes: ArraySlice<UInt8>,
        valueBytes: ArraySlice<UInt8>
    ) -> String? {
        guard !keyBytes.isEmpty else { return "empty key" }
        guard !keyBytes.contains(UInt8(ascii: "=")) else { return "key contains '='" }

        switch keyBytes {
        case PaxKey.path, PaxKey.linkpath,
            PaxKey.uname, PaxKey.gname:
            if valueBytes.contains(0) { return "value contains NUL byte" }
            return nil
        default:
            if keyBytes.contains(0) { return "key contains NUL byte" }
            return nil
        }
    }

    /// Parse ASCII decimal digits into an `Int`.
    private func _parsePaxDecimal(_ bytes: some Collection<UInt8>) -> Int? {
        var result = 0
        for b in bytes {
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else {
                return nil
            }
            // Overflow check
            let (r1, o1) = result.multipliedReportingOverflow(by: 10)
            guard !o1 else { return nil }
            let (r2, o2) = r1.addingReportingOverflow(Int(b - UInt8(ascii: "0")))
            guard !o2 else { return nil }
            result = r2
        }
        return result
    }
}

/// A single PAX extended-header key/value pair.
internal struct PaxExtension: Sendable {
    /// The raw bytes of the key.
    internal let keyBytes: ArraySlice<UInt8>
    /// The raw bytes of the value.
    internal let valueBytes: ArraySlice<UInt8>

    /// The key as a `String`, decoded as UTF-8.
    internal var key: String {
        String(decoding: keyBytes, as: UTF8.self)
    }

    /// The value as a `String`, decoded as UTF-8.
    internal var value: String {
        String(decoding: valueBytes, as: UTF8.self)
    }
}

// MARK: - Header Field Codecs
// Implements POSIX.1-2017 and later (UStar) and GNU tar octal / base-256 field encoding.
// Field layouts defined in IEEE Std 1003.1 (Issue 8 / POSIX.1-2024), Sec. 10.1.1 (ustar interchange format).

/// Decode an octal (or GNU base-256) numeric field from a header byte slice.
/// Returns `nil` if the field contains invalid data.
internal func decodeOctalField(_ field: ArraySlice<UInt8>) -> UInt64? {
    if field.isEmpty { return nil }

    let first = field[field.startIndex]

    // GNU base-256 encoding: high bit of first byte is set.
    if first & 0x80 != 0 {
        // Bit 6 is the sign bit (two's complement); negative values are not represented as UInt64.
        if first & 0x40 != 0 {
            return nil
        }
        var val: UInt64 = UInt64(first & 0x7F)
        for i in (field.startIndex + 1)..<field.endIndex {
            if (val >> 56) != 0 {
                return nil
            }
            val = val &<< 8 | UInt64(field[i])
        }
        return val
    }

    // Standard octal ASCII, skip leading spaces.
    var val: UInt64 = 0
    var started = false
    for i in field.indices {
        let b = field[i]
        if b == 0 {
            break
        }
        if b == UInt8(ascii: " ") {
            if started { break }
            continue  // skip leading spaces
        }
        guard b >= UInt8(ascii: "0") && b <= UInt8(ascii: "7") else {
            return nil
        }
        started = true
        let digit = UInt64(b &- UInt8(ascii: "0"))
        let (mul, overflowMul) = val.multipliedReportingOverflow(by: 8)
        if overflowMul { return nil }
        let (next, overflowAdd) = mul.addingReportingOverflow(digit)
        if overflowAdd { return nil }
        val = next
    }
    return val
}

/// Encode a value as null-terminated octal ASCII into the given range of `bytes`.
/// Format: zero-padded on the left, last byte is NUL.
internal func encodeOctalField(_ value: UInt64, into bytes: inout [UInt8], range: Range<Int>) {
    // Fill with ASCII '0'
    for i in range { bytes[i] = UInt8(ascii: "0") }

    // Null terminator in last position
    bytes[range.upperBound - 1] = 0

    // Write octal digits right-to-left, leaving last byte as NUL
    var v = value
    var pos = range.upperBound - 2  // rightmost digit position

    while v > 0 && pos >= range.lowerBound {
        bytes[pos] = UInt8(ascii: "0") &+ UInt8(v & 0x7)
        v >>= 3
        pos -= 1
    }
}

/// Encode a potentially large value. Uses octal if the value fits; otherwise GNU base-256.
internal func encodeOctalOrBinary(
    _ value: UInt64, into bytes: inout [UInt8], range: Range<Int>
) {
    let width = range.count
    // Maximum value that fits in (width - 1) octal digits (last byte is NUL in octal mode).
    // Each octal digit is 3 bits, we have (width - 1) digit positions.
    // width == 1 implies maxBits == 0, so only 0 fits in octal; ustar headers do not use 1-byte numeric fields.
    let maxBits = 3 * (width - 1)
    let fitsInOctal: Bool
    if maxBits >= 64 {
        fitsInOctal = true
    } else {
        fitsInOctal = value < (1 << maxBits)
    }

    if fitsInOctal {
        encodeOctalField(value, into: &bytes, range: range)
    } else {
        // Base-256: (width - 1) data bytes after the 0x80 marker byte (GNU tar / star).
        let availableBits = (width - 1) * 8
        precondition(
            availableBits >= 64 || value < (1 as UInt64) << availableBits,
            "encodeOctalOrBinary: value does not fit in base-256 field of width \(width)"
        )
        // Base-256 encoding: set high bit on first byte, big-endian value
        for i in range { bytes[i] = 0 }
        bytes[range.lowerBound] = 0x80
        var v = value
        var pos = range.upperBound - 1
        while pos > range.lowerBound {
            bytes[pos] = UInt8(v & 0xFF)
            v >>= 8
            pos -= 1
        }
    }
}

/// Extract bytes up to (but not including) the first null byte from a header field.
/// Returns the entire slice contents if no null terminator is found.
internal func decodeStringField(_ field: ArraySlice<UInt8>) -> [UInt8] {
    var end = field.endIndex
    for i in field.indices {
        if field[i] == 0 {
            end = i
            break
        }
    }
    return Array(field[field.startIndex..<end])
}

/// Encode bytes into a fixed-width header field, null-padding any remaining bytes.
/// If `value` is longer than the field, it is truncated on the right; callers must ensure paths fit.
internal func encodeStringField(
    _ value: [UInt8], into bytes: inout [UInt8], range: Range<Int>
) {
    for i in range { bytes[i] = 0 }
    let copyLen = min(value.count, range.count)
    for i in 0..<copyLen {
        bytes[range.lowerBound + i] = value[i]
    }
}

// MARK: - Path Splitting Helper

/// Try to split a path into (prefix, name) for UStar format.
///   prefix: up to 155 bytes
///   name:   up to 100 bytes
/// The split must occur at a `/` separator.
///
/// Trailing slashes on directory names (e.g. `some/dir/`) are common in tar; the rightmost `/`
/// yields an empty name, so the algorithm picks an earlier slash, giving e.g. prefix `some`, name `dir/`.
///
/// Paths beginning with `/` are rejected here (prefix length 0); archives normally use relative paths.
/// Returns nil if no valid split is possible.

// MARK: - Header

/// A 512-byte tar archive header.
public struct Header: Sendable {
    // TODO: Use a slice instead of a full block
    internal var _bytes: [UInt8]

    // MARK: Initializers

    /// Create a new GNU-format header.
    public init(asGnu: Void = ()) {
        _bytes = [UInt8](repeating: 0, count: Entry.blockSize)
        // magic: "ustar " (6 bytes, trailing space)
        _bytes[257] = 0x75  // u
        _bytes[258] = 0x73  // s
        _bytes[259] = 0x74  // t
        _bytes[260] = 0x61  // a
        _bytes[261] = 0x72  // r
        _bytes[262] = 0x20  // ' '
        // version: " \0"
        _bytes[263] = 0x20  // ' '
        _bytes[264] = 0x00  // NUL
    }

    /// Create a new UStar-format header.
    public init(asUstar: Void = ()) {
        _bytes = [UInt8](repeating: 0, count: Entry.blockSize)
        // magic: "ustar\0" (6 bytes)
        _bytes[257] = 0x75  // u
        _bytes[258] = 0x73  // s
        _bytes[259] = 0x74  // t
        _bytes[260] = 0x61  // a
        _bytes[261] = 0x72  // r
        _bytes[262] = 0x00  // NUL
        // version: "00"
        _bytes[263] = 0x30  // '0'
        _bytes[264] = 0x30  // '0'
    }

    /// Create a new old-format (V7) header.
    public init(asOldV7: Void = ()) {
        _bytes = [UInt8](repeating: 0, count: Entry.blockSize)
    }

    /// Initialize from an existing 512-byte buffer.
    public init(bytes raw: [UInt8]) {
        precondition(
            raw.count == Entry.blockSize, "tar header must be exactly \(Entry.blockSize) bytes")
        self._bytes = raw
    }

    // MARK: Format Detection

    /// Whether the magic bytes indicate UStar format ("ustar\0").
    public var isUstar: Bool {
        _bytes[257] == 0x75 && _bytes[258] == 0x73 && _bytes[259] == 0x74
            && _bytes[260] == 0x61 && _bytes[261] == 0x72 && _bytes[262] == 0x00
    }

    /// Whether the magic bytes indicate GNU format ("ustar ").
    public var isGnu: Bool {
        _bytes[257] == 0x75 && _bytes[258] == 0x73 && _bytes[259] == 0x74
            && _bytes[260] == 0x61 && _bytes[261] == 0x72 && _bytes[262] == 0x20
    }

    /// Return an `OldV7Header` view of this header. Always succeeds.
    public func asOldV7() -> OldV7Header {
        OldV7Header(bytes: _bytes)
    }

    /// Mutate the V7 portion of the header in place.
    ///
    /// Provides an `inout OldV7Header` view to `body`, then writes the
    /// modified bytes back into the receiver. Always succeeds because every
    /// header has a valid V7 base layout.
    public mutating func withMutatingOldV7<R, E: Error>(
        _ body: (inout OldV7Header) throws(E) -> R
    ) throws(E) -> R {
        var oldV7 = asOldV7()
        let result = try body(&oldV7)
        _bytes = oldV7.bytes
        return result
    }

    /// Return a `UstarHeader` view if this header is UStar format.
    public func asUstar() -> UstarHeader? {
        guard isUstar else { return nil }
        return UstarHeader(bytes: _bytes)
    }

    /// Mutate the UStar-specific fields of the header in place.
    ///
    /// Provides an `inout UstarHeader` view to `body`, then writes the
    /// modified bytes back into the receiver. Returns `nil` without calling
    /// `body` if the header is not in UStar format.
    public mutating func withMutatingUstar<R, E: Error>(
        _ body: (inout UstarHeader) throws(E) -> R
    ) throws(E) -> R? {
        guard var ustar = asUstar() else { return nil }
        let result = try body(&ustar)
        _bytes = ustar.bytes
        return result
    }

    /// Return a `GnuHeader` view if this header is GNU format.
    public func asGnu() -> GnuHeader? {
        guard isGnu else { return nil }
        return GnuHeader(bytes: _bytes)
    }

    /// Mutate the GNU-specific fields of the header in place.
    ///
    /// Provides an `inout GnuHeader` view to `body`, then writes the
    /// modified bytes back into the receiver. Returns `nil` without calling
    /// `body` if the header is not in GNU format.
    public mutating func withMutatingGnu<R, E: Error>(
        _ body: (inout GnuHeader) throws(E) -> R
    ) throws(E) -> R? {
        guard var gnu = asGnu() else { return nil }
        let result = try body(&gnu)
        _bytes = gnu.bytes
        return result
    }

    // MARK: Entry Type

    /// The entry type (offset 156).
    public var entryType: EntryType {
        get { asOldV7().entryType }
        set { withMutatingOldV7 { $0.entryType = newValue } }
    }

    // MARK: Size

    /// The raw size field value.
    public func entrySize() throws(TarError) -> UInt64 {
        try asOldV7().size()
    }

    /// The logical size of the entry.
    /// For GNU sparse files this returns the real size; otherwise returns `entrySize()`.
    public func size() throws(TarError) -> UInt64 {
        if entryType == .gnuSparse, let gnu = asGnu() {
            return try gnu.realSize()
        }
        return try entrySize()
    }

    /// Set the size field (offset 124..136).
    public mutating func setSize(_ size: UInt64) {
        withMutatingOldV7 { $0.setSize(size) }
    }

    // MARK: Path

    /// Get the raw path bytes from the header.
    /// For UStar headers, combines the prefix and name fields.
    public func pathBytes() -> [UInt8] {
        let nameBytes = asOldV7().name
        if let utar = asUstar() {
            let prefixBytes = utar.prefix
            if !prefixBytes.isEmpty {
                return prefixBytes + [UInt8(ascii: "/")] + nameBytes
            }
        }
        return nameBytes
    }

    /// Get the path as a String.
    public func path() -> String {
        String(decoding: pathBytes(), as: UTF8.self)
    }

    // MARK: Link Name

    /// Get the raw link name bytes (offset 157..257).
    /// Returns `nil` if the link name field is empty.
    public func linkNameBytes() -> [UInt8] {
        return asOldV7().linkName()
    }

    /// Get the link name as a String, or `nil` if empty.
    public func linkName() -> String? {
        let raw = linkNameBytes()
        guard !raw.isEmpty else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    // MARK: Mode

    /// Get the file mode (offset 100..108).
    public func mode() throws(TarError) -> UInt32 {
        try asOldV7().mode()
    }

    /// Set the file mode (offset 100..108).
    public mutating func setMode(_ mode: UInt32) {
        withMutatingOldV7 { $0.setMode(mode) }
    }

    // MARK: UID / GID

    /// Get the owner user ID (offset 108..116).
    public func uid() throws(TarError) -> UInt64 {
        try asOldV7().uid()
    }

    /// Set the owner user ID (offset 108..116).
    public mutating func setUid(_ uid: UInt64) {
        withMutatingOldV7 { $0.setUid(uid) }
    }

    /// Get the owner group ID (offset 116..124).
    public func gid() throws(TarError) -> UInt64 {
        try asOldV7().gid()
    }

    /// Set the owner group ID (offset 116..124).
    public mutating func setGid(_ gid: UInt64) {
        withMutatingOldV7 { $0.setGid(gid) }
    }

    // MARK: Modification Time

    /// Get the modification time as a Unix timestamp (offset 136..148).
    public func mtime() throws(TarError) -> UInt64 {
        try asOldV7().mtime()
    }

    /// Set the modification time (offset 136..148).
    public mutating func setMtime(_ mtime: UInt64) {
        withMutatingOldV7 { $0.setMtime(mtime) }
    }

    // MARK: Username

    /// Get raw username bytes (offset 265..297, UStar/GNU only).
    /// Returns `nil` if the header format lacks this field or it is empty.
    public func usernameBytes() -> [UInt8]? {
        if let ustar = asUstar() {
            return ustar.username
        } else if let gnu = asGnu() {
            return gnu.username
        } else {
            return nil
        }
    }

    /// Get the username as a String.
    public func username() throws(TarError) -> String? {
        guard let raw = usernameBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Set the username (max 32 bytes). Throws if format doesn't support it.
    public mutating func setUsername(_ name: String) throws(TarError) {
        let utf8 = [UInt8](name.utf8)
        if utf8.count > 32 {
            throw TarError(
                "username is too long (\(utf8.count) bytes, max 32)")
        }
        if isUstar {
            try withMutatingUstar { (u: inout UstarHeader) throws(TarError) in
                try u.setUsername(utf8)
            }
        } else if isGnu {
            try withMutatingGnu { (g: inout GnuHeader) throws(TarError) in
                try g.setUsername(utf8)
            }
        } else {
            throw TarError("username field not supported in old (V7) tar format")
        }
    }

    // MARK: Group Name

    /// Get raw group name bytes (offset 297..329, UStar/GNU only).
    public func groupnameBytes() -> [UInt8]? {
        if let ustar = asUstar() {
            return ustar.groupname
        } else if let gnu = asGnu() {
            return gnu.groupname
        } else {
            return nil
        }
    }

    /// Get the group name as a String.
    public func groupname() throws(TarError) -> String? {
        guard let raw = groupnameBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Set the group name (max 32 bytes). Throws if format doesn't support it.
    public mutating func setGroupname(_ name: String) throws(TarError) {
        let utf8 = [UInt8](name.utf8)
        if utf8.count > 32 {
            throw TarError(
                "groupname is too long (\(utf8.count) bytes, max 32)")
        }
        if isUstar {
            try withMutatingUstar { (u: inout UstarHeader) throws(TarError) in
                try u.setGroupname(utf8)
            }
        } else if isGnu {
            try withMutatingGnu { (g: inout GnuHeader) throws(TarError) in
                try g.setGroupname(utf8)
            }
        } else {
            throw TarError("groupname field not supported in old (V7) tar format")
        }
    }

    // MARK: Device Major / Minor

    /// Get the device major number (offset 329..337, UStar/GNU only).
    /// Returns `nil` for old-format headers or if the field is all zeros.
    public func deviceMajor() throws(TarError) -> UInt32? {
        if let ustar = asUstar() {
            return try ustar.deviceMajor()
        } else if let gnu = asGnu() {
            return try gnu.deviceMajor()
        } else {
            return nil
        }
    }

    /// Set the device major number (offset 329..337).
    public mutating func setDeviceMajor(_ major: UInt32) throws(TarError) {
        guard isUstar || isGnu else {
            throw TarError(
                "device major field not supported in old (V7) tar format")
        }
        if isUstar {
            withMutatingUstar { $0.setDeviceMajor(major) }
        } else {
            withMutatingGnu { $0.setDeviceMajor(major) }
        }
    }

    /// Get the device minor number (offset 337..345, UStar/GNU only).
    /// Returns `nil` for old-format headers or if the field is all zeros.
    public func deviceMinor() throws(TarError) -> UInt32? {
        if let ustar = asUstar() {
            return try ustar.deviceMinor()
        } else if let gnu = asGnu() {
            return try gnu.deviceMinor()
        } else {
            return nil
        }
    }

    /// Set the device minor number (offset 337..345).
    public mutating func setDeviceMinor(_ minor: UInt32) throws(TarError) {
        if isUstar {
            withMutatingUstar { $0.setDeviceMinor(minor) }
        } else if isGnu {
            withMutatingGnu { $0.setDeviceMinor(minor) }
        } else {
            throw TarError("device minor field not supported in old (V7) tar format")
        }
    }

    // MARK: Checksum

    /// Compute the checksum over all 512 header bytes.
    /// The checksum field itself (offset 148..156) is treated as ASCII spaces.
    public func computeChecksum() -> UInt32 {
        asOldV7().computeChecksum()
    }

    /// Read the stored checksum value (offset 148..156).
    public func checksum() throws(TarError) -> UInt32 {
        try asOldV7().checksum()
    }

    /// Compute and write the correct checksum into the header.
    public mutating func setChecksum() {
        withMutatingOldV7 { $0.setChecksum() }
    }

    /// Validate the header checksum against the stored value.
    public func validateChecksum() throws(TarError) -> Bool {
        let stored = try checksum()
        return stored == computeChecksum()
    }

    // MARK: Bytes / Zeroed

    /// Return a copy of the raw 512 header bytes.
    public func asBytes() -> [UInt8] {
        _bytes
    }

    /// Whether the header is all zeros (end-of-archive marker).
    public var isZero: Bool {
        _bytes.allSatisfy { $0 == 0 }
    }
}

// MARK: - OldV7Header

/// View of a tar header in the old V7 / POSIX format.
/// All tar headers share this base layout for the first 257 bytes.
///
/// Old header fields:
///
/// | Field Name | Octet Offset | Length (in Octets) |
/// |------------|-------------:|-------------------:|
/// | name       |            0 |                100 |
/// | mode       |          100 |                  8 |
/// | uid        |          108 |                  8 |
/// | gid        |          116 |                  8 |
/// | size       |          124 |                 12 |
/// | mtime      |          136 |                 12 |
/// | chksum     |          148 |                  8 |
/// | typeflag   |          156 |                  1 |
/// | linkname   |          157 |                100 |
public struct OldV7Header: Sendable {
    /// The raw 512-byte header data.
    public var bytes: [UInt8]

    /// Creates a view over the given raw 512-byte header block.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == Entry.blockSize)
        self.bytes = bytes
    }

    /// Name field (0..100).
    public var name: [UInt8] {
        decodeStringField(bytes[0..<100])
    }

    /// Set the name field (0..100).
    public mutating func setName(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 100 else {
            throw TarError("name is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 0..<100)
    }

    /// Mode field (100..108).
    public func mode() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[100..<108]) else {
            throw TarError("invalid mode")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("mode value overflows UInt32")
        }
        return result
    }

    public mutating func setMode(_ mode: UInt32) {
        encodeOctalField(UInt64(mode), into: &bytes, range: 100..<108)
    }

    /// UID field (108..116).
    public func uid() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[108..<116]) else {
            throw TarError("invalid uid")
        }
        return v
    }

    /// GID field (116..124).
    public func gid() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[116..<124]) else {
            throw TarError("invalid gid")
        }
        return v
    }

    /// Set the UID field (108..116).
    public mutating func setUid(_ uid: UInt64) {
        encodeOctalOrBinary(uid, into: &bytes, range: 108..<116)
    }

    /// Set the GID field (116..124).
    public mutating func setGid(_ gid: UInt64) {
        encodeOctalOrBinary(gid, into: &bytes, range: 116..<124)
    }

    /// Size field (124..136).
    public func size() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[124..<136]) else {
            throw TarError("invalid size")
        }
        return v
    }

    public mutating func setSize(_ size: UInt64) {
        encodeOctalField(size, into: &bytes, range: 124..<136)
    }

    /// Mtime field (136..148).
    public func mtime() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[136..<148]) else {
            throw TarError("invalid mtime")
        }
        return v
    }

    /// Set the mtime field (136..148).
    public mutating func setMtime(_ mtime: UInt64) {
        encodeOctalOrBinary(mtime, into: &bytes, range: 136..<148)
    }

    /// Checksum field (148..156).
    public func checksum() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[148..<156]) else {
            throw TarError("invalid checksum")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("checksum value overflows UInt32")
        }
        return result
    }

    /// Computes the checksum over all 512 header bytes (checksum field treated as spaces).
    public func computeChecksum() -> UInt32 {
        var sum: UInt32 = 0
        for i in 0..<Entry.blockSize {
            if i >= 148 && i < 156 {
                sum &+= UInt32(UInt8(ascii: " "))
            } else {
                sum &+= UInt32(bytes[i])
            }
        }
        return sum
    }

    /// Writes the correct checksum into the header (offset 148..156).
    public mutating func setChecksum() {
        for i in 148..<156 { bytes[i] = UInt8(ascii: " ") }
        let sum = computeChecksum()
        encodeOctalField(UInt64(sum), into: &bytes, range: 148..<156)
    }

    /// Type flag (156) (known as "link flag" in old V7 format)
    public var entryType: EntryType {
        get { EntryType(byte: bytes[156]) }
        set { bytes[156] = newValue.byte }
    }

    /// Link name (157..257).
    public func linkName() -> [UInt8] {
        decodeStringField(bytes[157..<257])
    }

    public mutating func setLinkName(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 100 else {
            throw TarError("link name is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 157..<257)
    }
}

// MARK: - UstarHeader

/// View of a tar header in UStar (POSIX.1-2001) format.
///
/// UStar header fields (followed by the old V7 header fields):
///
/// | Field Name | Octet Offset | Length (in Octets) |
/// |------------|-------------:|-------------------:|
/// | magic      |          257 |                  6 |
/// | version    |          263 |                  2 |
/// | uname      |          265 |                 32 |
/// | gname      |          297 |                 32 |
/// | devmajor   |          329 |                  8 |
/// | devminor   |          337 |                  8 |
/// | prefix     |          345 |                155 |
public struct UstarHeader: Sendable {
    /// The raw 512-byte header data.
    internal var bytes: [UInt8]

    /// Creates a view over the given raw 512-byte header block.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == Entry.blockSize)
        self.bytes = bytes
    }

    /// Magic field (257..263), should be "ustar\0".
    public var magic: [UInt8] {
        Array(bytes[257..<263])
    }

    /// Version field (263..265), should be "00".
    public var version: [UInt8] {
        Array(bytes[263..<265])
    }

    /// Owner user name (265..297).
    public var username: [UInt8] {
        decodeStringField(bytes[265..<297])
    }

    /// Owner group name (297..329).
    public var groupname: [UInt8] {
        decodeStringField(bytes[297..<329])
    }

    /// Device major number (329..337).
    public func deviceMajor() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[329..<337]) else {
            throw TarError("invalid devmajor")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("devmajor value overflows UInt32")
        }
        return result
    }

    /// Device minor number (337..345).
    public func deviceMinor() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[337..<345]) else {
            throw TarError("invalid devminor")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("devminor value overflows UInt32")
        }
        return result
    }

    /// Path prefix (345..500).
    public var prefix: [UInt8] {
        decodeStringField(bytes[345..<500])
    }

    /// Set the path prefix (345..500).
    public mutating func setPrefix(_ prefix: [UInt8]) throws(TarError) {
        guard prefix.count <= 155 else {
            throw TarError("prefix is too long (\(prefix.count) bytes)")
        }
        encodeStringField(prefix, into: &bytes, range: 345..<500)
    }

    /// Set the owner user name (265..297).
    public mutating func setUsername(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 32 else {
            throw TarError("username is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 265..<297)
    }

    /// Set the owner group name (297..329).
    public mutating func setGroupname(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 32 else {
            throw TarError("groupname is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 297..<329)
    }

    /// Set the device major number (329..337).
    public mutating func setDeviceMajor(_ major: UInt32) {
        encodeOctalField(UInt64(major), into: &bytes, range: 329..<337)
    }

    /// Set the device minor number (337..345).
    public mutating func setDeviceMinor(_ minor: UInt32) {
        encodeOctalField(UInt64(minor), into: &bytes, range: 337..<345)
    }
}

// MARK: - GnuHeader

/// View of a tar header in GNU format.
///
/// GNU-specific fields (octets 345-511):
///
/// | Field Name | Octet Offset | Length (in Octets) |
/// |------------|-------------:|-------------------:|
/// | magic      |          257 |                  6 |
/// | version    |          263 |                  2 |
/// | uname      |          265 |                 32 |
/// | gname      |          297 |                 32 |
/// | devmajor   |          329 |                  8 |
/// | devminor   |          337 |                  8 |
/// | atime      |          345 |                 12 |
/// | ctime      |          357 |                 12 |
/// | offset     |          369 |                 12 |
/// | longnames  |          381 |                  4 |
/// | sparse     |          386 |                 96 |
/// | isextended |        482 |                  1 |
/// | realsize   |          483 |                 12 |
/// | (padding)  |          495 |                 17 |
public struct GnuHeader: Sendable {
    /// The raw 512-byte header data.
    internal var bytes: [UInt8]

    /// Creates a view over the given raw 512-byte header block.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == Entry.blockSize)
        self.bytes = bytes
    }

    /// Magic field (257..263), should be "ustar " (trailing space).
    public var magic: [UInt8] {
        Array(bytes[257..<263])
    }

    /// Version field (263..265), should be " \0".
    public var version: [UInt8] {
        Array(bytes[263..<265])
    }

    /// Owner user name (265..297).
    public var username: [UInt8] {
        decodeStringField(bytes[265..<297])
    }

    /// Owner group name (297..329).
    public var groupname: [UInt8] {
        decodeStringField(bytes[297..<329])
    }

    /// Device major (329..337).
    public func deviceMajor() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[329..<337]) else {
            throw TarError("invalid devmajor")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("devmajor value overflows UInt32")
        }
        return result
    }

    /// Device minor (337..345).
    public func deviceMinor() throws(TarError) -> UInt32 {
        guard let v = decodeOctalField(bytes[337..<345]) else {
            throw TarError("invalid devminor")
        }
        guard let result = UInt32(exactly: v) else {
            throw TarError("devminor value overflows UInt32")
        }
        return result
    }

    /// Set the owner user name (265..297).
    public mutating func setUsername(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 32 else {
            throw TarError("username is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 265..<297)
    }

    /// Set the owner group name (297..329).
    public mutating func setGroupname(_ name: [UInt8]) throws(TarError) {
        guard name.count <= 32 else {
            throw TarError("groupname is too long (\(name.count) bytes)")
        }
        encodeStringField(name, into: &bytes, range: 297..<329)
    }

    /// Set the device major number (329..337).
    public mutating func setDeviceMajor(_ major: UInt32) {
        encodeOctalField(UInt64(major), into: &bytes, range: 329..<337)
    }

    /// Set the device minor number (337..345).
    public mutating func setDeviceMinor(_ minor: UInt32) {
        encodeOctalField(UInt64(minor), into: &bytes, range: 337..<345)
    }

    /// Access time (345..357).
    public func atime() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[345..<357]) else {
            throw TarError("invalid atime in GNU header")
        }
        return v
    }

    /// Set access time.
    public mutating func setAtime(_ value: UInt64) {
        encodeOctalOrBinary(value, into: &bytes, range: 345..<357)
    }

    /// Change time (357..369).
    public func ctime() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[357..<369]) else {
            throw TarError("invalid ctime in GNU header")
        }
        return v
    }

    /// Set change time.
    public mutating func setCtime(_ value: UInt64) {
        encodeOctalOrBinary(value, into: &bytes, range: 357..<369)
    }

    /// Offset for multi-volume archives (369..381).
    public func offset() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[369..<381]) else {
            throw TarError("invalid offset in GNU header")
        }
        return v
    }

    /// Long names field (381..385).
    public var longnames: [UInt8] {
        Array(bytes[381..<385])
    }

    /// The 4 inline GNU sparse headers (386..482, each 24 bytes).
    public func sparseHeaders() -> [GnuSparseHeader] {
        (0..<4).map { i in
            let start = 386 + i * 24
            return GnuSparseHeader(
                bytes: Array(bytes[start..<(start + 24)]))
        }
    }

    /// Whether there are extension sparse header blocks following.
    public var isExtended: Bool {
        bytes[482] != 0
    }

    /// Set the is-extended flag.
    public mutating func setIsExtended(_ value: Bool) {
        bytes[482] = value ? 1 : 0
    }

    /// Real size of the file for sparse files (483..495).
    public func realSize() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[483..<495]) else {
            throw TarError("invalid real size in GNU header")
        }
        return v
    }

    /// Set the real size.
    public mutating func setRealSize(_ value: UInt64) {
        encodeOctalOrBinary(value, into: &bytes, range: 483..<495)
    }
}

// MARK: - GnuSparseHeader

/// A single GNU sparse map entry (24 bytes).
/// Contains an offset (12 bytes) and a number-of-bytes (12 bytes).
public struct GnuSparseHeader: Sendable {
    /// The raw 24 bytes.
    public var bytes: [UInt8]

    /// Create from existing bytes (must be 24 bytes).
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 24)
        self.bytes = bytes
    }

    /// Create an empty (all-zero) sparse header.
    public init() {
        bytes = [UInt8](repeating: 0, count: 24)
    }

    /// Whether this sparse header is empty (all zeros).
    public var isEmpty: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    /// The offset within the file (0..12).
    public func offset() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[0..<12]) else {
            throw TarError("invalid sparse offset")
        }
        return v
    }

    /// Set the offset.
    public mutating func setOffset(_ value: UInt64) {
        encodeOctalOrBinary(value, into: &bytes, range: 0..<12)
    }

    /// The number of bytes in this sparse region (12..24).
    public func length() throws(TarError) -> UInt64 {
        guard let v = decodeOctalField(bytes[12..<24]) else {
            throw TarError("invalid sparse length")
        }
        return v
    }

    /// Set the length.
    public mutating func setLength(_ value: UInt64) {
        encodeOctalOrBinary(value, into: &bytes, range: 12..<24)
    }
}

// MARK: - Archive

/// A top-level representation of a tar archive for reading.
///
/// This archive can be iterated over to inspect entries. It reads from a
/// generic byte source provided at construction time.
///
/// Example:
/// ```swift
/// import Tar
///
/// let archive = Archive(data: archiveBytes)
/// for entry in archive {
///     print(entry.fields.path(), entry.fields.size)
/// }
/// ```
public struct Archive: Sendable, Sequence {
    /// The raw bytes of the entire archive.
    let data: [UInt8]

    /// When true, a second end-of-archive marker does not stop parsing; bytes after it are read
    /// as another tar image (GNU / libarchive ``read_concatenated_archives``).
    let readConcatenatedArchives: Bool

    /// When true, a regular file whose last path component starts with `._` is treated as
    /// AppleDouble metadata for the immediately following entry (libarchive ``tar:mac-ext=1``).
    let mergeMacMetadata: Bool

    /// Create a new archive from raw bytes.
    ///
    /// - Parameters:
    ///   - data: The complete tar archive data.
    ///   - readConcatenatedArchives: If true, continue after the usual two zero blocks when more
    ///     non-zero blocks follow (concatenated tar files).
    ///   - mergeMacMetadata: If true, merge each `._*` regular file's payload into the next entry's
    ///     ``EntryFields/macMetadata`` instead of yielding it as its own entry.
    ///
    /// Example:
    /// ```swift
    /// let archive = Archive(data: archiveBytes)
    /// ```
    public init(
        data: [UInt8], readConcatenatedArchives: Bool = false, mergeMacMetadata: Bool = false
    ) {
        self.data = data
        self.readConcatenatedArchives = readConcatenatedArchives
        self.mergeMacMetadata = mergeMacMetadata
    }

    public func makeIterator() -> EntriesIterator {
        EntriesIterator(
            data: data, readConcatenatedArchives: readConcatenatedArchives,
            mergeMacMetadata: mergeMacMetadata)
    }
}

/// The effective metadata for an archive entry.
///
/// `EntryFields` is the semantic view of an entry after applying archive
/// extensions. The embedded ``Header`` remains the raw 512-byte entry header as
/// it appeared in the archive, while the accessors on `EntryFields` resolve
/// overrides carried by GNU long-name records and PAX extended headers.
///
/// Use ``header`` when you need the on-disk base header contents. Use the
/// methods on `EntryFields` when you want the effective path, link target, and
/// other metadata for the entry.
public struct EntryFields: Sendable {
    /// The raw 512-byte header for this entry.
    ///
    /// This is the base header exactly as it appeared in the archive. It does
    /// not incorporate overrides from GNU long-name records or PAX extended
    /// headers. Use the accessors on ``EntryFields`` for effective metadata.
    public var header: Header

    /// GNU long pathname override, if present.
    public var longPathname: [UInt8]?

    /// GNU long link name override, if present.
    public var longLinkname: [UInt8]?

    /// PAX extension headers, if present.
    public var paxHeaders: PaxHeaders?

    /// AppleDouble metadata bytes from a preceding `._*` member, when
    /// ``Archive/init(data:readConcatenatedArchives:mergeMacMetadata:)`` / ``EntriesIterator`` are
    /// created with `mergeMacMetadata: true` (libarchive ``tar:mac-ext=1``).
    public var macMetadata: ArraySlice<UInt8>?

    /// The logical size of the entry's data after applying archive extensions.
    public var size: UInt64

    private func paxNumber(_ key: PaxKey) throws(TarError) -> UInt64? {
        guard let value = paxHeaders?[key] else { return nil }
        guard let parsed = UInt64(value) else {
            throw TarError("invalid PAX \(key.value)")
        }
        return parsed
    }

    private func paxString(_ key: PaxKey) -> String? {
        paxHeaders?[key]
    }

    /// Returns the effective path for this entry.
    ///
    /// This considers GNU long-name extensions and PAX path extensions,
    /// falling back to the header's path field.
    public func pathBytes() -> [UInt8] {
        // 1. GNU long pathname
        if let long = longPathname {
            // Strip trailing null if present
            if let last = long.last, last == 0 {
                return Array(long.dropLast())
            }
            return long
        }
        // 2. PAX path extension
        if let pax = paxHeaders {
            if let path = pax[PaxKey.path] {
                return Array(path.utf8)
            }
        }
        // 3. Header path
        return header.pathBytes()
    }

    /// Returns the effective path as a String.
    public func path() -> String {
        String(decoding: pathBytes(), as: UTF8.self)
    }

    /// Effective entry type for archive consumers.
    ///
    /// Historically, directories were sometimes stored with typeflag `0` (regular) and a path
    /// ending in `/` (POSIX / libarchive behavior). This maps that case to ``EntryType/directory``.
    public func effectiveEntryType() -> EntryType {
        switch header.entryType {
        case .directory:
            return .directory
        case .symlink:
            return .symlink
        default:
            break
        }
        if path().hasSuffix("/") {
            return .directory
        }
        return header.entryType
    }

    /// Returns the effective link name bytes, if any.
    public func linkNameBytes() -> [UInt8]? {
        // 1. GNU long linkname
        if let long = longLinkname {
            if let last = long.last, last == 0 {
                return Array(long.dropLast())
            }
            return long
        }
        // 2. PAX linkpath extension
        if let pax = paxHeaders {
            if let linkpath = pax[PaxKey.linkpath] {
                return Array(linkpath.utf8)
            }
        }
        // 3. Header link name
        return header.linkNameBytes()
    }

    /// Returns the effective link name as a String, or `nil` if absent.
    public func linkName() -> String? {
        guard let bytes = linkNameBytes() else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Returns the effective owner user ID for this entry.
    ///
    /// PAX `uid` overrides the base header field when present.
    public func uid() throws(TarError) -> UInt64 {
        if let value = try paxNumber(.uid) {
            return value
        }
        return try header.uid()
    }

    /// Returns the effective owner group ID for this entry.
    ///
    /// PAX `gid` overrides the base header field when present.
    public func gid() throws(TarError) -> UInt64 {
        if let value = try paxNumber(.gid) {
            return value
        }
        return try header.gid()
    }

    /// Returns the effective modification time for this entry.
    ///
    /// PAX `mtime` overrides the base header field when present. Fractional
    /// timestamps are currently rejected by this accessor.
    public func mtime() throws(TarError) -> UInt64 {
        if let value = try paxNumber(.mtime) {
            return value
        }
        return try header.mtime()
    }

    /// Returns the effective raw username bytes for this entry.
    ///
    /// PAX `uname` overrides the base header field when present.
    public func usernameBytes() -> [UInt8]? {
        if let value = paxString(.uname) {
            return Array(value.utf8)
        }
        return header.usernameBytes()
    }

    /// Returns the effective username for this entry.
    ///
    /// PAX `uname` overrides the base header field when present.
    public func username() throws(TarError) -> String? {
        guard let raw = usernameBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Returns the effective raw group name bytes for this entry.
    ///
    /// PAX `gname` overrides the base header field when present.
    public func groupnameBytes() -> [UInt8]? {
        if let value = paxString(.gname) {
            return Array(value.utf8)
        }
        return header.groupnameBytes()
    }

    /// Returns the effective group name for this entry.
    ///
    /// PAX `gname` overrides the base header field when present.
    public func groupname() throws(TarError) -> String? {
        guard let raw = groupnameBytes() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}

// MARK: - Entry

/// A single entry in a tar archive.
///
/// Provides access to the entry's header, path, link name, data, and PAX
/// extensions.
public struct Entry: Sendable {
    /// The fields for this entry.
    public var fields: EntryFields

    /// The file data for this entry as a slice of the archive buffer.
    ///
    /// This is a zero-copy view into the underlying archive bytes.
    ///
    /// If you need an owned `[UInt8]`, wrap with `Array(entry.data)`.
    public var data: ArraySlice<UInt8>

    static var blockSize: Int { 512 }
}

internal func isEndOfArchive(_ block: ArraySlice<UInt8>) -> Bool {
    block.allSatisfy { $0 == 0 }
}

/// Whether the last path component looks like a macOS AppleDouble sidecar (`._name`), per libarchive
/// ``is_mac_metadata_entry`` (used when ``Archive/mergeMacMetadata`` is enabled).
internal func pathBytesIndicateMacMetadata(_ path: [UInt8]) -> Bool {
    let name: ArraySlice<UInt8>
    if let lastSlash = path.lastIndex(of: UInt8(ascii: "/")) {
        name = path[path.index(after: lastSlash)...]
    } else {
        name = path[...]
    }
    guard name.count >= 3 else { return false }
    let i = name.startIndex
    return name[i] == UInt8(ascii: ".")
        && name[name.index(after: i)] == UInt8(ascii: "_")
        && name[name.index(i, offsetBy: 2)] != 0
}

/// Coordinates merging AppleDouble `._*` payloads into the following archive member (libarchive
/// ``tar:mac-ext=1``). Used by ``EntriesIterator`` and ``TarReader``.
internal struct MacMetadataMergeState: Sendable {
    var pendingPayload: ArraySlice<UInt8>?
    /// Retained for orphan emission when the archive ends after a sidecar without a follower.
    var pendingSidecarFields: EntryFields?

    /// If a sidecar payload is waiting, attach it to `fields` and return true.
    mutating func mergePendingPayload(into fields: inout EntryFields) -> Bool {
        guard let blob = pendingPayload else { return false }
        fields.macMetadata = blob
        pendingPayload = nil
        pendingSidecarFields = nil
        return true
    }

    mutating func recordSidecar(fields: EntryFields, payload: ArraySlice<UInt8>) {
        pendingPayload = payload
        pendingSidecarFields = fields
    }

    mutating func takeOrphanEntry() -> Entry? {
        guard let data = pendingPayload, let fields = pendingSidecarFields else { return nil }
        pendingPayload = nil
        pendingSidecarFields = nil
        return Entry(fields: fields, data: data)
    }

    /// Whether the next non-extension member should receive ``mergePendingPayload(into:)``.
    var hasPendingMerge: Bool { pendingPayload != nil }

    func shouldCaptureAsSidecar(mergeEnabled: Bool, fields: EntryFields) -> Bool {
        mergeEnabled && !hasPendingMerge && fields.header.entryType == .regular
            && pathBytesIndicateMacMetadata(fields.pathBytes())
    }
}

/// Shared semantic parser state used by both batch and streaming readers.
///
/// Notes:
/// - GNU long name/link and local PAX data apply to the next regular entry only.
/// - Global PAX data persists until replaced by later global PAX records.
private struct EntryParsingStateMachine: Sendable {
    private struct PaxRecord: Sendable {
        let key: [UInt8]
        var value: [UInt8]
    }

    struct PreparedHeader: Sendable {
        let kind: PreparedHeaderKind
        /// Logical size from header/PAX; stored in ``EntryFields/size``.
        let logicalSize: UInt64
        /// Bytes of payload following the header in the archive (0 for directory entries).
        let dataPayloadBytes: UInt64
        let paddedSize: Int

        var fields: EntryFields? {
            if case .entry(let fields) = kind {
                return fields
            }
            return nil
        }
    }

    enum PreparedHeaderKind: Sendable {
        case `extension`
        case entry(EntryFields)
    }

    private var gnuLongName: [UInt8]?
    private var gnuLongLink: [UInt8]?
    private var globalPaxRecords = PaxHeaders()
    private var localPaxRecords = PaxHeaders()
    private var hasPendingEntryExtensionsFlag = false

    var hasPendingExtensions: Bool {
        hasPendingEntryExtensionsFlag
    }

    mutating func prepare(_ header: Header) throws(TarError) -> PreparedHeader {
        var logicalSize = try header.entrySize()
        let effectivePaxHeaders = mergedPaxRecords()
        if let ext = effectivePaxHeaders[PaxKey.size] {
            if ext.hasPrefix("-") {
                throw TarError("invalid PAX size: negative value not allowed")
            }
            guard let val = UInt64(ext) else {
                throw TarError("invalid PAX size")
            }
            logicalSize = val
        }

        guard logicalSize <= UInt64(Int.max) else {
            throw TarError("tar entry size exceeds supported platform limits")
        }

        if isExtensionHeader(header) {
            let roundedSize =
                (logicalSize + UInt64(Entry.blockSize) - 1) & ~(UInt64(Entry.blockSize) - 1)
            guard roundedSize <= UInt64(Int.max) else {
                throw TarError("tar entry padded size exceeds supported platform limits")
            }
            let paddedSize = Int(roundedSize)
            return PreparedHeader(
                kind: .extension,
                logicalSize: logicalSize,
                dataPayloadBytes: logicalSize,
                paddedSize: paddedSize
            )
        }

        let dataPayloadBytes: UInt64
        let paddedSize: Int
        if isDirectoryLike(header: header, effectivePax: effectivePaxHeaders) {
            // Legacy tar: directory members are not followed by file payload blocks; the size
            // field must not advance the stream (POSIX / libarchive `test_compat_tar_directory`).
            dataPayloadBytes = 0
            paddedSize = 0
        } else {
            let roundedSize =
                (logicalSize + UInt64(Entry.blockSize) - 1) & ~(UInt64(Entry.blockSize) - 1)
            guard roundedSize <= UInt64(Int.max) else {
                throw TarError("tar entry padded size exceeds supported platform limits")
            }
            paddedSize = Int(roundedSize)
            dataPayloadBytes = logicalSize
        }

        let fields = EntryFields(
            header: header,
            longPathname: gnuLongName,
            longLinkname: gnuLongLink,
            paxHeaders: effectivePaxHeaders.isEmpty ? nil : effectivePaxHeaders,
            macMetadata: nil,
            size: logicalSize
        )
        clearLocalExtensions()
        return PreparedHeader(
            kind: .entry(fields),
            logicalSize: logicalSize,
            dataPayloadBytes: dataPayloadBytes,
            paddedSize: paddedSize
        )
    }

    /// Whether this header describes a directory for stream layout purposes.
    private func isDirectoryLike(header: Header, effectivePax: PaxHeaders) -> Bool {
        if header.entryType == .directory { return true }
        // Only POSIX "regular file" headers use the legacy trailing-slash convention.
        // Vendor-specific types (e.g. Solaris ACL `A`) may use paths ending in `/` with payload.
        if header.entryType != .regular && header.entryType != .continuous {
            return false
        }
        let pathBytes: [UInt8]
        if let long = gnuLongName {
            pathBytes =
                long.last == 0
                ? Array(long.dropLast())
                : long
        } else if let p = effectivePax[PaxKey.path] {
            pathBytes = Array(p.utf8)
        } else {
            pathBytes = header.pathBytes()
        }
        return pathBytes.last == UInt8(ascii: "/")
    }

    mutating func consumeExtensionData(
        header: Header,
        data: ArraySlice<UInt8>
    ) throws(TarError) {
        if header.entryType == .gnuLongName {
            hasPendingEntryExtensionsFlag = true
            gnuLongName = Array(data)
        } else if header.entryType == .gnuLongLink {
            hasPendingEntryExtensionsFlag = true
            gnuLongLink = Array(data)
        } else if header.entryType == .paxLocalExtensions {
            hasPendingEntryExtensionsFlag = true
            localPaxRecords.merge(try parsePaxRecords(data))
        } else if header.entryType == .paxGlobalExtensions {
            globalPaxRecords.merge(try parsePaxRecords(data))
        } else if header.entryType == .gnuVolumeLabel {
            // GNU volume label: payload skipped; no metadata for the following entry.
        }
    }

    /// Whether this block is an extension record (consumed for the following entry).
    ///
    /// Extension typeflags are recognized on their own; they must not require ustar magic.
    /// Fuzzer-generated archives may omit magic (see libarchive `test_read_format_tar_invalid_pax_size`).
    private func isExtensionHeader(_ header: Header) -> Bool {
        switch header.entryType {
        case .gnuLongName, .gnuLongLink, .paxGlobalExtensions, .paxLocalExtensions,
            .gnuVolumeLabel:
            return true
        default:
            return false
        }
    }

    private func mergedPaxRecords() -> PaxHeaders {
        var merged = globalPaxRecords
        merged.merge(localPaxRecords)
        return merged
    }

    private func paxRecord(for key: PaxKey, in records: PaxHeaders) -> String? {
        records[key.value]
    }

    /// Parses PAX key/value records; malformed tails are ignored after the last valid record
    /// (libarchive ``ARCHIVE_WARN`` behavior for damaged extended headers).
    private func parsePaxRecords(_ bytes: ArraySlice<UInt8>) throws(TarError) -> PaxHeaders {
        var headers = PaxHeaders()
        var iterator = PaxIterator(data: bytes)
        while true {
            let ext: PaxExtension
            do {
                guard let next = try iterator.nextExtension() else { break }
                ext = next
            } catch {
                break
            }
            if ext.key == PaxKey.size.value, ext.value.hasPrefix("-") {
                throw TarError("invalid PAX size: negative value not allowed")
            }
            headers[ext.key] = ext.value
        }
        return headers
    }

    private func serialize(_ records: [PaxRecord]) -> [UInt8] {
        var bytes: [UInt8] = []
        for record in records {
            let restLen = 1 + record.key.count + 1 + record.value.count + 1
            var lenLen = 1
            var maxLen = 10
            while restLen + lenLen >= maxLen {
                lenLen += 1
                maxLen *= 10
            }
            let totalLen = restLen + lenLen

            bytes.append(contentsOf: [UInt8](String(totalLen).utf8))
            bytes.append(UInt8(ascii: " "))
            bytes.append(contentsOf: record.key)
            bytes.append(UInt8(ascii: "="))
            bytes.append(contentsOf: record.value)
            bytes.append(UInt8(ascii: "\n"))
        }
        return bytes
    }

    private mutating func clearLocalExtensions() {
        gnuLongName = nil
        gnuLongLink = nil
        localPaxRecords = PaxHeaders()
        hasPendingEntryExtensionsFlag = false
    }
}

/// Iterator over tar archive entries.
///
/// Parses headers directly from the archive buffer without any intermediate
/// copies. Entry data is returned as a zero-copy `ArraySlice` view into the
/// original archive bytes.
///
/// Example:
/// ```swift
/// var iterator = archive.makeIterator()
/// while let entry = try iterator.nextEntry() {
///     print(entry.fields.path())
/// }
/// ```
public struct EntriesIterator: IteratorProtocol, Sendable {
    private let archiveData: [UInt8]
    private let readConcatenatedArchives: Bool
    private let mergeMacMetadata: Bool
    private var offset: Int
    private var done: Bool
    private var sawZeroBlock: Bool
    private var macMetadata = MacMetadataMergeState()
    private var parsingState = EntryParsingStateMachine()

    init(
        data: [UInt8], readConcatenatedArchives: Bool = false, mergeMacMetadata: Bool = false
    ) {
        self.archiveData = data
        self.readConcatenatedArchives = readConcatenatedArchives
        self.mergeMacMetadata = mergeMacMetadata
        self.offset = 0
        self.done = false
        self.sawZeroBlock = false
    }

    /// Advances to and returns the next entry, or `nil` when the archive is exhausted.
    public mutating func next() -> Entry? {
        do {
            return try nextEntry()
        } catch {
            done = true
            return nil
        }
    }

    /// Advances to and returns the next entry, or `nil` when the archive is exhausted.
    ///
    /// Example:
    /// ```swift
    /// while let entry = try iterator.nextEntry() {
    ///     print(entry.fields.path())
    /// }
    /// ```
    public mutating func nextEntry() throws(TarError) -> Entry? {
        while !done {
            let nextBlockEnd = offset + Entry.blockSize
            guard nextBlockEnd <= archiveData.count else {
                return macMetadata.takeOrphanEntry()
            }
            let blockSlice = archiveData[offset..<nextBlockEnd]

            // Check for zero block (end-of-archive marker).
            if isEndOfArchive(blockSlice) {
                offset += Entry.blockSize
                if sawZeroBlock {
                    if readConcatenatedArchives {
                        sawZeroBlock = false
                        continue
                    }
                    done = true
                    return nil
                }
                sawZeroBlock = true
                continue
            }
            if sawZeroBlock {
                // A lone 512-byte zero block is a common partial EOF; some tools append non-zero
                // padding that is not a valid header (e.g. Maven Plexus). If the next block has a
                // valid checksum, treat it as a real member after a bogus EOF (still invalid).
                let header = Header(bytes: Array(blockSlice))
                if (try? header.validateChecksum()) == true {
                    throw TarError("invalid tar archive: zero block followed by non-zero block")
                }
                done = true
                return nil
            }

            let header = Header(bytes: Array(blockSlice))
            guard try header.validateChecksum() else {
                done = true
                return nil
            }

            let prepared = try parsingState.prepare(header)
            offset += Entry.blockSize  // advance past header block

            let filePos = offset
            let dataEnd = filePos + Int(prepared.dataPayloadBytes)
            let nextData = archiveData[filePos..<min(dataEnd, archiveData.count)]
            offset += prepared.paddedSize

            switch prepared.kind {
            case .entry(var fields):
                if macMetadata.mergePendingPayload(into: &fields) {
                    return Entry(fields: fields, data: nextData)
                }
                if macMetadata.shouldCaptureAsSidecar(
                    mergeEnabled: mergeMacMetadata, fields: fields)
                {
                    macMetadata.recordSidecar(fields: fields, payload: nextData)
                    continue
                }
                return Entry(fields: fields, data: nextData)
            case .extension:
                try parsingState.consumeExtensionData(header: header, data: nextData)
                continue
            }
        }
        return macMetadata.takeOrphanEntry()
    }
}

// MARK: - TarReader

/// A push-based streaming tar archive reader.
///
/// Unlike ``Archive`` which requires the entire archive in memory,
/// `TarReader` accepts data incrementally via ``append(_:)`` and emits
/// ``Event`` values as parsing progresses. File content is delivered in
/// chunks -- never fully buffered -- so memory usage stays bounded, except
/// when ``mergeMacMetadata`` is enabled: an AppleDouble `._*` sidecar's
/// payload is buffered until the following member is parsed (matching libarchive
/// ``tar:mac-ext=1``).
///
/// Usage:
/// ```swift
/// var reader = TarReader()
/// for await compressedChunk in response.body {
///     let decompressed = try decompressStream.write(compressedChunk)
///     for event in try reader.append(decompressed) {
///         switch event {
///         case .entryStart(let entry):
///             print(entry.path(), entry.size)
///         case .data(let chunk):
///             outputFile.write(chunk)
///         case .entryEnd:
///             outputFile.close()
///         }
///     }
/// }
/// try reader.finish()
/// ```
///
/// The caller is expected to serialize access; no internal locking is
/// performed.
public struct TarReader: Sendable {

    // MARK: - Parser State

    /// How an in-flight body should be finalized once its bytes are consumed.
    private enum Completion: Sendable {
        /// Internal extension entry data should be fed back into the shared parser state.
        case `extension`(header: Header, data: [UInt8])
        /// A user-visible entry should emit `.entryEnd`.
        case entry
        /// AppleDouble sidecar (`._*`): buffer payload for ``TarReader/mergeMacMetadata`` (no `.data` / `.entryEnd`).
        case macSidecarForMerge(EntryFields)
    }

    /// The current entry body being streamed, including any trailing block padding.
    private struct InFlightEntry: Sendable {
        /// Completion behavior once both data and padding are fully consumed.
        var completion: Completion
        /// Logical entry bytes still to be delivered or buffered.
        var remaining: UInt64
        /// Trailing tar block padding bytes still to be skipped.
        var paddingRemaining: UInt64
        /// Payload bytes when ``Completion/macSidecarForMerge`` is active.
        var macAccumulated: [UInt8]

        init(header: Header, prepared: EntryParsingStateMachine.PreparedHeader) {
            self.remaining = prepared.dataPayloadBytes
            self.paddingRemaining = UInt64(prepared.paddedSize) - prepared.dataPayloadBytes
            self.macAccumulated = []
            switch prepared.kind {
            case .extension:
                self.completion = .extension(header: header, data: [])
            case .entry:
                self.completion = .entry
            }
        }

        init(macSidecarFields: EntryFields, prepared: EntryParsingStateMachine.PreparedHeader) {
            self.remaining = prepared.dataPayloadBytes
            self.paddingRemaining = UInt64(prepared.paddedSize) - prepared.dataPayloadBytes
            self.macAccumulated = []
            self.completion = .macSidecarForMerge(macSidecarFields)
        }

        /// Whether this body belongs to an internal extension entry.
        var isExtension: Bool {
            if case .extension = completion {
                return true
            }
            return false
        }

        var isMacSidecar: Bool {
            if case .macSidecarForMerge = completion {
                return true
            }
            return false
        }

        /// Accumulate streamed bytes for an internal extension entry.
        mutating func appendExtensionData(_ bytes: some Collection<UInt8>) {
            guard case .extension(let header, var data) = completion else { return }
            data.append(contentsOf: bytes)
            completion = .extension(header: header, data: data)
        }

        mutating func appendMacSidecarData(_ bytes: some Collection<UInt8>) {
            macAccumulated.append(contentsOf: bytes)
        }
    }

    /// Internal parser phase.
    private enum State: Sendable {
        /// The starting state.
        /// Waiting for enough bytes to decode the next 512-byte header block.
        case waitingForHeader
        /// A first zero block was seen; waiting to confirm EOF with a second zero block.
        case waitingForZeroBlock
        /// Streaming the current entry body and any trailing padding.
        case reading(InFlightEntry)
        /// Parsing has finished and no further progress is possible.
        case done
    }

    // MARK: - Properties

    /// Internal buffer accumulating bytes across ``append(_:)`` calls.
    private var buffer: [UInt8] = []

    /// Current parser state.
    private var state: State = .waitingForHeader

    /// Shared entry parser state used by both streaming and batch readers.
    private var parsingState = EntryParsingStateMachine()

    /// Total number of bytes pushed into this reader.
    public private(set) var totalBytesIn: UInt64 = 0

    /// If true, after the usual two zero blocks, continue when more data follows
    /// (concatenated tar images). Matches ``Archive/init(data:readConcatenatedArchives:)``.
    private let readConcatenatedArchives: Bool

    /// When true, merge `._*` regular file payloads into the following entry as
    /// ``EntryFields/macMetadata`` (matches ``Archive/mergeMacMetadata``).
    private let mergeMacMetadata: Bool

    private var macMetadata = MacMetadataMergeState()

    // MARK: - Initialization

    /// Create a new streaming tar reader.
    ///
    /// - Parameters:
    ///   - readConcatenatedArchives: If true, continue after two zero blocks when
    ///     further non-zero blocks follow (concatenated archives).
    ///   - mergeMacMetadata: If true, collapse AppleDouble `._*` sidecars like libarchive
    ///     ``tar:mac-ext=1`` (see ``Archive/init(data:readConcatenatedArchives:mergeMacMetadata:)``).
    ///
    /// Example:
    /// ```swift
    /// var reader = TarReader()
    /// ```
    public init(readConcatenatedArchives: Bool = false, mergeMacMetadata: Bool = false) {
        self.readConcatenatedArchives = readConcatenatedArchives
        self.mergeMacMetadata = mergeMacMetadata
    }

    // MARK: - Public API

    /// Push bytes into the reader.
    ///
    /// Returns events for any progress that can be made with the data
    /// available so far.
    ///
    /// - Parameter bytes: A collection of bytes to append.
    /// - Returns: An array of ``Event`` values (may be empty).
    ///
    /// Example:
    /// ```swift
    /// let events = try reader.append(chunk)
    /// ```
    public mutating func append<C: Collection<UInt8>>(_ bytes: C) throws(TarError) -> [Event] {
        buffer.append(contentsOf: bytes)
        totalBytesIn += UInt64(bytes.count)
        return try drain()
    }

    /// Signal that no more input will be provided.
    ///
    /// Returns any final events. Throws if the archive is truncated.
    ///
    /// - Returns: An array of any final ``Event`` values.
    /// - Throws: ``TarError`` if the archive is truncated.
    ///
    /// Example:
    /// ```swift
    /// let finalEvents = try reader.finish()
    /// ```
    public mutating func finish() throws(TarError) -> [Event] {
        var events = try drain()
        switch state {
        case .waitingForHeader:
            events.append(contentsOf: takePendingMacOrphanEvents())
            if !buffer.isEmpty && buffer.contains(where: { $0 != 0 }) {
                throw TarError(
                    "incomplete tar archive: \(buffer.count) bytes remaining (expected 512-byte header block)"
                )
            }
            if parsingState.hasPendingExtensions {
                throw TarError(
                    "incomplete tar archive: extension header(s) without a following entry")
            }
        case .waitingForZeroBlock:
            if !buffer.isEmpty {
                if buffer.count >= Entry.blockSize {
                    let header = Header(bytes: Array(buffer[0..<Entry.blockSize]))
                    if (try? header.validateChecksum()) == true {
                        throw TarError(
                            "invalid tar archive: zero block followed by non-zero block")
                    }
                }
                buffer.removeAll()
            }
        case .reading:
            throw TarError(
                "incomplete tar archive: entry data is truncated")
        case .done:
            break
        }
        state = .done
        return events
    }

    // MARK: - Internal Parsing

    /// Drain as many events from the buffer as possible.
    private mutating func drain() throws(TarError) -> [Event] {
        var events: [Event] = []
        loop: while true {
            switch state {
            case .done:
                break loop

            case .waitingForHeader:
                if try !startNextEntry(events: &events) {
                    break loop
                }
                continue loop

            case .waitingForZeroBlock:
                if try !finishZeroBlockSequence() {
                    break loop
                }
                continue loop

            case .reading(var entry):
                if !drainEntryData(&entry, events: &events) {
                    state = .reading(entry)
                    break loop
                }
                try finishEntry(entry, events: &events)
                continue loop
            }
        }
        return events
    }

    @discardableResult
    private mutating func startNextEntry(events: inout [Event]) throws(TarError) -> Bool {
        guard buffer.count >= Entry.blockSize else { return false }

        let header = Header(bytes: Array(buffer[0..<Entry.blockSize]))
        if header.isZero {
            consumeBuffer(Entry.blockSize)
            state = .waitingForZeroBlock
            return true
        }

        guard try header.validateChecksum() else {
            state = .done
            return false
        }

        let prepared = try parsingState.prepare(header)
        consumeBuffer(Entry.blockSize)

        if case .entry(var fields) = prepared.kind, macMetadata.mergePendingPayload(into: &fields) {
            events.append(.entryStart(fields))
            let entry = InFlightEntry(header: header, prepared: prepared)
            state = .reading(entry)
            return true
        }

        if case .entry(let fields) = prepared.kind,
            macMetadata.shouldCaptureAsSidecar(mergeEnabled: mergeMacMetadata, fields: fields)
        {
            let entry = InFlightEntry(macSidecarFields: fields, prepared: prepared)
            state = .reading(entry)
            return true
        }

        let entry = InFlightEntry(header: header, prepared: prepared)
        state = .reading(entry)

        if let fields = prepared.fields {
            events.append(.entryStart(fields))
        }
        return true
    }

    @discardableResult
    private mutating func finishZeroBlockSequence() throws(TarError) -> Bool {
        guard buffer.count >= Entry.blockSize else { return false }
        if isEndOfArchive(buffer[0..<Entry.blockSize]) {
            consumeBuffer(Entry.blockSize)
            if readConcatenatedArchives {
                state = .waitingForHeader
                return true
            }
            state = .done
            return false
        }
        let header = Header(bytes: Array(buffer[0..<Entry.blockSize]))
        if (try? header.validateChecksum()) == true {
            state = .done
            throw TarError("invalid tar archive: zero block followed by non-zero block")
        }
        // Trailing padding after a single zero block (invalid checksum): ignore (matches lenient
        // readers such as libarchive for archives like Plexus).
        state = .done
        buffer.removeAll()
        return false
    }

    @discardableResult
    private mutating func drainEntryData(_ entry: inout InFlightEntry, events: inout [Event])
        -> Bool
    {
        if entry.remaining > 0 && !buffer.isEmpty {
            let toConsume = min(Int(entry.remaining), buffer.count)
            let slice = buffer[buffer.startIndex..<(buffer.startIndex + toConsume)]

            if entry.isExtension {
                entry.appendExtensionData(slice)
            } else if entry.isMacSidecar {
                entry.appendMacSidecarData(slice)
            } else {
                events.append(.data(slice))
            }

            consumeBuffer(toConsume)
            entry.remaining -= UInt64(toConsume)
        }

        if entry.remaining > 0 {
            return false
        }

        if entry.paddingRemaining > 0 {
            let toSkip = min(Int(entry.paddingRemaining), buffer.count)
            if toSkip == 0 { return false }
            consumeBuffer(toSkip)
            entry.paddingRemaining -= UInt64(toSkip)
            if entry.paddingRemaining > 0 {
                return false
            }
        }

        return true
    }

    private mutating func finishEntry(_ entry: InFlightEntry, events: inout [Event])
        throws(TarError)
    {
        state = .waitingForHeader
        switch entry.completion {
        case .extension(let header, let data):
            try parsingState.consumeExtensionData(header: header, data: ArraySlice(data))
        case .entry:
            events.append(.entryEnd)
        case .macSidecarForMerge(let fields):
            macMetadata.recordSidecar(
                fields: fields, payload: ArraySlice(entry.macAccumulated))
        }
    }

    /// If a `._*` sidecar was fully read but no following entry exists, emit it as a normal file.
    private mutating func takePendingMacOrphanEvents() -> [Event] {
        guard let orphan = macMetadata.takeOrphanEntry() else { return [] }
        return [.entryStart(orphan.fields), .data(orphan.data), .entryEnd]
    }

    /// Remove `count` bytes from the front of the buffer and advance the
    /// logical stream position.
    private mutating func consumeBuffer(_ count: Int) {
        buffer.removeFirst(count)
    }
}

// MARK: - TarReader.Event

extension TarReader {

    /// An event emitted by ``TarReader`` during streaming parsing.
    public enum Event: Sendable {
        /// A complete entry header has been parsed.
        ///
        /// The associated ``EntryFields`` contains the header, path, link name,
        /// and PAX metadata.
        /// Subsequent ``data(_:)`` events deliver the file content.
        case entryStart(EntryFields)

        /// A chunk of file content for the current entry.
        ///
        /// May be emitted zero or more times between ``entryStart(_:)`` and
        /// ``entryEnd``. The chunks are contiguous; concatenating them
        /// produces the complete file content.
        case data(ArraySlice<UInt8>)

        /// The current entry's file content has been fully delivered.
        case entryEnd
    }
}
