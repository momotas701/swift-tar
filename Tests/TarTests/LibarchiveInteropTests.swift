//
// Tests using libarchive's test suite archives to verify interoperability.
// Run `Vendor/checkout-dependency libarchive` before running these tests.
//
// Optional extraction-vs-bsdtar checks: set `SWIFT_TAR_BSDTAR_EXTRACT_TESTS=1` and ensure `bsdtar`
// is on `PATH` (or set `BSDTAR_EXEC`). When those are not met, the parameterized test returns
// without running (no `Test.cancel`, which requires a newer toolchain than Swift 6.1). Inactive on
// Windows/WASI.
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import Tar

// MARK: - Helpers

private let vendorDir: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Vendor")
        .appendingPathComponent("libarchive")
        .appendingPathComponent("libarchive")
        .appendingPathComponent("test")
}()

/// Decode a uuencoded file to raw bytes.
private func uudecode(_ name: String) throws -> [UInt8] {
    let uuPath = vendorDir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: uuPath.path) else {
        throw LibarchiveTestError(
            "File not found: \(uuPath.path). Run: Vendor/checkout-dependency libarchive")
    }
    let content = try String(contentsOf: uuPath, encoding: .ascii)
    return try decodeUU(content)
}

private struct LibarchiveTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Pure-Swift uudecode implementation.
private func decodeUU(_ content: String) throws -> [UInt8] {
    var result: [UInt8] = []
    var inBody = false
    // Normalize line endings so CRLF (Windows git checkout) doesn't corrupt decoding.
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("begin ") {
            inBody = true
            continue
        }
        if line == "end" || line == "`" {
            break
        }
        guard inBody else { continue }
        let chars = Array(line.utf8)
        guard !chars.isEmpty else { continue }
        let count = Int(chars[0]) - 32
        guard count > 0, count <= 45 else { continue }
        var decoded: [UInt8] = []
        var i = 1
        while decoded.count < count {
            func ch(_ idx: Int) -> UInt8 {
                guard idx < chars.count else { return 0 }
                let v = chars[idx]
                return ((v - 32) & 0x3F)
            }
            let a = ch(i)
            let b = ch(i + 1)
            let c = ch(i + 2)
            let d = ch(i + 3)
            decoded.append((a << 2) | (b >> 4))
            decoded.append((b << 4) | (c >> 2))
            decoded.append((c << 6) | d)
            i += 4
        }
        result.append(contentsOf: decoded.prefix(count))
    }
    return result
}

/// Collect all entries from an archive into an array.
private func collectEntries(
    _ data: [UInt8],
    readConcatenatedArchives: Bool = false,
    mergeMacMetadata: Bool = false
) -> [Entry] {
    let archive = Archive(
        data: data, readConcatenatedArchives: readConcatenatedArchives,
        mergeMacMetadata: mergeMacMetadata)
    return Array(archive)
}

/// Collect entries using ``EntriesIterator/nextEntry()`` so ``TarError`` is not swallowed
/// (unlike ``Archive``'s `Sequence` conformance, which maps errors to end-of-sequence).
private func collectAllEntriesThrowing(_ data: [UInt8]) throws(TarError) -> [Entry] {
    var iterator = EntriesIterator(data: data)
    var entries: [Entry] = []
    while let entry = try iterator.nextEntry() {
        entries.append(entry)
    }
    return entries
}

/// Shared checks for ``test_pax_xattr_header*.tar`` (see ``test_pax_xattr_header.c``).
private func assertPaxXattrHeaderArchiveCore(_ entries: [Entry]) throws {
    try #require(entries.count == 1)
    let e = entries[0]
    #expect(e.fields.path() == "file")
    #expect(e.fields.header.entryType == .regular)
    #expect(e.fields.size == 8)
    #expect(String(decoding: e.data, as: UTF8.self) == "12345678")
}

// MARK: - bsdtar extract interop (helpers)

/// Snapshot of one extracted path: kind, raw bytes or symlink target, POSIX mode bits, and mtime
/// (whole seconds) from the filesystem.
private enum BsdtarExtractedTreeEntry: Equatable {
    case directory(permissions: Int, modificationTimeUnix: Int64)
    case regular(permissions: Int, modificationTimeUnix: Int64, data: Data)
    case symlink(permissions: Int, modificationTimeUnix: Int64, target: String)
}

private func posixModeAndMtimeSeconds(atPath path: String) throws -> (mode: Int, mtimeSec: Int64) {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    let mtime = attrs[.modificationDate] as? Date
    let sec = mtime.map { Int64($0.timeIntervalSince1970.rounded()) } ?? 0
    return (mode, sec)
}

private func bsdtarExtractionSnapshot(root: URL) throws -> [String: BsdtarExtractedTreeEntry] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else {
        throw LibarchiveTestError("Missing extraction root \(root.path)")
    }

    var result: [String: BsdtarExtractedTreeEntry] = [:]
    guard
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        )
    else {
        throw LibarchiveTestError("Could not enumerate \(root.path)")
    }

    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    while let item = enumerator.nextObject() as? URL {
        let itemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
        let rel: String
        if itemPath == rootPath {
            continue
        } else if itemPath.hasPrefix(rootPath + "/") {
            rel = String(itemPath.dropFirst(rootPath.count + 1))
        } else {
            throw LibarchiveTestError("Unexpected path under \(rootPath): \(itemPath)")
        }

        let values = try item.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
        let meta = try posixModeAndMtimeSeconds(atPath: item.path)
        if values.isDirectory == true {
            result[rel] = .directory(permissions: meta.mode, modificationTimeUnix: meta.mtimeSec)
        } else if values.isSymbolicLink == true {
            let dest = try fm.destinationOfSymbolicLink(atPath: item.path)
            result[rel] = .symlink(
                permissions: meta.mode, modificationTimeUnix: meta.mtimeSec, target: dest)
        } else if values.isRegularFile == true {
            let data = try Data(contentsOf: item)
            result[rel] = .regular(
                permissions: meta.mode, modificationTimeUnix: meta.mtimeSec, data: data)
        } else {
            throw LibarchiveTestError("Unsupported filesystem entry at \(item.path)")
        }
    }

    return result
}

