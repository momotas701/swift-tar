// CreateArchive - Creates a tar archive and writes it to stdout.
//
// Usage: swift run CreateArchive > output.tar

import Foundation
import Tar

var writer = TarWriter(mode: .deterministic)

// Add a text file.
let readmeContents: [UInt8] = Array("Hello from swift-tar!\n".utf8)
var fileHeader = Header(asGnu: ())
fileHeader.entryType = .regular
fileHeader.setSize(UInt64(readmeContents.count))
fileHeader.setMode(0o644)
writer.appendData(header: fileHeader, path: "example/README.txt", data: readmeContents)

// Add a directory.
writer.appendDir(path: "example/subdir/")

// Add another file inside the subdirectory.
let sourceContents: [UInt8] = Array("""
    print("Hello, world!")

    """.utf8)
var srcHeader = Header(asGnu: ())
srcHeader.entryType = .regular
srcHeader.setSize(UInt64(sourceContents.count))
srcHeader.setMode(0o644)
writer.appendData(header: srcHeader, path: "example/subdir/main.swift", data: sourceContents)

// Finalize the archive and get the bytes.
let archiveBytes = writer.finish()

// Write to stdout.
FileHandle.standardOutput.write(Data(archiveBytes))
FileHandle.standardError.write(
    Data("Created archive with 3 entries (\(archiveBytes.count) bytes)\n".utf8)
)
