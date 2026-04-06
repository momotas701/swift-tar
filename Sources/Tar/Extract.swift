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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#elseif os(Windows)
    import WinSDK
    import ucrt
#elseif os(WASI)
    import WASILibc
#elseif hasFeature(Embedded)
    // Bare-metal Embedded targets do not provide the filesystem APIs that the
    // extractor implementation relies on.
#else
    #error("Unsupported Platform")
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android) || os(WASI)
    private typealias StreamingExtractorPlatform = UnixPlatform
#elseif os(Windows)
    private typealias StreamingExtractorPlatform = WindowsPlatform
#elseif hasFeature(Embedded)
    private typealias StreamingExtractorPlatform = UnsupportedPlatform
#endif

/// Extracts tar archives onto the local filesystem.
///
/// - leading `/` and `./` path components are ignored
/// - entries containing `..` are skipped
/// - intermediate symlinks are rejected to prevent escaping the destination
/// - regular files, directories, symlinks, and hard links are supported where the platform allows
///
/// Device nodes, FIFOs, and GNU sparse files are currently skipped. On WASI,
/// symlinks and hard links are also skipped.
///
/// Use ``TarExtractor/mergeMacMetadata`` with ``Archive/mergeMacMetadata`` (or set the extractor flag
/// alone) to collapse `._*` AppleDouble members; on Apple platforms, ``TarExtractor/writeAppleDoubleSidecars``
/// writes `._basename` next to extracted files when ``EntryFields/macMetadata`` is present.
///
/// Example:
/// ```swift
/// import Tar
///
/// let archive = Archive(data: archiveBytes)
/// let result = try TarExtractor().extract(archive, to: "output-directory")
/// print(result.extractedEntries)
/// ```
///
/// Streaming example:
/// ```swift
/// import Tar
///
/// var reader = TarReader()
/// var extractor = try TarExtractor().streamingExtractor(to: "output-directory")
///
/// for chunk in chunks {
///     let events = try reader.append(chunk)
///     try extractor.consume(events)
/// }
///
/// let finalEvents = try reader.finish()
/// try extractor.consume(finalEvents)
///
/// let result = try extractor.finish()
/// print(result.extractedEntries)
/// ```
public struct TarExtractor: Sendable {
    /// Summary of an extraction run.
    public struct Result: Sendable {
        /// Number of archive entries written to disk.
        public var extractedEntries: Int
        /// Number of archive entries skipped for security or unsupported-kind reasons.
        public var skippedEntries: Int

        internal init() {
            self.extractedEntries = 0
            self.skippedEntries = 0
        }
    }

    /// Whether existing files or links should be replaced.
    public var overwrite: Bool

    /// Whether to preserve special permission bits from the archive.
    public var preservePermissions: Bool

    /// Whether to restore modification time for files and directories.
    public var preserveModificationTime: Bool

    /// When true, reading via ``extract(_:to:)`` or ``StreamingExtractor/consume(contentsOfFileAtPath:chunkSize:)``
    /// merges AppleDouble `._*` sidecars into the following entry (see ``Archive/mergeMacMetadata``).
    public var mergeMacMetadata: Bool

    /// When true (default on Apple platforms), writes an AppleDouble companion file (`._basename`) next to
    /// extracted regular files that carry ``EntryFields/macMetadata``. Ignored on non-Apple platforms.
    public var writeAppleDoubleSidecars: Bool

    public init(
        overwrite: Bool = true,
        preservePermissions: Bool = false,
        preserveModificationTime: Bool = true,
        mergeMacMetadata: Bool = false,
        writeAppleDoubleSidecars: Bool? = nil
    ) {
        self.overwrite = overwrite
        self.preservePermissions = preservePermissions
        self.preserveModificationTime = preserveModificationTime
        self.mergeMacMetadata = mergeMacMetadata
        #if canImport(Darwin) && !os(WASI)
            self.writeAppleDoubleSidecars = writeAppleDoubleSidecars ?? true
        #else
            self.writeAppleDoubleSidecars = writeAppleDoubleSidecars ?? false
        #endif
    }

    /// A stateful extractor that consumes ``TarReader/Event`` values.
    ///
    /// Use this when tar bytes arrive incrementally and you want to extract
    /// entries without buffering the entire archive in memory. The expected
    /// call order is:
    ///
    /// 1. create the extractor with ``TarExtractor/streamingExtractor(to:)``
    /// 2. feed zero or more batches of ``TarReader/Event`` values via ``consume(_:)-(TarReader.Event)``
    ///    or ``consume(_:)-(S)``
    /// 3. call ``finish()`` after the reader has emitted all final events
    ///
    /// Each entry must be observed as `.entryStart`, then zero or more `.data`
    /// events, then `.entryEnd`. That contract is naturally satisfied when the
    /// events come from ``TarReader``.
    ///
    /// Example:
    /// ```swift
    /// var reader = TarReader()
    /// var extractor = try TarExtractor().streamingExtractor(to: "output-directory")
    ///
    /// try extractor.consume(reader.append(chunk))
    /// try extractor.consume(reader.finish())
    /// let result = try extractor.finish()
    /// ```
    ///
    /// You can also stream directly from a tar file on disk:
    /// ```swift
    /// var extractor = try TarExtractor().streamingExtractor(to: "output-directory")
    /// try extractor.consume(contentsOfFileAtPath: "archive.tar")
    /// let result = try extractor.finish()
    /// ```
    public struct StreamingExtractor: @unchecked Sendable {
        fileprivate typealias Platform = StreamingExtractorPlatform
        private var extractor: ExtractorState
        private let configuration: TarExtractor
        private var isFinished = false

        fileprivate init(configuration: TarExtractor, destination: String) throws(TarError) {
            var extractor = ExtractorState(platform: Platform(configuration: configuration))
            try extractor.prepare(to: destination)
            self.extractor = extractor
            self.configuration = configuration
        }