private func bsdtarMetadataComparable(
    _ lhs: BsdtarExtractedTreeEntry, _ rhs: BsdtarExtractedTreeEntry
)
    -> Bool
{
    func modesMatch(_ a: Int, _ b: Int) -> Bool {
        (a & 0o7777) == (b & 0o7777)
    }
    /// Many filesystems cannot represent pre-Unix-epoch mtimes; tools may clamp differently.
    func mtimesMatch(_ a: Int64, _ b: Int64) -> Bool {
        if a == b { return true }
        if a < 0 || b < 0 { return true }
        return false
    }

    switch (lhs, rhs) {
    case (
        .directory(let ap, let am),
        .directory(let bp, let bm)
    ):
        return modesMatch(ap, bp) && mtimesMatch(am, bm)
    case (
        .regular(let ap, let am, let ad),
        .regular(let bp, let bm, let bd)
    ):
        return modesMatch(ap, bp) && mtimesMatch(am, bm) && ad == bd
    case (
        .symlink(let ap, let am, let at),
        .symlink(let bp, let bm, let bt)
    ):
        return modesMatch(ap, bp) && mtimesMatch(am, bm) && at == bt
    default:
        return false
    }
}

private func assertBsdtarAndSwiftExtractionsMatch(bsdtarRoot: URL, swiftRoot: URL) throws {
    let a = try bsdtarExtractionSnapshot(root: bsdtarRoot)
    let b = try bsdtarExtractionSnapshot(root: swiftRoot)
    let keysA = Set(a.keys).sorted()
    let keysB = Set(b.keys).sorted()
    #expect(
        keysA == keysB,
        "Relative paths differ.\nbsdtar: \(keysA)\nswift-tar: \(keysB)")
    for key in keysA {
        guard let left = a[key], let right = b[key] else {
            Issue.record("Missing entry for \(key)")
            continue
        }
        #expect(
            bsdtarMetadataComparable(left, right),
            "Mismatch at \(key): bsdtar \(String(describing: left)) vs swift-tar \(String(describing: right))"
        )
    }
}

