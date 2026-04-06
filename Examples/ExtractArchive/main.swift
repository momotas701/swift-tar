// ExtractArchive - Reads a tar file from disk and extracts it into a directory.
//
// Usage: swift run ExtractArchive input.tar output-directory

import Foundation
import Tar

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: swift run ExtractArchive input.tar output-directory\n".utf8)
    )
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
var extractor = try TarExtractor().streamingExtractor(to: destination)
try extractor.consume(contentsOfFileAtPath: inputPath, chunkSize: 16 * 1024)
let result = try extractor.finish()

FileHandle.standardError.write(
    Data("Extracted \(result.extractedEntries) entries, skipped \(result.skippedEntries)\n".utf8)
)