        /// Consumes one streaming reader event.
        ///
        /// This advances the extractor state machine by one step. Passing an
        /// event sequence that does not follow TarReader's `.entryStart`,
        /// `.data*`, `.entryEnd` contract throws(TarError) ``TarError``.
        ///
        /// Example:
        /// ```swift
        /// try extractor.consume(.entryStart(fields))
        /// ```
        public mutating func consume(_ event: TarReader.Event) throws(TarError) {
            guard !isFinished else {
                throw TarError("extractor is already finished")
            }
            switch event {
            case .entryStart(let fields):
                try extractor.startEntry(fields)
            case .data(let chunk):
                try extractor.appendData(chunk)
            case .entryEnd:
                try extractor.finishEntry()
            }
        }

        /// Consumes multiple streaming reader events.
        ///
        /// This is the usual integration point with ``TarReader/append(_:)`` and
        /// ``TarReader/finish()`` because both APIs already return `[Event]`.
        ///
        /// Example:
        /// ```swift
        /// try extractor.consume(reader.append(chunk))
        /// ```
        public mutating func consume<S: Sequence>(_ events: S) throws(TarError)
        where S.Element == TarReader.Event {
            for event in events {
                try consume(event)
            }
        }

        /// Reads a tar file incrementally from disk and consumes it through a local reader.
        ///
        /// This is a convenience for command-line tools and other file-based
        /// extraction flows that still want to exercise the streaming parser.
        ///
        /// - Parameters:
        ///   - path: Path to the tar file on disk.
        ///   - chunkSize: Maximum number of bytes to read per chunk.
        ///
        /// Example:
        /// ```swift
        /// var extractor = try TarExtractor().streamingExtractor(to: "output-directory")
        /// try extractor.consume(contentsOfFileAtPath: "archive.tar", chunkSize: 16 * 1024)
        /// let result = try extractor.finish()
        /// ```
        public mutating func consume(
            contentsOfFileAtPath path: String,
            chunkSize: Int = 64 * 1024
        ) throws(TarError) {
            guard !isFinished else {
                throw TarError("extractor is already finished")
            }
            guard chunkSize > 0 else {
                throw TarError("chunkSize must be greater than zero")
            }

            var reader = TarReader(
                readConcatenatedArchives: false,
                mergeMacMetadata: configuration.mergeMacMetadata
            )
            try Platform.readFileIncrementally(atPath: path, chunkSize: chunkSize) {
                chunk throws(TarError) in
                try consume(reader.append(chunk))
            }
            try consume(reader.finish())
        }

        /// Finalizes extraction and returns the extraction summary.
        ///
        /// Call this only after all reader events have been consumed. Calling it
        /// while an entry is still open throws(TarError) ``TarError``.
        ///
        /// Example:
        /// ```swift
        /// let result = try extractor.finish()
        /// ```
        public mutating func finish() throws(TarError) -> Result {
            guard !isFinished else {
                throw TarError("extractor is already finished")
            }
            isFinished = true
            return try extractor.finish()
        }
    }

    /// Creates a streaming extractor for `destination`.
    ///
    /// The destination directory is prepared immediately, but archive contents
    /// are only written once events are consumed.
    ///
    /// Example:
    /// ```swift
    /// var extractor = try TarExtractor().streamingExtractor(to: "output-directory")
    /// ```
    public func streamingExtractor(to destination: String) throws(TarError) -> StreamingExtractor {
        try StreamingExtractor(configuration: self, destination: destination)
    }

    /// Extracts an archive into `destination`.
    ///
    /// - Parameter archive: The archive to extract.
    /// - Parameter destination: The destination directory. It will be created if needed.
    /// - Returns: A count of extracted and skipped entries.
    ///
    /// Example:
    /// ```swift
    /// let result = try TarExtractor().extract(archive, to: "output-directory")
    /// ```
    public func extract(
        _ archive: Archive,
        to destination: String
    ) throws(TarError) -> Result {
        let archiveToRead = Archive(
            data: archive.data,
            readConcatenatedArchives: archive.readConcatenatedArchives,
            mergeMacMetadata: archive.mergeMacMetadata || mergeMacMetadata
        )
        var extractor = try streamingExtractor(to: destination)
        var iterator = archiveToRead.makeIterator()
        while let entry = try iterator.nextEntry() {
            try extractor.consume(.entryStart(entry.fields))
            try extractor.consume(.data(entry.data))
            try extractor.consume(.entryEnd)
        }
        return try extractor.finish()
    }
}

/// Filesystem operations that vary by platform while extraction control flow stays shared.
///
/// ``_ExtractorState`` owns archive traversal, per-entry state, and the policy for
/// counting extracted versus skipped entries. Platform implementations provide path
/// normalization plus the concrete filesystem primitives needed to materialize entries.
private protocol TarExtractorPlatform {
    /// Platform-native absolute path representation used during extraction.
    associatedtype Path: Sendable
    /// Sanitized path components used to join archive paths onto the extraction root.
    associatedtype PathComponent: Sendable
    /// Handle for an in-progress regular file extraction.
    associatedtype RegularFile: Sendable

    /// User-selected extraction configuration.
    var configuration: TarExtractor { get }

    /// Prepares and canonicalizes the extraction root for `destination`.
    mutating func prepareRoot(from destination: String) throws(TarError) -> Path
    /// Splits an archive path into safe components or returns `nil` when it should be skipped.
    mutating func sanitizedComponents(rawPath: [UInt8]) throws(TarError) -> [PathComponent]?
    /// Joins sanitized path components onto `root`.
    func join(_ root: Path, _ components: [PathComponent]) -> Path
    /// Ensures the directory exists without traversing intermediate symlinks.
    mutating func ensureDirectoryExists(at path: Path) throws(TarError)
    /// Verifies that an existing path is present and is not a symlink.
    mutating func ensureExistingNonSymlink(at path: Path) throws(TarError)
    /// Opens a regular file destination for streaming writes.
    mutating func openRegularFile(at path: Path) throws(TarError) -> RegularFile
    /// Appends a chunk of file data to an in-progress regular file.
    mutating func append<C: Collection<UInt8>>(_ data: C, to file: inout RegularFile)
        throws(TarError) where C.Element == UInt8
    /// Reads a file incrementally and yields byte chunks to shared streaming extraction logic.
    static func readFileIncrementally(
        atPath path: String,
        chunkSize: Int,
        onChunk: ([UInt8]) throws(TarError) -> Void
    ) throws(TarError)
    /// Closes a regular file once all data has been written.
    mutating func closeRegularFile(_ file: RegularFile) throws(TarError)
    /// Extracts a symbolic link, returning `false` when the platform does not support it.
    mutating func extractSymlink(target: [UInt8], to path: Path) throws(TarError) -> Bool
    /// Extracts a hard link, returning `false` when the target is missing or unsupported.
    mutating func extractHardLink(target: Path, to path: Path) throws(TarError) -> Bool
    /// Applies deferred mode and modification time metadata after content creation.
    mutating func applyDeferredMetadata(
        mode: UInt32?, mtime: UInt64?, to path: Path, isDirectory: Bool) throws(TarError)
    /// Orders paths deterministically for deferred directory metadata replay.
    func pathPrecedes(_ lhs: Path, _ rhs: Path) -> Bool
    /// Writes `._basename` AppleDouble data beside an extracted file when supported (Apple platforms).
    mutating func writeAppleDoubleSidecarIfNeeded(
        bytes: [UInt8],
        companionDirectory: Path,
        lastPathComponent: PathComponent
    ) throws(TarError)
}

