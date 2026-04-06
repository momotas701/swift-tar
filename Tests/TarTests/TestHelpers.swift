import Foundation

@testable import Tar

// MARK: - Archives and PAX helpers

/// Loads test archive data from the Fixtures directory.
func loadArchive(_ name: String) throws -> [UInt8] {
    let filePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    let data = try Data(contentsOf: filePath)
    return [UInt8](data)
}

func encodePaxData(_ extensions: [(key: String, value: [UInt8])]) -> [UInt8] {
    var paxData: [UInt8] = []

    for (key, value) in extensions {
        let keyBytes = [UInt8](key.utf8)
        let restLen = 1 + keyBytes.count + 1 + value.count + 1
        var lenLen = 1
        var maxLen = 10
        while restLen + lenLen >= maxLen {
            lenLen += 1
            maxLen *= 10
        }
        let totalLen = restLen + lenLen

        paxData.append(contentsOf: [UInt8](String(totalLen).utf8))
        paxData.append(UInt8(ascii: " "))
        paxData.append(contentsOf: keyBytes)
        paxData.append(UInt8(ascii: "="))
        paxData.append(contentsOf: value)
        paxData.append(UInt8(ascii: "\n"))
    }

    return paxData
}

func makePaxHeader(entryType: EntryType, data: [UInt8]) -> Header {
    var header = Header(asUstar: ())
    header.entryType = entryType
    header.setSize(UInt64(data.count))
    header.setChecksum()
    return header
}

enum TestSupport {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String

        init(description: String) {
            self.description = description
        }

        init(errno: Int32) {
            self.init(description: String(cString: strerror(errno)))
        }
    }

    /// Creates a unique empty directory and passes its path to `body`. The directory is removed in
    /// `defer` unless `shouldRetain` is set to `true` (e.g. after a failure for inspection).
    static func withTemporaryDirectory<Result>(
        _ body: (String, _ shouldRetain: inout Bool) throws -> Result
    ) throws -> Result {
        #if os(WASI)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-tar-\(UUID().uuidString)")
                .path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            var shouldRetain = false
            defer {
                if !shouldRetain {
                    _ = try? FileManager.default.removeItem(atPath: path)
                }
            }
            return try body(path, &shouldRetain)
        #else
            let tempdir = URL(fileURLWithPath: NSTemporaryDirectory())
            let templatePath = tempdir.appendingPathComponent("swift-tar.XXXXXX")
            var template = [UInt8](templatePath.path.utf8).map { Int8($0) } + [Int8(0)]

            #if os(Windows)
                if _mktemp_s(&template, template.count) != 0 {
                    throw Error(errno: errno)
                }
                if _mkdir(template) != 0 {
                    throw Error(errno: errno)
                }
            #else
                if mkdtemp(&template) == nil {
                    #if os(Android)
                        throw Error(errno: __errno().pointee)
                    #else
                        throw Error(errno: errno)
                    #endif
                }
            #endif

            let path: String
            if let zero = template.firstIndex(of: 0) {
                path = String(
                    decoding: template[..<zero].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } else {
                path = String(decoding: template.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var shouldRetain = false
            defer {
                if !shouldRetain {
                    _ = try? FileManager.default.removeItem(atPath: path)
                }
            }
            return try body(path, &shouldRetain)
        #endif
    }

    /// Same as ``withTemporaryDirectory(_:_:)`` but without a `shouldRetain` out-parameter.
    static func withTemporaryDirectory<Result>(
        _ body: (String) throws -> Result
    ) throws -> Result {
        try withTemporaryDirectory { path, _ in
            try body(path)
        }
    }

    /// Resolves an executable the way a shell `which` would: optional `NAME_EXEC` override, then
    /// directories on `PATH` / `Path` (WasmKit `TestSupport.lookupExecutable`).
    static func which(_ name: String) -> URL? {
        let envName = "\(name.uppercased())_EXEC"
        if let path = ProcessInfo.processInfo.environment[envName] {
            let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(
                name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        #if os(Windows)
            let pathEnvVar = "Path"
            let pathSeparator: Character = ";"
        #else
            let pathEnvVar = "PATH"
            let pathSeparator: Character = ":"
        #endif

        let paths = ProcessInfo.processInfo.environment[pathEnvVar] ?? ""
        let searchPaths = paths.split(separator: pathSeparator).map(String.init)
        for path in searchPaths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
