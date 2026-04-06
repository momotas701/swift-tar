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

// MARK: - HeaderMode

/// Controls how metadata is written when building archives.
public enum HeaderMode: Sendable {
    /// Include all metadata as-is.
    case complete
    /// Use deterministic values: zero uid/gid, fixed timestamps.
    case deterministic
}

/// A deterministic timestamp for reproducible builds (Sat Jul 17 23:50:59 2010 +0000).
public let deterministicTimestamp: UInt64 = 1_279_407_059

// MARK: - TarWriter

/// A structure for building tar archives.
///
/// The writer accumulates entries into an internal byte buffer. Call
/// ``finish()`` to produce the final archive data.
///
/// Example:
/// ```swift
/// import Tar
///
/// var writer = TarWriter(mode: .deterministic)
/// var header = Header(asGnu: ())
/// header.entryType = .regular
/// header.setMode(0o644)
///
/// let data = Array("hello\n".utf8)
/// writer.appendData(header: header, path: "hello.txt", data: data)
///
/// let archiveBytes = writer.finish()
/// ```
public struct TarWriter: Sendable {
    /// The header mode for metadata.
    public var mode: HeaderMode

    /// Whether the archive has been finished.
    private var finished: Bool = false

    /// The accumulated archive bytes.
    private var buffer: [UInt8] = []

    // MARK: - Initialization

    /// Create a new tar archive writer.
    ///
    /// - Parameter mode: The header mode controlling metadata. Defaults to
    ///   ``HeaderMode/complete``.
    ///
    /// Example:
    /// ```swift
    /// let writer = TarWriter(mode: .deterministic)
    /// ```
    public init(mode: HeaderMode = .complete) {
        self.mode = mode
    }

    // MARK: - Appending Entries

    /// Append a raw entry with the given header and data.
    ///
    /// The header's checksum should have already been set. The data is
    /// padded to a 512-byte boundary automatically.
    ///
    /// - Parameters:
    ///   - header: The 512-byte entry header.
    ///   - data: The entry data.
    ///
    /// Example:
    /// ```swift
    /// var header = Header(asGnu: ())
    /// header.entryType = .regular
    /// header.setSize(5)
    /// header.setChecksum()
    ///
    /// writer.append(header: header, data: Array("hello".utf8))
    /// ```
    public mutating func append<C: Collection<UInt8>>(header: Header, data: C) {
        buffer.append(contentsOf: header._bytes)
        buffer.append(contentsOf: data)
        // Pad to 512-byte boundary
        let remainder = data.count % 512
        if remainder != 0 {
            let padding = 512 - remainder
            buffer.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }
    }

    /// Append an entry with the given path and data.
    ///
    /// This creates a header, handles long paths via GNU extensions if
    /// necessary, and writes the entry.
    ///
    /// - Parameters:
    ///   - header: A header to use as the basis. Path and checksum will be
    ///     set automatically on a local copy.
    ///   - path: The path name for the entry.
    ///   - data: The file data.
    ///
    /// Example:
    /// ```swift
    /// var header = Header(asGnu: ())
    /// header.entryType = .regular
    /// header.setMode(0o644)
    ///
    /// writer.appendData(header: header, path: "hello.txt", data: Array("hello\n".utf8))
    /// ```
    public mutating func appendData<C: Collection<UInt8>>(
        header: Header, path: String, data: C
    ) {
        var header = header
        let pathBytes = [UInt8](path.utf8)
        prepareHeaderPath(&header, pathBytes: pathBytes)
        header.setSize(UInt64(data.count))
        header.setChecksum()
        append(header: header, data: data)
    }

    /// Append a link entry (symlink or hard link).
    ///
    /// - Parameters:
    ///   - header: A header. Must have entry type set to `.link`
    ///     or `.symlink`.
    ///   - path: The path name for the link entry.
    ///   - target: The link target path.
    ///
    /// Example:
    /// ```swift
    /// var header = Header(asGnu: ())
    /// header.entryType = .symlink
    ///
    /// writer.appendLink(header: header, path: "link.txt", target: "target.txt")
    /// ```
    public mutating func appendLink(
        header: Header, path: String, target: String
    ) {
        var header = header
        let pathBytes = [UInt8](path.utf8)
        let targetBytes = [UInt8](target.utf8)
        prepareHeaderPath(&header, pathBytes: pathBytes)
        prepareHeaderLink(&header, linkBytes: targetBytes)
        header.setSize(0)
        header.setChecksum()
        append(header: header, data: [])
    }

    /// Append a directory entry.
    ///
    /// - Parameter path: The directory path. A trailing `/` will be added
    ///   if not present.
    ///
    /// Example:
    /// ```swift
    /// writer.appendDir(path: "subdir")
    /// ```
    public mutating func appendDir(path: String) {
        var dirPath = path
        if !dirPath.hasSuffix("/") {
            dirPath += "/"
        }
        var header = Header(asGnu: ())
        header.entryType = .directory
        header.setMode(0o755)
        if mode == .deterministic {
            header.setUid(0)
            header.setGid(0)
            header.setMtime(deterministicTimestamp)
        }
        let pathBytes = [UInt8](dirPath.utf8)
        prepareHeaderPath(&header, pathBytes: pathBytes)
        header.setSize(0)
        header.setChecksum()
        append(header: header, data: [])
    }