private struct ExtractorState {
    typealias Platform = StreamingExtractorPlatform
    typealias Path = Platform.Path
    typealias RegularFile = Platform.RegularFile

    struct PendingDirectory {
        let path: Path
        let depth: Int
        let mode: UInt32?
        let mtime: UInt64?
    }

    enum CurrentEntry {
        case skipped
        case regular(
            RegularFile,
            path: Path,
            mode: UInt32?,
            mtime: UInt64?,
            macMetadataBytes: [UInt8]?,
            companionDirectory: Path,
            lastPathComponent: Platform.PathComponent
        )
    }

    var platform: Platform
    private var result = TarExtractor.Result()
    private var pendingDirectories: [PendingDirectory] = []
    private var root: Platform.Path?
    private var currentEntry: CurrentEntry?

    init(platform: Platform) {
        self.platform = platform
    }

    fileprivate var extractorConfiguration: TarExtractor {
        platform.configuration
    }

    mutating func prepare(to destination: String) throws(TarError) {
        guard root == nil else {
            throw TarError("extractor is already prepared")
        }
        self.root = try platform.prepareRoot(from: destination)
    }

    mutating func startEntry(_ fields: EntryFields) throws(TarError) {
        guard let root else {
            throw TarError("extractor is not prepared")
        }
        guard currentEntry == nil else {
            throw TarError("received entryStart before finishing the previous entry")
        }

        let rawPath = fields.pathBytes()
        guard let components = try platform.sanitizedComponents(rawPath: rawPath) else {
            result.skippedEntries += 1
            currentEntry = .skipped
            return
        }

        let destination = platform.join(root, components)
        let companionDirectory: Path
        if components.count > 1 {
            companionDirectory = platform.join(root, Array(components.dropLast()))
        } else {
            companionDirectory = root
        }
        let lastPathComponent = components[components.count - 1]
        let isDirectory =
            fields.header.entryType == .directory || rawPath.last == UInt8(ascii: "/")

        if isDirectory {
            try platform.ensureDirectoryExists(at: destination)
            pendingDirectories.append(
                PendingDirectory(
                    path: destination,
                    depth: components.count,
                    mode: try? fields.header.mode(),
                    mtime: try? fields.mtime()
                )
            )
            result.extractedEntries += 1
            currentEntry = .skipped
            return
        }

        let parent = platform.join(root, Array(components.dropLast()))
        try platform.ensureDirectoryExists(at: parent)

        switch fields.header.entryType {
        case .regular, .continuous, .other:
            let file = try platform.openRegularFile(at: destination)
            let macBytes = fields.macMetadata.map { Array($0) }
            result.extractedEntries += 1
            currentEntry = .regular(
                file,
                path: destination,
                mode: try? fields.header.mode(),
                mtime: try? fields.mtime(),
                macMetadataBytes: macBytes,
                companionDirectory: companionDirectory,
                lastPathComponent: lastPathComponent
            )
        case .symlink:
            guard let target = fields.linkNameBytes(), !target.isEmpty else {
                result.skippedEntries += 1
                currentEntry = .skipped
                return
            }
            let extracted = try platform.extractSymlink(target: target, to: destination)
            if extracted {
                result.extractedEntries += 1
            } else {
                result.skippedEntries += 1
            }
            currentEntry = .skipped
        case .link:
            guard let target = fields.linkNameBytes(),
                let targetComponents = try platform.sanitizedComponents(rawPath: target)
            else {
                result.skippedEntries += 1
                currentEntry = .skipped
                return
            }
            let hardLinkTarget = platform.join(root, targetComponents)
            try platform.ensureExistingNonSymlink(at: parent)
            let extracted = try platform.extractHardLink(
                target: hardLinkTarget, to: destination)
            if extracted {
                result.extractedEntries += 1
            } else {
                result.skippedEntries += 1
            }
            currentEntry = .skipped
        case .directory:
            currentEntry = .skipped
        case .char, .block, .fifo, .gnuSparse:
            result.skippedEntries += 1
            currentEntry = .skipped
        case .gnuLongName, .gnuLongLink, .paxGlobalExtensions, .paxLocalExtensions,
            .gnuVolumeLabel:
            result.skippedEntries += 1
            currentEntry = .skipped
        }
    }

    mutating func appendData<C: Collection<UInt8>>(_ data: C) throws(TarError)
    where C.Element == UInt8 {
        guard let currentEntry else {
            throw TarError("received data outside of an entry")
        }

        switch currentEntry {
        case .skipped:
            return
        case .regular(
            var file, let path, let mode, let mtime, let macMeta, let companionDir, let lastComp
        ):
            try platform.append(data, to: &file)
            self.currentEntry = .regular(
                file, path: path, mode: mode, mtime: mtime,
                macMetadataBytes: macMeta, companionDirectory: companionDir,
                lastPathComponent: lastComp)
        }
    }

