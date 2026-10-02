//
//  CloudKitOptOutTests.swift
//  IndigoTests
//
//  With the iCloud entitlement on, SwiftData's default for a configuration is
//  to sync (`.automatic`). The cache models cannot be synced -- they have
//  unique constraints and required attributes -- and a store that is not
//  meant to sync must never be handed the chance. Every configuration the app
//  or its tests build says so out loud.
//
//  The one exception is the seed store, which exists to sync and is DEBUG-only.
//

import XCTest

final class CloudKitOptOutTests: XCTestCase {
    func testEveryModelConfigurationSaysWhetherItSyncs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for folder in ["Indigo", "IndigoTests"] {
            let base = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files where file.lastPathComponent != "CloudKitOptOutTests.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                var rest = text[...]
                while let hit = rest.range(of: "ModelConfiguration(") {
                    let tail = rest[hit.upperBound...]
                    // The call ends at its matching parenthesis.
                    var depth = 1
                    var end = tail.startIndex
                    for index in tail.indices {
                        if tail[index] == "(" { depth += 1 }
                        if tail[index] == ")" { depth -= 1 }
                        if depth == 0 { end = index; break }
                    }
                    let call = tail[tail.startIndex..<end]
                    // `ModelConfiguration(schema:).url` only reads a path.
                    let readsOnlyAURL = call.trimmingCharacters(in: .whitespaces) == "schema: Persistence.schema"
                        || call.trimmingCharacters(in: .whitespaces) == "schema: schema"
                    if !call.contains("cloudKitDatabase") && !readsOnlyAURL {
                        offenders.append("\(file.lastPathComponent): ModelConfiguration(\(call.prefix(60))")
                    }
                    rest = tail[end...]
                }
            }
        }
        XCTAssertEqual(offenders, [], "These would sync when the app is signed for iCloud.")
    }
}
