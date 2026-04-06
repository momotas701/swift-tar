// ListEntries - Reads a tar file from stdin and lists all entries.
//
// Usage: cat archive.tar | swift run ListEntries

import Foundation
import Tar

let inputData = FileHandle.standardInput.readDataToEndOfFile()
let data = Array(inputData)

if data.isEmpty {
    FileHandle.standardError.write(
        Data("Usage: cat archive.tar | swift run ListEntries\n".utf8)
    )
    exit(1)
}

let archive = Archive(data: data)

print(String(format: "%-10s %-8s %-8s %10s %s", "MODE", "UID", "GID", "SIZE", "PATH"))
print(String(repeating: "-", count: 72))

for entry in archive {
    let path = entry.fields.path()
    let mode = (try? entry.fields.header.mode()).map { String(format: "%o", $0) } ?? "------"
    let uid = (try? entry.fields.header.uid()).map { String($0) } ?? "-"
    let gid = (try? entry.fields.header.gid()).map { String($0) } ?? "-"
    let size = (try? entry.fields.header.size()) ?? 0
    let typeIndicator: String
    switch entry.fields.header.entryType {
    case .directory: typeIndicator = "d"
    case .symlink:   typeIndicator = "l"
    case .link:      typeIndicator = "h"
    default:         typeIndicator = "-"
    }

    print("\(typeIndicator)\(mode.padding(toLength: 9, withPad: " ", startingAt: 0)) \(uid.padding(toLength: 8, withPad: " ", startingAt: 0)) \(gid.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(path)")
}