    mutating func finishEntry() throws(TarError) {
        guard let currentEntry else {
            throw TarError("received entryEnd without a matching entryStart")
        }
        defer { self.currentEntry = nil }

        switch currentEntry {
        case .skipped:
            return
        case .regular(
            let file, let path, let mode, let mtime, let macMeta, let companionDir, let lastComp
        ):
            try platform.closeRegularFile(file)
            try platform.applyDeferredMetadata(
                mode: mode, mtime: mtime, to: path, isDirectory: false)
            try platform.writeAppleDoubleSidecarIfNeeded(
                bytes: macMeta ?? [],
                companionDirectory: companionDir,
                lastPathComponent: lastComp
            )
        }
    }

    mutating func finish() throws(TarError) -> TarExtractor.Result {
        guard root != nil else {
            throw TarError("extractor is not prepared")
        }
        guard currentEntry == nil else {
            throw TarError("cannot finish extraction while an entry is still open")
        }

        pendingDirectories.sort { lhs, rhs in
            if lhs.depth != rhs.depth {
                return lhs.depth > rhs.depth
            }
            return platform.pathPrecedes(lhs.path, rhs.path)
        }
        for directory in pendingDirectories {
            try platform.applyDeferredMetadata(
                mode: directory.mode,
                mtime: directory.mtime,
                to: directory.path,
                isDirectory: true
            )
        }
        return result
    }
}

private struct UnsupportedPlatform: TarExtractorPlatform, Sendable {
    struct RegularFile: Sendable {}

    let configuration: TarExtractor

    mutating func prepareRoot(from destination: String) throws(TarError) -> [UInt8] {
        _ = destination
        throw unsupported()
    }

    mutating func sanitizedComponents(rawPath: [UInt8]) throws(TarError) -> [[UInt8]]? {
        _ = rawPath
        throw unsupported()
    }

    func join(_ root: [UInt8], _ components: [[UInt8]]) -> [UInt8] {
        _ = components
        return root
    }

    mutating func ensureDirectoryExists(at path: [UInt8]) throws(TarError) {
        _ = path
        throw unsupported()
    }

    mutating func ensureExistingNonSymlink(at path: [UInt8]) throws(TarError) {
        _ = path
        throw unsupported()
    }

    mutating func openRegularFile(at path: [UInt8]) throws(TarError) -> RegularFile {
        _ = path
        throw unsupported()
    }

    mutating func append<C: Collection<UInt8>>(_ data: C, to file: inout RegularFile)
        throws(TarError) where C.Element == UInt8
    {
        _ = data
        _ = file
        throw unsupported()
    }

    static func readFileIncrementally(
        atPath path: String,
        chunkSize: Int,
        onChunk: ([UInt8]) throws(TarError) -> Void
    ) throws(TarError) {
        _ = path
        _ = chunkSize
        _ = onChunk
        throw TarError("TarExtractor is unavailable on Embedded no-OS targets")
    }

    mutating func closeRegularFile(_ file: RegularFile) throws(TarError) {
        _ = file
        throw unsupported()
    }

    mutating func extractSymlink(target: [UInt8], to path: [UInt8]) throws(TarError) -> Bool {
        _ = target
        _ = path
        throw unsupported()
    }

    mutating func extractHardLink(target: [UInt8], to path: [UInt8]) throws(TarError) -> Bool {
        _ = target
        _ = path
        throw unsupported()
    }

    mutating func applyDeferredMetadata(
        mode: UInt32?, mtime: UInt64?, to path: [UInt8], isDirectory: Bool
    ) throws(TarError) {
        _ = mode
        _ = mtime
        _ = path
        _ = isDirectory
        throw unsupported()
    }