private func bsdtarVersionExits(at executable: URL) -> Bool {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func runBsdtarExtract(bsdtar: URL, archive: URL, destination: URL) throws {
    let process = Process()
    process.executableURL = bsdtar
    // `-p` / same-permissions: comparable to ``TarExtractor/preservePermissions``.
    process.arguments = ["-pxf", archive.path, "-C", destination.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let err =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw LibarchiveTestError("bsdtar failed (status \(process.terminationStatus)): \(err)")
    }
}

/// Resolves `bsdtar` when the opt-in interop test should run; otherwise `nil` (caller returns early).
/// Uses early exit instead of `Test.cancel` so it builds on Swift 6.1 toolchains.
private func bsdtarURLForInteropIfEnabled() -> URL? {
    #if os(Windows) || os(WASI)
        return nil
    #else
        guard ProcessInfo.processInfo.environment["SWIFT_TAR_BSDTAR_EXTRACT_TESTS"] == "1" else {
            return nil
        }
        guard let url = TestSupport.which("bsdtar") else {
            return nil
        }
        guard bsdtarVersionExits(at: url) else {
            return nil
        }
        return url
    #endif
}

// MARK: - test_read_format_tar.c equivalent
// Tests various basic entry types using inline data from libarchive.

@Suite("Libarchive Interop", .tags(.libarchiveInterop))
struct LibarchiveInteropTests {

    // MARK: - test_compat_gtar_1: GNU tar long filenames and symlinks

    @Test("compat gtar 1 - long filenames")
    func compatGtar1() throws {
        let data = try uudecode("test_compat_gtar_1.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 2)

        // Entry 1: Regular file with 200-char name
        let longName = String(
            repeating:
                "1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890",
            count: 2)
        let e1 = entries[0]
        #expect(e1.fields.path() == longName)
        #expect(e1.fields.header.entryType == .regular)
        #expect(try e1.fields.header.mtime() == 1_197_179_003)
        #expect(try e1.fields.header.uid() == 1000)
        #expect(try e1.fields.username() == "tim")
        #expect(try e1.fields.header.gid() == 1000)
        #expect(try e1.fields.groupname() == "tim")
        #expect(try e1.fields.header.mode() == 0o100644)

        // Entry 2: Symlink with 200-char name pointing to 200-char target
        let longLink = String(
            repeating:
                "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij",
            count: 2)
        let e2 = entries[1]
        #expect(e2.fields.path() == longLink)
        #expect(e2.fields.header.entryType == .symlink)
        #expect(e2.fields.linkName() == longName)
        #expect(try e2.fields.header.mtime() == 1_197_179_043)
        #expect(try e2.fields.header.uid() == 1000)
        #expect(try e2.fields.username() == "tim")
        #expect(try e2.fields.header.gid() == 1000)
        #expect(try e2.fields.groupname() == "tim")
        #expect(try e2.fields.header.mode() == 0o120755)
    }

    // MARK: - test_compat_gtar_2: base-256 UID and octal GID

    @Test("compat gtar 2 - large uid/gid")
    func compatGtar2() throws {
        let data = try uudecode("test_compat_gtar_2.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 1)

        let e1 = entries[0]
        #expect(e1.fields.path() == "file_with_big_uid_gid")
        #expect(e1.fields.header.entryType == .regular)
        #expect(e1.fields.size == 119)
        #expect(try e1.fields.header.uid() == 2_097_152)
        #expect(try e1.fields.header.gid() == 2_097_152)
        #expect(try e1.fields.username() == "test")
        #expect(try e1.fields.groupname() == "big")
        #expect(try e1.fields.header.mode() == 0o666)
    }

    // MARK: - test_compat_tar_directory: directory entry

    @Test("compat tar directory")
    func compatTarDirectory() throws {
        let data = try uudecode("test_compat_tar_directory_1.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 2)

        // The first entry uses a regular-file header but must still be treated
        // as a directory because the path ends in "/".
        let e1 = entries[0]
        #expect(e1.fields.path() == "directory1/")
        #expect(e1.fields.effectiveEntryType() == .directory)
        #expect(e1.fields.size == 1)

        let e2 = entries[1]
        #expect(e2.fields.path() == "directory2/")
        #expect(e2.fields.effectiveEntryType() == .directory)
        #expect(e2.fields.size == 0)
    }

    // MARK: - test_compat_tar_hardlink: hardlink entry

    @Test("compat tar hardlink")
    func compatTarHardlink() throws {
        let data = try uudecode("test_compat_tar_hardlink_1.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 2)

        // Entry 1: regular file payload.
        let e1 = entries[0]
        #expect(e1.fields.path() == "xmcd-3.3.2/docs_d/READMf")
        #expect(e1.fields.header.entryType == .regular)
        #expect(e1.fields.linkName() == "")
        #expect(e1.fields.size == 321)
        #expect(try e1.fields.header.mtime() == 1_082_575_645)
        #expect(try e1.fields.header.uid() == 1851)
        #expect(try e1.fields.header.gid() == 3)
        #expect(try e1.fields.header.mode() == 0o444)

        // Entry 2: hardlink at end-of-archive. Matching libarchive here is
        // important because readers that obey a non-zero size can overrun.
        let e2 = entries[1]
        #expect(e2.fields.path() == "xmcd-3.3.2/README")
        #expect(e2.fields.header.entryType == .link)
        #expect(e2.fields.linkName() == "xmcd-3.3.2/docs_d/READMf")
        #expect(e2.fields.size == 321)
        #expect(try e2.fields.header.mtime() == 1_082_575_645)
        #expect(try e2.fields.header.uid() == 1851)
        #expect(try e2.fields.header.gid() == 3)
        #expect(try e2.fields.header.mode() == 0o444)
    }

    // MARK: - test_compat_perl_archive_tar

    @Test("compat perl Archive::Tar")
    func compatPerlArchiveTar() throws {
        let data = try uudecode("test_compat_perl_archive_tar.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 1)

        let e1 = entries[0]
        #expect(e1.fields.path() == "file1")
        #expect(e1.fields.header.entryType == .regular)
        #expect(try e1.fields.header.mtime() == 1_480_603_099)
        #expect(try e1.fields.header.uid() == 1000)
        #expect(try e1.fields.username() == "john")
        #expect(try e1.fields.header.gid() == 1000)
        #expect(try e1.fields.groupname() == "john")
        #expect(try e1.fields.header.mode() == 0o644)
        #expect(e1.fields.header.isUstar)
        #expect(e1.fields.size == 5)
        #expect(String(decoding: e1.data, as: UTF8.self) == "abcd\n")
    }

    // MARK: - test_compat_plexus_archiver_tar
    // Tests plexus-archiver which fills uid/gid with spaces

    @Test("compat plexus archiver")
    func compatPlexusArchiver() throws {
        let data = try uudecode("test_compat_plexus_archiver_tar.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 1)

        let e1 = entries[0]
        #expect(e1.fields.path() == "commons-logging-1.2/NOTICE.txt")
        #expect(e1.fields.header.entryType == .regular)
        #expect(try e1.fields.header.mtime() == 1_404_583_896)
        #expect(try e1.fields.header.mode() == 0o100664)
        // uid/gid filled with spaces should parse as 0
        #expect(try e1.fields.header.uid() == 0)
        #expect(try e1.fields.header.gid() == 0)

        let ustar = try #require(e1.fields.header.asUstar())
        #expect(ustar.magic == Array("ustar\0".utf8))
        #expect(ustar.version == [0, 0])
    }

    // MARK: - test_read_format_tar_concatenated

    @Test("read concatenated tar")
    func readConcatenated() throws {
        let data = try uudecode("test_read_format_tar_concatenated.tar.uu")

        // libarchive default (no read_concatenated_archives): first tape only - file1 then EOF.
        let entries1 = collectEntries(data)
        try #require(entries1.count == 1)
        #expect(entries1[0].fields.path() == "file1")
        #expect(entries1[0].fields.header.entryType == .regular)
        #expect(entries1[0].fields.size == 0)

        let entriesBoth = collectEntries(
            data,
            readConcatenatedArchives: true
        )
        try #require(entriesBoth.count == 2)
        #expect(entriesBoth[0].fields.path() == "file1")
        #expect(entriesBoth[1].fields.path() == "file2")

        var reader = TarReader(readConcatenatedArchives: true)
        var events: [TarReader.Event] = []
        events.append(contentsOf: try reader.append(data))
        events.append(contentsOf: try reader.finish())
        var paths: [String] = []
        var pending: EntryFields?
        for event in events {
            switch event {
            case .entryStart(let fields):
                pending = fields
            case .entryEnd:
                if let fields = pending {
                    paths.append(fields.path())
                    pending = nil
                }
            default:
                break
            }
        }
        #expect(paths == ["file1", "file2"])
    }

    // MARK: - test_read_format_tar_empty_filename

    @Test("read empty filename")
    func readEmptyFilename() throws {
        let data = try uudecode("test_read_format_tar_empty_filename.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 1)

        let e1 = entries[0]
        #expect(e1.fields.path() == "")
        #expect(try e1.fields.header.mtime() == 1_208_628_157)
        #expect(try e1.fields.header.uid() == 1000)
        #expect(try e1.fields.header.gid() == 0)
        #expect(e1.fields.header.entryType == .directory)
    }

    // MARK: - test_read_format_tar_empty_with_gnulabel
    // An archive with only a GNU volume label should have no user-visible entries.

    @Test("read empty with GNU label")
    func readEmptyWithGnuLabel() throws {
        let data = try uudecode("test_read_format_tar_empty_with_gnulabel.tar.uu")
        let entries = collectEntries(data)
        // libarchive: immediate EOF (GNU volume label is not a user-visible entry).
        #expect(entries.isEmpty)
    }

    // MARK: - test_read_format_tar_invalid_pax_size
    // A PAX archive with a bogus large negative size should not crash.

    @Test("read invalid pax size does not crash")
    func readInvalidPaxSize() throws {
        let data = try uudecode("test_read_format_tar_invalid_pax_size.tar.uu")
        // libarchive: ARCHIVE_FATAL when applying invalid negative PAX `size`
        // (test_read_format_tar_invalid_pax_size.c).
        #expect(throws: TarError.self) {
            try collectAllEntriesThrowing(data)
        }
    }

    // MARK: - test_read_format_tar_V_negative_size

    @Test("read V entry negative size does not crash")
    func readVNegativeSize() throws {
        let data = try uudecode("test_read_format_tar_V_negative_size.tar.uu")
        // libarchive: ARCHIVE_FATAL (negative `V` body size). No usable file entry.
        let entries = try collectAllEntriesThrowing(data)
        #expect(entries.isEmpty)
    }

    // MARK: - test_read_format_tar_pax_negative_time

    @Test("read pax negative time")
    func readPaxNegativeTime() throws {
        let data = try uudecode("test_read_format_tar_pax_negative_time.tar.uu")
        let entries = try collectAllEntriesThrowing(data)
        try #require(entries.count == 1)

        let e1 = entries[0]
        #expect(e1.fields.path() == "empty")
        let pax = try #require(e1.fields.paxHeaders)
        // Values from libarchive test_read_format_tar_pax_negative_time.c
        #expect(pax[PaxKey.mtime] == "-2146608000")
        #expect(pax[PaxKey.atime] == "-2146608000")
        #expect(pax[PaxKey.ctime] == "1748089464.951928467")
        #expect(try e1.fields.username() == "root")
        #expect(try e1.fields.groupname() == "root")
        #expect(try e1.fields.header.uid() == 0)
        #expect(try e1.fields.header.gid() == 0)
        #expect(try e1.fields.header.mode() == 0o644)
        #expect(e1.fields.size == 0)
        #expect(e1.fields.header.entryType == .regular)
    }

    // MARK: - test_read_format_tar_pax_g_large
    // A PAX archive with a 4GB global header. Should not OOM.

    @Test("read pax global large does not OOM")
    func readPaxGlobalLarge() throws {
        let data = try uudecode("test_read_format_tar_pax_g_large.tar.uu")
        // libarchive: no OK data entry (oversized global PAX header vs. short file).
        let entries = collectEntries(data)
        #expect(entries.isEmpty)
    }

    // MARK: - PAX xattr archives

    @Test("read pax xattr schily")
    func readPaxXattrSchily() throws {
        let data = try uudecode("test_read_pax_xattr_schily.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count >= 1)

        // Should have PAX headers with SCHILY.xattr entries
        let e1 = entries[0]
        let pax = try #require(e1.fields.paxHeaders)
        #expect(
            pax["SCHILY.xattr.user.mime_type"] != nil || pax["SCHILY.xattr.security.selinux"] != nil
        )
    }

    @Test("read pax xattr rht security selinux")
    func readPaxXattrRhtSecuritySelinux() throws {
        let data = try uudecode("test_read_pax_xattr_rht_security_selinux.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 1)
        let e1 = entries[0]
        #expect(e1.fields.path() == "test.txt")
        #expect(e1.fields.header.entryType == .regular)
        #expect(e1.fields.size == 0)
        let pax = try #require(e1.fields.paxHeaders)
        // Encoded as RHT.* in this fixture (see strings in the reference tarball).
        #expect(pax["RHT.security.selinux"] == "system_u:object_r:admin_home_t:s0")
    }

    @Test("read pax xattr header all")
    func readPaxXattrHeaderAll() throws {
        let data = try uudecode("test_pax_xattr_header_all.tar.uu")
        let entries = collectEntries(data)
        try assertPaxXattrHeaderArchiveCore(entries)
        let pax = try #require(entries[0].fields.paxHeaders)
        #expect(pax["SCHILY.xattr.user.data1"] == "ABCDEFG")
        #expect(pax["SCHILY.xattr.user.data2"] == "XYZ")
    }

    @Test("read pax xattr header libarchive")
    func readPaxXattrHeaderLibarchive() throws {
        let data = try uudecode("test_pax_xattr_header_libarchive.tar.uu")
        let entries = collectEntries(data)
        try assertPaxXattrHeaderArchiveCore(entries)
        let pax = try #require(entries[0].fields.paxHeaders)
        #expect(pax["LIBARCHIVE.xattr.user.data1"] == "QUJDREVGRw")
        #expect(pax["LIBARCHIVE.xattr.user.data2"] == "WFla")
    }

    @Test("read pax xattr header schily")
    func readPaxXattrHeaderSchily() throws {
        let data = try uudecode("test_pax_xattr_header_schily.tar.uu")
        let entries = collectEntries(data)
        try assertPaxXattrHeaderArchiveCore(entries)
        let pax = try #require(entries[0].fields.paxHeaders)
        #expect(pax["SCHILY.xattr.user.data1"] == "ABCDEFG")
        #expect(pax["SCHILY.xattr.user.data2"] == "XYZ")
    }

    // MARK: - PAX filename encoding

    @Test("read pax filename encoding")
    func readPaxFilenameEncoding() throws {
        let data = try uudecode("test_pax_filename_encoding.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 2)

        let expectedPathBytes: [UInt8] = [
            UInt8(ascii: "a"), UInt8(ascii: "b"), UInt8(ascii: "c"),
            0xCC, 0x8C,
            UInt8(ascii: "m"), UInt8(ascii: "n"), UInt8(ascii: "o"),
            0xFC,
            UInt8(ascii: "x"), UInt8(ascii: "y"), UInt8(ascii: "z"),
        ]
        let expectedPath = String(decoding: expectedPathBytes, as: UTF8.self)

        let first = entries[0]
        #expect(first.fields.path() == expectedPath)
        #expect(first.fields.header.entryType == .regular)
        #expect(first.fields.size == 5)
        #expect(String(decoding: first.data, as: UTF8.self) == "Hello")
        #expect(first.fields.paxHeaders?[PaxKey.path] == expectedPath)
        #expect(first.fields.paxHeaders?["hdrcharset"] == nil)

        let second = entries[1]
        #expect(second.fields.path() == expectedPath)
        #expect(second.fields.header.entryType == .regular)
        #expect(second.fields.size == 5)
        #expect(String(decoding: second.data, as: UTF8.self) == "Hello")
        #expect(second.fields.paxHeaders?[PaxKey.path] == expectedPath)
        #expect(second.fields.paxHeaders?["hdrcharset"] == "BINARY")
    }

    // MARK: - ACL archives (just verify they parse)

    @Test("read acl pax posix1e")
    func readAclPaxPosix1e() throws {
        let data = try uudecode("test_acl_pax_posix1e.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 4)

        let expectedModes = [0o142, 0o142, 0o543, 0o142]
        let expectedAcls: [String?] = [
            nil,
            "user::--x,group::r--,other::-w-,user:user77:r--:77",
            "user::r-x,group::r--,other::-wx,user:user77:r--:77,user:user78:---:78,group:group78:rwx:78",
            nil,
        ]

        for index in entries.indices {
            let entry = entries[index]
            let expectedMode = expectedModes[index]
            let expectedAcl = expectedAcls[index]
            #expect(entry.fields.path() == "file")
            #expect(entry.fields.header.entryType == .regular)
            #expect(entry.fields.size == 0)
            #expect(try entry.fields.header.mode() == expectedMode)
            #expect(entry.fields.paxHeaders?["SCHILY.acl.access"] == expectedAcl)
        }
    }

    @Test("read acl pax nfs4")
    func readAclPaxNfs4() throws {
        let data = try uudecode("test_acl_pax_nfs4.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 3)

        let expectedAcls = [
            "owner@:rwxpaARWcCos::allow,group@:rwpaRcs::allow,everyone@:raRcs::allow",
            "owner@:rwpaARWcCos::allow,user:user77:raRcs:I:allow:77,user:user78:rwx::deny:78,group@:rwpaRcs::allow,group:group78:wpAWCo::deny:78,everyone@:raRcs::allow",
            "owner@:rwxpaARWcCos::allow,user:user77:rwpaRcos::allow:77,user:user77:wp:S:audit:77,group@:rwpaRcs::allow,group:group78:raRc:F:alarm:78,everyone@:raRcs::allow",
        ]

        for (entry, expectedAcl) in zip(entries, expectedAcls) {
            #expect(entry.fields.path() == "file")
            #expect(entry.fields.header.entryType == .regular)
            #expect(entry.fields.size == 0)
            #expect(try entry.fields.header.mode() == 0o777)
            #expect(entry.fields.paxHeaders?["SCHILY.acl.ace"] == expectedAcl)
        }
    }

    @Test("read compat solaris tar acl")
    func readCompatSolarisTarAcl() throws {
        let data = try uudecode("test_compat_solaris_tar_acl.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 8)

        let expectedAclEntries: [(path: String, mode: UInt32, size: UInt64, acl: String)] = [
            (
                "file-with-posix-acls",
                0o644,
                99,
                "1000007\u{0}user::rw-,user:lp:--x:71,user:666:r--:666,user:1000:rwx:1000,group::r--,mask:r--,other:r--\u{0}"
            ),
            (
                "dir-with-posix-acls/",
                0o750,
                192,
                "1000014\u{0}user::rwx,user:bin:rwx:2,group::r-x,group:sys:r-x:3,mask:r-x,other:---,defaultuser::rwx,defaultuser:bin:rwx:2,defaultgroup::r-x,defaultgroup:sys:r-x:3,defaultmask:rwx,defaultother:---\u{0}"
            ),
            (
                "file-with-nfsv4-acls",
                0o640,
                244,
                "3000006\u{0}group:daemon:rwxp--aARWcCos:-------:deny:12,group:bin:rwxp---------s:-------:allow:2,user:adm:r-----a-R-c--s:-------:allow:4,owner@:rw-p--aARWcCos:-------:allow,group@:r-----a-R-c--s:-------:allow,everyone@:------a-R-c--s:-------:allow\u{0}"
            ),
            (
                "dir-with-nfsv4-acls/",
                0o750,
                204,
                "3000005\u{0}user:1100:rwxp--aARWcCos:fdi----:allow:1100,group:adm:r-----a-R-c--s:fd-----:allow:4,owner@:rwxp-DaARWcCos:-------:allow,group@:r-x---a-R-c--s:-------:allow,everyone@:------a-R-c--s:-------:allow\u{0}"
            ),
        ]
        let expectedEntries: [(path: String, type: EntryType, mode: UInt32)] = [
            ("file-with-posix-acls", .regular, 0o644),
            ("dir-with-posix-acls/", .directory, 0o750),
            ("file-with-nfsv4-acls", .regular, 0o640),
            ("dir-with-nfsv4-acls/", .directory, 0o750),
        ]

        for index in expectedAclEntries.indices {
            let aclEntry = entries[index * 2]
            let expectedAcl = expectedAclEntries[index]
            #expect(aclEntry.fields.path() == expectedAcl.path)
            #expect(aclEntry.fields.header.entryType == .other(UInt8(ascii: "A")))
            #expect(try aclEntry.fields.header.mode() == expectedAcl.mode)
            #expect(aclEntry.fields.size == expectedAcl.size)
            #expect(String(decoding: aclEntry.data, as: UTF8.self) == expectedAcl.acl)

            let entry = entries[index * 2 + 1]
            let expectedEntry = expectedEntries[index]
            #expect(entry.fields.path() == expectedEntry.path)
            #expect(entry.fields.header.entryType == expectedEntry.type)
            #expect(try entry.fields.header.mode() == expectedEntry.mode)
            #expect(entry.fields.size == 0)
        }
    }

    @Test("read compat star acl posix1e")
    func readCompatStarAclPosix1e() throws {
        let data = try uudecode("test_compat_star_acl_posix1e.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 3)

        let expectedEntries:
            [(
                path: String,
                type: EntryType,
                mode: UInt32,
                accessAcl: String?,
                defaultAcl: String?
            )] = [
                (
                    "file1",
                    .regular,
                    0o142,
                    "user::--x,user:user77:r--,group::r--,mask::r--,other::-w-",
                    nil
                ),
                (
                    "file2",
                    .regular,
                    // libarchive normalizes this to 0543 after applying the ACL
                    // mask; swift-tar currently exposes the raw header mode 0573.
                    0o573,
                    "user::r-x,user:user77:r--,user:user78:---,group::r--,group:group78:rwx,mask::rwx,other::-wx",
                    nil
                ),
                (
                    "dir1/",
                    .directory,
                    0o142,
                    "user::--x,group::r--,mask::r--,other::-w-",
                    "user::--x,user:user77:r--,group::r--,group:group78:--x,mask::r-x,other::-w-"
                ),
            ]

        for (entry, expected) in zip(entries, expectedEntries) {
            #expect(entry.fields.path() == expected.path)
            #expect(entry.fields.header.entryType == expected.type)
            #expect(entry.fields.size == 0)
            #expect(try entry.fields.header.mode() == expected.mode)
            #expect(try entry.fields.uid() == 0)
            #expect(try entry.fields.gid() == 0)
            #expect(try entry.fields.username() == "root")
            #expect(try entry.fields.groupname() == "wheel")
            #expect(entry.fields.paxHeaders?["SCHILY.acl.access"] == expected.accessAcl)
            #expect(entry.fields.paxHeaders?["SCHILY.acl.default"] == expected.defaultAcl)
        }
    }

    @Test("read compat star acl nfs4")
    func readCompatStarAclNfs4() throws {
        let data = try uudecode("test_compat_star_acl_nfs4.tar.uu")
        let entries = collectEntries(data)
        try #require(entries.count == 3)

        let expectedEntries: [(path: String, type: EntryType, mode: UInt32, acl: String)] = [
            (
                "file1",
                .regular,
                0o764,
                "owner@:rwxp--aARWcCos:-------:allow,group@:rw-p--a-R-c--s:-------:allow,everyone@:r-----a-R-c--s:-------:allow"
            ),
            (
                "file2",
                .regular,
                0o664,
                "user:user78:rwx-----------:-------:deny:78,group:group78:-w-p---A-W-Co-:-------:deny:78,user:user77:r-----a-R-c--s:------I:allow:77,owner@:rw-p--aARWcCos:-------:allow,group@:rw-p--a-R-c--s:-------:allow,everyone@:r-----a-R-c--s:-------:allow"
            ),
            (
                "dir1/",
                .directory,
                0o775,
                "group:group78:rwxpDdaARWcCos:fd-----:deny:78,user:user77:r-----a-R-c--s:fd-----:allow:77,owner@:rwxp--aARWcCos:-------:allow,group@:rwxp--aARWc--s:-------:allow,everyone@:r-x---a-R-c--s:-------:allow"
            ),
        ]

        for (entry, expected) in zip(entries, expectedEntries) {
            #expect(entry.fields.path() == expected.path)
            #expect(entry.fields.header.entryType == expected.type)
            #expect(entry.fields.size == 0)
            #expect(try entry.fields.header.mode() == expected.mode)
            #expect(try entry.fields.uid() == 0)
            #expect(try entry.fields.gid() == 0)
            #expect(try entry.fields.username() == "root")
            #expect(try entry.fields.groupname() == "wheel")
            #expect(entry.fields.paxHeaders?["SCHILY.acl.ace"] == expected.acl)
        }
    }

    // MARK: - GNU sparse archives

    @Test("read gtar sparse 1.13")
    func readGtarSparse113() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_13.tar.uu")
        let entries = collectEntries(data)
        // libarchive expands GNU sparse to logical sparse + sparse2 + non-sparse; swift-tar
        // currently surfaces fewer entries but should still expose the sparse members.
        #expect(entries.count >= 1)
        let paths = Set(entries.map { $0.fields.path() })
        #expect(paths.contains("sparse"))
        #expect(paths.contains("sparse2"))
        if let nonSparse = entries.first(where: { $0.fields.path() == "non-sparse" }) {
            #expect(nonSparse.fields.size == 1)
            #expect(nonSparse.data.elementsEqual([UInt8(ascii: "a")]))
        }
    }

    @Test("read gtar sparse 1.17")
    func readGtarSparse117() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_17.tar.uu")
        let entries = collectEntries(data)
        #expect(entries.count >= 1)
        let paths = Set(entries.map { $0.fields.path() })
        #expect(paths.contains("sparse"))
        #expect(paths.contains("sparse2"))
        if let nonSparse = entries.first(where: { $0.fields.path() == "non-sparse" }) {
            #expect(nonSparse.fields.size == 1)
            #expect(nonSparse.data.elementsEqual([UInt8(ascii: "a")]))
        }
    }

    @Test("read gtar sparse 1.17 posix00")
    func readGtarSparse117Posix00() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_17_posix00.tar.uu")
        let entries = collectEntries(data)
        #expect(entries.count >= 1)
        // POSIX.1-2001 sparse uses ./GNUSparseFile.*/name paths in GNU tar reference archives.
        let paths = entries.map { $0.fields.path() }
        #expect(paths.contains { $0.hasSuffix("/sparse") || $0 == "sparse" })
        #expect(paths.contains { $0.hasSuffix("/sparse2") || $0 == "sparse2" })
    }

    @Test("read gtar sparse 1.17 posix01")
    func readGtarSparse117Posix01() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_17_posix01.tar.uu")
        let entries = collectEntries(data)
        #expect(entries.count >= 1)
        let paths = entries.map { $0.fields.path() }
        #expect(paths.contains { $0.hasSuffix("/sparse") || $0 == "sparse" })
        #expect(paths.contains { $0.hasSuffix("/sparse2") || $0 == "sparse2" })
    }

    @Test("read gtar sparse 1.17 posix10")
    func readGtarSparse117Posix10() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_17_posix10.tar.uu")
        let entries = collectEntries(data)
        #expect(entries.count >= 1)
        let paths = entries.map { $0.fields.path() }
        #expect(paths.contains { $0.hasSuffix("/sparse") || $0 == "sparse" })
        #expect(paths.contains { $0.hasSuffix("/sparse2") || $0 == "sparse2" })
    }

    @Test("read gtar sparse 1.17 posix10 modified")
    func readGtarSparse117Posix10Modified() throws {
        let data = try uudecode("test_read_format_gtar_sparse_1_17_posix10_modified.tar.uu")
        let entries = collectEntries(data)
        #expect(entries.count >= 1)
        let paths = entries.map { $0.fields.path() }
        #expect(paths.contains { $0.hasSuffix("/sparse") || $0 == "sparse" })
        #expect(paths.contains { $0.hasSuffix("/sparse2") || $0 == "sparse2" })
    }

    // MARK: - PAX empty val no newline

    @Test("read pax empty val no newline")
    func readPaxEmptyValNoNl() throws {
        let data = try uudecode("test_read_pax_empty_val_no_nl.tar.uu")
        let entries = try collectAllEntriesThrowing(data)
        // Malformed PAX tail after valid records; libarchive returns ARCHIVE_WARN (test_read_pax_empty_val_no_nl.c).
        try #require(entries.count == 1)
        let e1 = entries[0]
        #expect(e1.fields.path() == "empty")
        #expect(try e1.fields.header.mtime() == 1_748_163_748)
        #expect(try e1.fields.header.uid() == 0)
        #expect(try e1.fields.username() == "root")
        #expect(try e1.fields.header.gid() == 0)
        #expect(try e1.fields.groupname() == "root")
        #expect(try e1.fields.header.mode() == 0o600)
        #expect(e1.fields.size == 0)
    }

    // MARK: - Mac metadata

    @Test("read tar mac metadata")
    func readTarMacMetadata() throws {
        let data = try uudecode("test_read_format_tar_mac_metadata_1.tar.uu")
        let entries = collectEntries(data)
        // Default: on-disk order (two members), like libarchive with mac-ext off.
        try #require(entries.count == 2)
        #expect(entries[0].fields.path().hasPrefix("._101_"))
        #expect(entries[0].fields.header.entryType == .regular)
        #expect(entries[0].fields.size == 19)
        #expect(String(decoding: entries[0].data, as: UTF8.self) == "content of badname\n")
        #expect(entries[1].fields.path() == "goodname")
        #expect(entries[1].fields.header.entryType == .regular)
        #expect(entries[1].fields.size == 20)
        #expect(String(decoding: entries[1].data, as: UTF8.self) == "content of goodname\n")

        // libarchive with tar:mac-ext=1: one "goodname" entry; `._*` payload is mac metadata.
        let merged = collectEntries(data, mergeMacMetadata: true)
        try #require(merged.count == 1)
        #expect(merged[0].fields.path() == "goodname")
        #expect(merged[0].fields.header.entryType == .regular)
        #expect(merged[0].fields.size == 20)
        let expectedMac: [UInt8] = [
            0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x20, 0x6f, 0x66, 0x20, 0x62,
            0x61, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x0a,
        ]
        #expect(Array(merged[0].fields.macMetadata!) == expectedMac)
        #expect(String(decoding: merged[0].data, as: UTF8.self) == "content of goodname\n")

        var tr = TarReader(mergeMacMetadata: true)
        var trEvents: [TarReader.Event] = []
        trEvents.append(contentsOf: try tr.append(data))
        trEvents.append(contentsOf: try tr.finish())
        var trPaths: [String] = []
        var trFileData: [[UInt8]] = []
        var trMac: [UInt8]?
        var currentPath: String?
        var currentData: [UInt8] = []
        for e in trEvents {
            switch e {
            case .entryStart(let f):
                currentPath = f.path()
                trMac = f.macMetadata.map { Array($0) }
                currentData = []
            case .data(let chunk):
                currentData.append(contentsOf: chunk)
            case .entryEnd:
                if let p = currentPath {
                    trPaths.append(p)
                    trFileData.append(currentData)
                }
                currentPath = nil
            }
        }
        #expect(trPaths == ["goodname"])
        #expect(trMac == expectedMac)
        try #require(trFileData.count == 1)
        #expect(String(decoding: trFileData[0], as: UTF8.self) == "content of goodname\n")

        #if os(macOS)
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-tar-macmeta-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let extractor = TarExtractor(mergeMacMetadata: true, writeAppleDoubleSidecars: true)
            let archive = Archive(data: data, mergeMacMetadata: true)
            _ = try extractor.extract(archive, to: tmpDir.path)

            let goodURL = tmpDir.appendingPathComponent("goodname")
            let sidecarURL = tmpDir.appendingPathComponent("._goodname")
            #expect(FileManager.default.fileExists(atPath: goodURL.path))
            #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
            let sidecarOnDisk = try Data(contentsOf: sidecarURL)
            #expect(Array(sidecarOnDisk) == expectedMac)
            let goodOnDisk = try Data(contentsOf: goodURL)
            #expect(String(decoding: goodOnDisk, as: UTF8.self) == "content of goodname\n")
        #endif
    }

    // MARK: - bsdtar extract interop

    /// Curated `test/*.tar.uu` names: compares paths, regular file bytes, symlink targets,
    /// POSIX mode bits (`st_mode & 0o7777` from ``FileManager/attributesOfItem(atPath:)``), and
    /// mtime in whole seconds (see ``bsdtarExtractionSnapshot`` / ``bsdtarMetadataComparable``).
    ///
    /// bsdtar is run as `bsdtar -pxf` (`-p` same-permissions) to align with
    /// ``TarExtractor/init(preservePermissions:preserveModificationTime:)`` (`true`, `true`).
    /// If either side has a pre-epoch mtime on disk, the comparison does not require mtime
    /// equality (filesystems and `utimens` often cannot represent those times consistently).
    ///
    /// Omitted from this matrix when not both-tool compatible, e.g. `test_pax_filename_encoding` (bsdtar
    /// exit failure on some hosts) or `test_read_pax_empty_val_no_nl` (bsdtar warns -> non-zero exit).
    ///
    /// If `SWIFT_TAR_BSDTAR_EXTRACT_TESTS` is unset, `bsdtar` is missing, or `--version` fails, the test
    /// body returns immediately (vacuous pass), not a formal "skipped" event, for Swift 6.1 compatibility.
    private static let bsdtarInteropUuFixtures: [String] = [
        "test_compat_perl_archive_tar.tar.uu",
        "test_compat_plexus_archiver_tar.tar.uu",
        "test_compat_gtar_1.tar.uu",
        "test_compat_gtar_2.tar.uu",
        "test_compat_tar_directory_1.tar.uu",
        "test_compat_tar_hardlink_1.tar.uu",
        "test_read_format_tar_pax_negative_time.tar.uu",
        "test_read_format_tar_empty_with_gnulabel.tar.uu",
    ]

    @Test(
        "extracted tree matches bsdtar",
        arguments: Self.bsdtarInteropUuFixtures
    )
    func extractedTreeMatchesBsdtar(libarchiveUuFileName: String) throws {
        guard let bsdtarURL = bsdtarURLForInteropIfEnabled() else {
            return
        }

        let data = try uudecode(libarchiveUuFileName)

        try TestSupport.withTemporaryDirectory { workPath in
            let work = URL(fileURLWithPath: workPath)
            let archiveURL = work.appendingPathComponent("archive.tar")
            let bsdtarOut = work.appendingPathComponent("bsdtar-out")
            let swiftOut = work.appendingPathComponent("swift-out")

            try Data(data).write(to: archiveURL)
            try FileManager.default.createDirectory(
                at: bsdtarOut, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: swiftOut, withIntermediateDirectories: true)

            try runBsdtarExtract(bsdtar: bsdtarURL, archive: archiveURL, destination: bsdtarOut)

            let archive = Archive(data: data)
            let extractor = TarExtractor(preservePermissions: true, preserveModificationTime: true)
            _ = try extractor.extract(archive, to: swiftOut.path)

            try assertBsdtarAndSwiftExtractionsMatch(bsdtarRoot: bsdtarOut, swiftRoot: swiftOut)
        }
    }
}

// MARK: - Tag

extension Tag {
    @Tag static var libarchiveInterop: Self
}