    /// Append PAX extended headers.
    ///
    /// - Parameter extensions: Key/value pairs to encode as PAX extensions.
    ///
    /// Example:
    /// ```swift
    /// writer.appendPaxExtensions([
    ///     (key: PaxKey.path.name, value: Array("very/long/path.txt".utf8))
    /// ])
    /// ```
    public mutating func appendPaxExtensions(
        _ extensions: [(key: String, value: [UInt8])]
    ) {
        var paxData: [UInt8] = []

        for (key, value) in extensions {
            let keyBytes = [UInt8](key.utf8)
            // Format: "<len> <key>=<value>\n"
            // len includes itself, space, key, =, value, newline
            let restLen = 1 + keyBytes.count + 1 + value.count + 1  // space + key + = + value + \n
            var lenLen = 1
            var maxLen = 10
            while restLen + lenLen >= maxLen {
                lenLen += 1
                maxLen *= 10
            }
            let totalLen = restLen + lenLen

            // Write the record
            paxData.append(contentsOf: [UInt8](String(totalLen).utf8))
            paxData.append(UInt8(ascii: " "))
            paxData.append(contentsOf: keyBytes)
            paxData.append(UInt8(ascii: "="))
            paxData.append(contentsOf: value)
            paxData.append(UInt8(ascii: "\n"))
        }

        if paxData.isEmpty { return }

        var header = Header(asUstar: ())
        header.setSize(UInt64(paxData.count))
        header.entryType = .paxLocalExtensions
        header.setChecksum()
        append(header: header, data: paxData)
    }

    // MARK: - Finishing

    /// Finish writing the archive by appending the termination blocks.
    ///
    /// This appends two 512-byte zero blocks to signal the end of the
    /// archive.
    ///
    /// Example:
    /// ```swift
    /// let archiveBytes = writer.finish()
    /// ```
    public mutating func finish() -> [UInt8] {
        if finished { return buffer }
        finished = true
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        return buffer
    }

    // MARK: - Internal Helpers

    /// Prepare the header path, emitting a GNU long-name extension if needed.
    private mutating func prepareHeaderPath(
        _ header: inout Header, pathBytes: [UInt8]
    ) {
        if pathBytes.count <= 100 {
            encodeStringField(pathBytes, into: &header._bytes, range: 0..<100)
            if header.isUstar {
                encodeStringField([], into: &header._bytes, range: 345..<500)
            }
        } else if header.isUstar, let (prefix, name) = _splitUstarPath(pathBytes) {
            encodeStringField(name, into: &header._bytes, range: 0..<100)
            encodeStringField(prefix, into: &header._bytes, range: 345..<500)
        } else {
            // Path is too long to store directly; emit a GNU ././@LongLink
            // entry carrying the full path, then store a truncated name in
            // the header for readers that ignore the extension.
            emitGnuLongName(pathBytes)
            encodeStringField(Array(pathBytes.prefix(100)), into: &header._bytes, range: 0..<100)
        }
    }

    /// Prepare the header link name, emitting a GNU long-link extension if
    /// needed.
    private mutating func prepareHeaderLink(
        _ header: inout Header, linkBytes: [UInt8]
    ) {
        if linkBytes.count <= 100 {
            encodeStringField(linkBytes, into: &header._bytes, range: 157..<257)
        } else {
            // Link target is too long; emit a GNU ././@LongLink ('K') entry
            // carrying the full target, then store a truncated name for
            // readers that ignore the extension.
            emitGnuLongLink(linkBytes)
            encodeStringField(Array(linkBytes.prefix(100)), into: &header._bytes, range: 157..<257)
        }
    }

    /// Emit a GNU long-name ('L') extension entry.
    private mutating func emitGnuLongName(_ name: [UInt8]) {
        var header = prepareLongHeader(
            size: UInt64(name.count + 1), entryType: .gnuLongName)
        header.setChecksum()
        // Data: name + null terminator
        var data = name
        data.append(0)
        append(header: header, data: data)
    }

    /// Emit a GNU long-link ('K') extension entry.
    private mutating func emitGnuLongLink(_ link: [UInt8]) {
        var header = prepareLongHeader(
            size: UInt64(link.count + 1), entryType: .gnuLongLink)
        header.setChecksum()
        var data = link
        data.append(0)
        append(header: header, data: data)
    }

    /// Create a header for a GNU long-name/long-link extension entry.
    private func prepareLongHeader(
        size: UInt64, entryType: EntryType
    ) -> Header {
        var header = Header(asGnu: ())
        // Set the conventional name used by GNU tar for long-name entries.
        let name = Array("././@LongLink".utf8)
        encodeStringField(name, into: &header._bytes, range: 0..<100)
        header.setMode(0o644)
        header.setUid(0)
        header.setGid(0)
        header.setMtime(0)
        header.setSize(size)
        header.entryType = entryType
        return header
    }
}

// MARK: - Helpers

/// Split a UStar path at the rightmost '/' that yields a valid prefix/name pair.
/// Returns `nil` if no valid split exists.
private func _splitUstarPath(
    _ pathBytes: [UInt8]
) -> (prefix: [UInt8], name: [UInt8])? {
    let slash = UInt8(ascii: "/")
    for i in stride(from: pathBytes.count - 1, through: 0, by: -1) {
        if pathBytes[i] == slash {
            let prefixLen = i
            let nameLen = pathBytes.count - i - 1
            if prefixLen > 0 && prefixLen <= 155 && nameLen > 0 && nameLen <= 100 {
                return (Array(pathBytes[0..<i]), Array(pathBytes[(i + 1)...]))
            }
        }
    }
    return nil
}