    func pathPrecedes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }

    mutating func writeAppleDoubleSidecarIfNeeded(
        bytes: [UInt8],
        companionDirectory: [UInt8],
        lastPathComponent: [UInt8]
    ) throws(TarError) {
        _ = bytes
        _ = companionDirectory
        _ = lastPathComponent
    }

    private func unsupported() -> TarError {
        TarError("TarExtractor is unavailable on Embedded no-OS targets")
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android) || os(WASI)

    #if os(WASI)
        private enum WASIConstants {
            // HACK: O_CREAT and O_EXCL are not ClangImporter friendly
            static let oCreat: Int32 = 1 << 12
            static let oExcl: Int32 = 1 << 14
        }
    #endif

    private struct UnixPlatform: TarExtractorPlatform, Sendable {
        struct RegularFile: Sendable {
            let path: [UInt8]
            let fd: Int32
        }

        let configuration: TarExtractor

        mutating func prepareRoot(from destination: String) throws(TarError) -> [UInt8] {
            let bytes = Array(destination.utf8)
            try ensureDirectoryExists(at: bytes, allowExistingSymlinkComponents: true)
            return try canonicalize(path: bytes)
        }

        mutating func openRegularFile(at path: [UInt8]) throws(TarError) -> RegularFile {
            RegularFile(path: path, fd: try openForWriting(path: path))
        }

        mutating func append<C: Collection<UInt8>>(_ data: C, to file: inout RegularFile)
            throws(TarError)
        where C.Element == UInt8 {
            var bytes = ArraySlice(data)
            while !bytes.isEmpty {
                let written = try writeChunk(fd: file.fd, bytes: bytes)
                bytes = bytes.dropFirst(written)
            }
        }

        mutating func closeRegularFile(_ file: RegularFile) throws(TarError) {
            _ = close(file.fd)
        }

        static func readFileIncrementally(
            atPath path: String,
            chunkSize: Int,
            onChunk: ([UInt8]) throws(TarError) -> Void
        ) throws(TarError) {
            let fd = path.withCString { pointer in
                open(pointer, O_RDONLY)
            }
            guard fd >= 0 else {
                throw TarError("failed to open \(path)")
            }
            defer { _ = close(fd) }

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                    read(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if readCount < 0 {
                    throw TarError("failed to read \(path)")
                }
                if readCount == 0 {
                    break
                }
                try onChunk(Array(buffer.prefix(readCount)))
            }
        }

        mutating func applyDeferredMetadata(
            mode: UInt32?, mtime: UInt64?, to path: [UInt8], isDirectory: Bool
        ) throws(TarError) {
            if let mode {
                try applyMode(mode, to: path)
            }
            if configuration.preserveModificationTime, let mtime {
                try applyModificationTime(mtime, to: path)
            }
        }

        func pathPrecedes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
            lhs.lexicographicallyPrecedes(rhs)
        }

        mutating func extractSymlink(target: [UInt8], to path: [UInt8]) throws(TarError) -> Bool {
            #if os(WASI)
                _ = target
                _ = path
                return false
            #else
                try replaceIfNeeded(at: path)
                try withCString(target) { targetPointer throws(TarError) in
                    try withCString(path) { pathPointer throws(TarError) in
                        if symlink(targetPointer, pathPointer) != 0 {
                            throw TarError(
                                "failed to create symlink at \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                            )
                        }
                    }
                }
                return true
            #endif
        }

        mutating func extractHardLink(target: [UInt8], to path: [UInt8]) throws(TarError) -> Bool {
            #if os(WASI)
                _ = target
                _ = path
                return false
            #else
                guard try fileKind(at: target) != nil else { return false }
                try replaceIfNeeded(at: path)
                try withCString(target) { targetPointer throws(TarError) in
                    try withCString(path) { pathPointer throws(TarError) in
                        if link(targetPointer, pathPointer) != 0 {
                            throw TarError(
                                "failed to create hard link at \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                            )
                        }
                    }
                }
                return true
            #endif
        }

        func sanitizedComponents(rawPath: [UInt8]) throws(TarError) -> [[UInt8]]? {
            var components: [[UInt8]] = []
            var current: [UInt8] = []

            func flush() throws(TarError) -> Bool {
                guard !current.isEmpty else { return true }
                if current.contains(0) {
                    throw TarError("archive path contains NUL")
                }
                if current == [UInt8(ascii: ".")] {
                    current.removeAll(keepingCapacity: true)
                    return true
                }
                if current == [UInt8(ascii: "."), UInt8(ascii: ".")] {
                    return false
                }
                components.append(current)
                current.removeAll(keepingCapacity: true)
                return true
            }

            for byte in rawPath {
                if byte == UInt8(ascii: "/") {
                    guard try flush() else { return nil }
                } else {
                    current.append(byte)
                }
            }
            guard try flush() else { return nil }
            return components.isEmpty ? nil : components
        }

        private func ensureDirectoryExists(
            at path: [UInt8],
            allowExistingSymlinkComponents: Bool = false
        ) throws(TarError) {
            guard !path.isEmpty else { return }

            var partial: [UInt8] = []
            let isAbsolute = path.first == UInt8(ascii: "/")
            if isAbsolute {
                partial = [UInt8(ascii: "/")]
            }

            for component in splitPathComponents(path) {
                if partial.isEmpty || partial == [UInt8(ascii: "/")] {
                    partial = join(partial, [component])
                } else {
                    partial = join(partial, [component])
                }

                switch try fileKind(at: partial) {
                case .directory:
                    continue
                case .symlink:
                    if allowExistingSymlinkComponents {
                        continue
                    }
                    throw TarError(
                        "refusing to follow symlink while creating \(String(decoding: partial, as: UTF8.self))"
                    )
                case .file, .other:
                    throw TarError(
                        "non-directory path component blocks extraction: \(String(decoding: partial, as: UTF8.self))"
                    )
                case nil:
                    try withCString(partial) { pointer throws(TarError) in
                        if mkdir(pointer, mode_t(0o755)) != 0 && errno != EEXIST {
                            throw TarError(
                                "failed to create directory \(String(decoding: partial, as: UTF8.self)): \(lastErrorDescription())"
                            )
                        }
                    }
                }
            }
        }

        mutating func ensureDirectoryExists(at path: [UInt8]) throws(TarError) {
            try ensureDirectoryExists(at: path, allowExistingSymlinkComponents: false)
        }

        func ensureExistingNonSymlink(at path: [UInt8]) throws(TarError) {
            switch try fileKind(at: path) {
            case .directory, .file, .other:
                return
            case .symlink:
                throw TarError(
                    "refusing to follow symlink at \(String(decoding: path, as: UTF8.self))")
            case nil:
                throw TarError("expected path to exist: \(String(decoding: path, as: UTF8.self))")
            }
        }

        private func replaceIfNeeded(at path: [UInt8]) throws(TarError) {
            switch try fileKind(at: path) {
            case nil:
                return
            case .directory:
                throw TarError(
                    "refusing to overwrite directory at \(String(decoding: path, as: UTF8.self))")
            case .file, .symlink, .other:
                guard configuration.overwrite else {
                    throw TarError(
                        "destination already exists: \(String(decoding: path, as: UTF8.self))")
                }
                try withCString(path) { pointer throws(TarError) in
                    if unlink(pointer) != 0 {
                        throw TarError(
                            "failed to remove existing path \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                        )
                    }
                }
            }
        }

        private func openForWriting(path: [UInt8]) throws(TarError) -> Int32 {
            try withCString(path) { pointer throws(TarError) in
                #if os(WASI)
                    let createFlags = O_WRONLY | WASIConstants.oCreat | WASIConstants.oExcl
                #else
                    let createFlags = O_WRONLY | O_CREAT | O_EXCL
                #endif
                let fd = open(pointer, createFlags, mode_t(0o600))
                if fd >= 0 { return fd }

                if errno == EEXIST && configuration.overwrite {
                    if unlink(pointer) != 0 {
                        throw TarError(
                            "failed to replace existing file at \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                        )
                    }
                    let retry = open(pointer, createFlags, mode_t(0o600))
                    if retry >= 0 { return retry }
                }

                throw TarError(
                    "failed to open \(String(decoding: path, as: UTF8.self)) for writing: \(lastErrorDescription())"
                )
            }
        }

        private func writeChunk(fd: Int32, bytes: ArraySlice<UInt8>) throws(TarError) -> Int {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return write(fd, baseAddress, rawBuffer.count)
            }
            guard let written else { return 0 }
            if written < 0 {
                throw TarError("failed to write file contents: \(lastErrorDescription())")
            }
            return written
        }

        private func applyMode(_ mode: UInt32, to path: [UInt8]) throws(TarError) {
            #if os(WASI)
                _ = mode
                _ = path
                return
            #else
                let applied: mode_t
                if configuration.preservePermissions {
                    applied = mode_t(mode)
                } else {
                    applied = mode_t(mode & 0o777)
                }

                try withCString(path) { pointer throws(TarError) in
                    if chmod(pointer, applied) != 0 {
                        throw TarError(
                            "failed to apply mode to \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                        )
                    }
                }
            #endif
        }

        private func applyModificationTime(_ mtime: UInt64, to path: [UInt8]) throws(TarError) {
            var times = [
                timespec(tv_sec: time_t(mtime), tv_nsec: 0),
                timespec(tv_sec: time_t(mtime), tv_nsec: 0),
            ]
            try withCString(path) { pointer throws(TarError) in
                if utimensat(AT_FDCWD, pointer, &times, 0) != 0 {
                    throw TarError(
                        "failed to apply modification time to \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                    )
                }
            }
        }

        private func canonicalize(path: [UInt8]) throws(TarError) -> [UInt8] {
            try withCString(path) { pointer throws(TarError) in
                guard let resolved = realpath(pointer, nil) else {
                    throw TarError(
                        "failed to canonicalize \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                    )
                }
                defer { free(resolved) }
                let bytes = Array(
                    UnsafeBufferPointer(
                        start: UnsafePointer<UInt8>(OpaquePointer(resolved)),
                        count: strlen(resolved)))
                return bytes
            }
        }

        private enum FileKind {
            case file
            case directory
            case symlink
            case other
        }

        private func fileKind(at path: [UInt8]) throws(TarError) -> FileKind? {
            var st = stat()
            return try withCString(path) { pointer throws(TarError) in
                if lstat(pointer, &st) != 0 {
                    if errno == ENOENT {
                        return nil
                    }
                    throw TarError(
                        "failed to inspect \(String(decoding: path, as: UTF8.self)): \(lastErrorDescription())"
                    )
                }
                switch st.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFREG): return .file
                case mode_t(S_IFDIR): return .directory
                case mode_t(S_IFLNK): return .symlink
                default: return .other
                }
            }
        }

        private func splitPathComponents(_ path: [UInt8]) -> [[UInt8]] {
            var components: [[UInt8]] = []
            var current: [UInt8] = []
            for byte in path {
                if byte == UInt8(ascii: "/") {
                    if !current.isEmpty {
                        components.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                } else {
                    current.append(byte)
                }
            }
            if !current.isEmpty {
                components.append(current)
            }
            return components
        }

        func join(_ base: [UInt8], _ components: [[UInt8]]) -> [UInt8] {
            var result = base
            for component in components {
                if result.isEmpty {
                    result.append(contentsOf: component)
                } else if result.last == UInt8(ascii: "/") {
                    result.append(contentsOf: component)
                } else {
                    result.append(UInt8(ascii: "/"))
                    result.append(contentsOf: component)
                }
            }
            return result
        }

        private func withCString<R>(
            _ bytes: [UInt8],
            _ body: (UnsafePointer<CChar>) throws(TarError) -> R
        ) throws(TarError) -> R {
            if bytes.contains(0) {
                throw TarError("path contains NUL")
            }
            var cString = bytes.map { CChar(bitPattern: $0) }
            cString.append(0)
            return try cString.withUnsafeBufferPointer { b throws(TarError) in
                try body(b.baseAddress!)
            }
        }

        private func lastErrorDescription() -> String {
            String(cString: strerror(errno))
        }

        mutating func writeAppleDoubleSidecarIfNeeded(
            bytes: [UInt8],
            companionDirectory: [UInt8],
            lastPathComponent: [UInt8]
        ) throws(TarError) {
            #if canImport(Darwin) && !os(WASI)
                guard configuration.writeAppleDoubleSidecars, !bytes.isEmpty else { return }
                var companionName = [UInt8(ascii: "."), UInt8(ascii: "_")]
                companionName.append(contentsOf: lastPathComponent)
                let companionPath = join(companionDirectory, [companionName])
                try replaceIfNeeded(at: companionPath)
                let fd = try openForWriting(path: companionPath)
                defer { _ = close(fd) }
                var slice = bytes[...]
                while !slice.isEmpty {
                    let written = try writeChunk(fd: fd, bytes: slice)
                    slice = slice.dropFirst(written)
                }
            #else
                _ = bytes
                _ = companionDirectory
                _ = lastPathComponent
            #endif
        }
    }
#elseif os(Windows)
    private struct WindowsPlatform: TarExtractorPlatform, Sendable {
        struct RegularFile: @unchecked Sendable {
            let path: [UInt16]
            let handle: HANDLE
        }

        let configuration: TarExtractor

        init(configuration: TarExtractor) {
            self.configuration = configuration
        }

        mutating func prepareRoot(from destination: String) throws(TarError) -> [UInt16] {
            let destinationPath = try sanitizeWindowsPath(destination)
            try ensureDirectoryExists(at: destinationPath)
            return try fullPath(destinationPath)
        }

        mutating func openRegularFile(at path: [UInt16]) throws(TarError) -> RegularFile {
            try replaceIfNeeded(at: path)
            let handle = try createFileHandle(
                path: path,
                desiredAccess: DWORD(GENERIC_WRITE),
                creationDisposition: DWORD(CREATE_NEW),
                flags: DWORD(FILE_ATTRIBUTE_NORMAL)
            )
            return RegularFile(path: path, handle: handle)
        }

        mutating func append<C: Collection<UInt8>>(_ data: C, to file: inout RegularFile)
            throws(TarError) where C.Element == UInt8
        {
            var slice = ArraySlice(data)
            while !slice.isEmpty {
                let written = try writeChunk(handle: file.handle, bytes: slice)
                slice = slice.dropFirst(written)
            }
        }

        mutating func closeRegularFile(_ file: RegularFile) throws(TarError) {
            CloseHandle(file.handle)
        }

        static func readFileIncrementally(
            atPath path: String,
            chunkSize: Int,
            onChunk: ([UInt8]) throws(TarError) -> Void
        ) throws(TarError) {
            let widePath = Array(path.utf16) + [0]
            let handle = widePath.withUnsafeBufferPointer {
                CreateFileW(
                    $0.baseAddress,
                    DWORD(GENERIC_READ),
                    DWORD(FILE_SHARE_READ),
                    nil,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_ATTRIBUTE_NORMAL),
                    nil
                )
            }
            guard handle != INVALID_HANDLE_VALUE else {
                throw TarError("failed to open \(path)")
            }
            defer { CloseHandle(handle) }

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                var bytesRead: DWORD = 0
                let ok = buffer.withUnsafeMutableBytes { rawBuffer in
                    ReadFile(handle, rawBuffer.baseAddress, DWORD(rawBuffer.count), &bytesRead, nil)
                }
                if !ok {
                    throw TarError("failed to read \(path)")
                }
                if bytesRead == 0 {
                    break
                }
                try onChunk(Array(buffer.prefix(Int(bytesRead))))
            }
        }

        mutating func applyDeferredMetadata(
            mode: UInt32?, mtime: UInt64?, to path: [UInt16], isDirectory: Bool
        ) throws(TarError) {
            if let mode {
                try applyMode(mode, to: path)
            }
            if configuration.preserveModificationTime, let mtime {
                try applyModificationTime(mtime, to: path, isDirectory: isDirectory)
            }
        }

        func pathPrecedes(_ lhs: [UInt16], _ rhs: [UInt16]) -> Bool {
            lhs.lexicographicallyPrecedes(rhs)
        }

        func sanitizedComponents(rawPath: [UInt8]) throws(TarError) -> [[UInt16]]? {
            var components: [[UInt16]] = []
            var current: [UInt8] = []

            func flush() throws(TarError) -> Bool {
                guard !current.isEmpty else { return true }
                if current.contains(0) {
                    throw TarError("archive path contains NUL")
                }
                if current == [UInt8(ascii: ".")] {
                    current.removeAll(keepingCapacity: true)
                    return true
                }
                if current == [UInt8(ascii: "."), UInt8(ascii: ".")] {
                    return false
                }
                components.append(utf16PathComponent(current))
                current.removeAll(keepingCapacity: true)
                return true
            }

            for byte in rawPath {
                if byte == UInt8(ascii: "/") {
                    guard try flush() else { return nil }
                } else {
                    current.append(byte)
                }
            }
            guard try flush() else { return nil }
            return components.isEmpty ? nil : components
        }

        func join(_ base: [UInt16], _ components: [[UInt16]]) -> [UInt16] {
            var path = base
            for component in components {
                if !path.isEmpty, path.last != windowsSeparator {
                    path.append(windowsSeparator)
                }
                path.append(contentsOf: component)
            }
            return path
        }

        func ensureDirectoryExists(at path: [UInt16]) throws(TarError) {
            guard !path.isEmpty else { return }

            var current = windowsPathPrefix(path)
            for component in splitPathComponents(path).dropFirst(pathPrefixComponentCount(path)) {
                if !current.isEmpty, current.last != windowsSeparator {
                    current.append(windowsSeparator)
                }
                current.append(contentsOf: component)

                switch try fileKind(at: current) {
                case .directory:
                    continue
                case .symlink:
                    throw TarError(
                        "refusing to follow symlink while creating \(pathDescription(current))")
                case .file, .other:
                    throw TarError(
                        "non-directory path component blocks extraction: \(pathDescription(current))"
                    )
                case nil:
                    try withWindowsPath(current) { pointer in
                        if !CreateDirectoryW(pointer, nil) {
                            let code = GetLastError()
                            if code != DWORD(ERROR_ALREADY_EXISTS) {
                                throw TarError(
                                    "failed to create directory \(pathDescription(current)): \(lastErrorDescription(code))"
                                )
                            }
                        }
                    }
                }
            }
        }

        private func replaceIfNeeded(at path: [UInt16]) throws(TarError) {
            switch try fileKind(at: path) {
            case nil:
                return
            case .directory:
                throw TarError("refusing to overwrite directory at \(pathDescription(path))")
            case .file, .symlink, .other:
                guard configuration.overwrite else {
                    throw TarError("destination already exists: \(pathDescription(path))")
                }
                try withWindowsPath(path) { pointer in
                    if !DeleteFileW(pointer) {
                        throw TarError(
                            "failed to remove existing path \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                        )
                    }
                }
            }
        }

        mutating func extractSymlink(target: [UInt8], to path: [UInt16]) throws(TarError) -> Bool {
            try replaceIfNeeded(at: path)
            let targetPath = utf16PathComponent(target)
            try withWindowsPath(path) { linkPointer in
                try withWindowsPath(targetPath) { targetPointer in
                    if CreateSymbolicLinkW(linkPointer, targetPointer, 0) == 0 {
                        throw TarError(
                            "failed to create symlink at \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                        )
                    }
                }
            }
            return true
        }

        mutating func extractHardLink(target: [UInt16], to path: [UInt16]) throws(TarError) -> Bool
        {
            guard try fileKind(at: target) != nil else { return false }
            try replaceIfNeeded(at: path)
            try withWindowsPath(path) { linkPointer in
                try withWindowsPath(target) { targetPointer in
                    if !CreateHardLinkW(linkPointer, targetPointer, nil) {
                        throw TarError(
                            "failed to create hard link at \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                        )
                    }
                }
            }
            return true
        }

        mutating func ensureExistingNonSymlink(at path: [UInt16]) throws(TarError) {
            _ = path
        }

        private func applyMode(_ mode: UInt32, to path: [UInt16]) throws(TarError) {
            let writable = mode & 0o200 != 0
            try withWindowsPath(path) { pointer in
                let current = GetFileAttributesW(pointer)
                if current == INVALID_FILE_ATTRIBUTES {
                    throw TarError(
                        "failed to inspect \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
                var updated = current
                if writable {
                    updated &= ~DWORD(FILE_ATTRIBUTE_READONLY)
                } else {
                    updated |= DWORD(FILE_ATTRIBUTE_READONLY)
                }
                if !SetFileAttributesW(pointer, updated) {
                    throw TarError(
                        "failed to apply mode to \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
            }
        }

        private func applyModificationTime(_ mtime: UInt64, to path: [UInt16], isDirectory: Bool)
            throws(TarError)
        {
            let flags =
                isDirectory ? DWORD(FILE_FLAG_BACKUP_SEMANTICS) : DWORD(FILE_ATTRIBUTE_NORMAL)
            let handle = try createFileHandle(
                path: path,
                desiredAccess: DWORD(FILE_WRITE_ATTRIBUTES),
                creationDisposition: DWORD(OPEN_EXISTING),
                flags: flags
            )
            defer { CloseHandle(handle) }

            var fileTime = fileTimeFromUnixSeconds(mtime)
            if !SetFileTime(handle, nil, nil, &fileTime) {
                throw TarError(
                    "failed to apply modification time to \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                )
            }
        }

        private func createFileHandle(
            path: [UInt16],
            desiredAccess: DWORD,
            creationDisposition: DWORD,
            flags: DWORD
        ) throws(TarError) -> HANDLE {
            try withWindowsPath(path) { pointer in
                let handle = CreateFileW(
                    pointer,
                    desiredAccess,
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                    nil,
                    creationDisposition,
                    flags,
                    nil
                )
                guard let handle else {
                    throw TarError(
                        "failed to open \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
                if handle == INVALID_HANDLE_VALUE {
                    throw TarError(
                        "failed to open \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
                return handle
            }
        }

        private func writeChunk(handle: HANDLE, bytes: ArraySlice<UInt8>) throws(TarError) -> Int {
            do {
                return try bytes.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    let chunkSize = min(rawBuffer.count, Int(UInt32.max))
                    var written: DWORD = 0
                    if !WriteFile(handle, baseAddress, DWORD(chunkSize), &written, nil) {
                        throw TarError(
                            "failed to write file contents: \(lastErrorDescription(GetLastError()))"
                        )
                    }
                    return Int(written)
                }
            } catch let error as TarError {
                throw error
            } catch {
                throw TarError(String(describing: error))
            }
        }

        private enum FileKind {
            case file
            case directory
            case symlink
            case other
        }

        private func fileKind(at path: [UInt16]) throws(TarError) -> FileKind? {
            try withWindowsPath(path) { pointer in
                let attributes = GetFileAttributesW(pointer)
                if attributes == INVALID_FILE_ATTRIBUTES {
                    let code = GetLastError()
                    if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
                        return nil
                    }
                    throw TarError(
                        "failed to inspect \(pathDescription(path)): \(lastErrorDescription(code))")
                }
                if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
                    return .symlink
                }
                if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                    return .directory
                }
                return .file
            }
        }

        private func fullPath(_ path: [UInt16]) throws(TarError) -> [UInt16] {
            try withWindowsPath(path) { pointer in
                let needed = GetFullPathNameW(pointer, 0, nil, nil)
                if needed == 0 {
                    throw TarError(
                        "failed to canonicalize \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
                var buffer = [UInt16](repeating: 0, count: Int(needed))
                let written = buffer.withUnsafeMutableBufferPointer {
                    GetFullPathNameW(pointer, DWORD($0.count), $0.baseAddress, nil)
                }
                if written == 0 {
                    throw TarError(
                        "failed to canonicalize \(pathDescription(path)): \(lastErrorDescription(GetLastError()))"
                    )
                }
                return Array(buffer.prefix(Int(written)))
            }
        }

        private func sanitizeWindowsPath(_ path: String) throws(TarError) -> [UInt16] {
            let utf16 = Array(path.utf16)
            guard !utf16.contains(0) else {
                throw TarError("path contains NUL")
            }
            return utf16
        }

        private func utf16PathComponent(_ bytes: [UInt8]) -> [UInt16] {
            Array(String(decoding: bytes, as: UTF8.self).utf16)
        }

        private func withWindowsPath<R>(
            _ path: [UInt16],
            _ body: (UnsafePointer<WCHAR>) throws -> R
        ) throws(TarError) -> R {
            if path.contains(0) {
                throw TarError("path contains NUL")
            }
            let wide = path + [0]
            do {
                return try wide.withUnsafeBufferPointer { buffer in
                    try body(buffer.baseAddress!)
                }
            } catch let error as TarError {
                throw error
            } catch {
                throw TarError(String(describing: error))
            }
        }

        private func splitPathComponents(_ path: [UInt16]) -> [[UInt16]] {
            var components: [[UInt16]] = []
            var current: [UInt16] = []
            for codeUnit in path {
                if codeUnit == windowsSeparator || codeUnit == windowsAltSeparator {
                    if !current.isEmpty {
                        components.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                } else {
                    current.append(codeUnit)
                }
            }
            if !current.isEmpty {
                components.append(current)
            }
            return components
        }

        private func windowsPathPrefix(_ path: [UInt16]) -> [UInt16] {
            if path.count >= 2, path[1] == windowsDriveSeparator {
                return Array(path.prefix(2))
            }
            if path.count >= 2, path[0] == windowsSeparator, path[1] == windowsSeparator {
                let components = splitPathComponents(path)
                if components.count >= 2 {
                    return Array(path.prefix(2 + components[0].count + 1 + components[1].count))
                }
            }
            if path.first == windowsSeparator || path.first == windowsAltSeparator {
                return [windowsSeparator]
            }
            return []
        }

        private func pathPrefixComponentCount(_ path: [UInt16]) -> Int {
            if path.count >= 2, path[1] == windowsDriveSeparator {
                return 1
            }
            if path.count >= 2, path[0] == windowsSeparator, path[1] == windowsSeparator {
                return 2
            }
            return 0
        }

        private func pathDescription(_ path: [UInt16]) -> String {
            String(decoding: path, as: UTF16.self)
        }

        private func lastErrorDescription(_ code: DWORD) -> String {
            String(UInt32(code))
        }

        private func fileTimeFromUnixSeconds(_ seconds: UInt64) -> FILETIME {
            let intervals = (seconds + 11_644_473_600) * 10_000_000
            return FILETIME(
                dwLowDateTime: DWORD(intervals & 0xffff_ffff),
                dwHighDateTime: DWORD(intervals >> 32)
            )
        }

        mutating func writeAppleDoubleSidecarIfNeeded(
            bytes: [UInt8],
            companionDirectory: [UInt16],
            lastPathComponent: [UInt16]
        ) throws(TarError) {
            _ = bytes
            _ = companionDirectory
            _ = lastPathComponent
        }

        private let windowsSeparator: UInt16 = 92
        private let windowsAltSeparator: UInt16 = 47
        private let windowsDriveSeparator: UInt16 = 58
    }
#endif
