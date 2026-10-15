//
//  PilotDemandExport.swift
//  IndigoTests
//
//  Freezes the Phase 2 pilot demand set (SHARED-KNOWLEDGE.md §9.7): the
//  starting points and the artists their rows name, from copies of this
//  Mac's Development and Production stores, plus representative identity and
//  coverage cases. Opt-in: `TEST_RUNNER_INDIGO_EXPORT_PILOT=1`. Writes
//  `pilot-demand.json` to the host's temporary directory; the file is then
//  committed under supabase/functions/_shared/testdata with its digest.
//
//  Built from the rows as kept, never from what a device has cached — the
//  same rule the backend shadow follows (decision 4).
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class PilotDemandExport: XCTestCase {
    struct Node: Codable, Hashable, Comparable {
        let id: String
        let kind: String
        let key: String
        let provider: String
        let handle: String
        var mbid: String?
        var why: String
        static func < (l: Node, r: Node) -> Bool { l.id < r.id }
    }
    struct Artist: Codable, Hashable, Comparable {
        let key: String
        var why: String
        static func < (l: Artist, r: Artist) -> Bool { l.key < r.key }
    }

    /// Identity and coverage cases the pilot must carry whatever the rows
    /// hold: a verified spelling pair, namesakes, aliases, a lookalike, a
    /// name and credit route to one artist, known artists, an unknown name.
    static let cases: [(String, String)] = [
        ("Prefuse73", "spelling of Prefuse 73 (verified variation)"),
        ("Prefuse 73", "entry name (Discogs 3722)"),
        ("Hype Williams", "namesakes: the duo (1874027) and the director (82)"),
        ("Anika", "alias pair with Annika Henderson"),
        ("Annika Henderson", "alias pair with Anika"),
        ("Mica Levi", "alias pair with Micachu"),
        ("Micachu", "alias pair with Mica Levi"),
        ("Duenn", "lookalike of Duenn Nyantora; filed-record trap"),
        ("Attilio Novellino", "reached by radio name and by credit"),
        ("Dean Blunt", "known artist; credited as Blunt"),
        ("Joanne Robertson", "known artist reached by credit"),
        ("Zzz Nobody Files This Name", "unknown to the backend"),
    ]

    func testExportThePilotDemandSet() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_EXPORT_PILOT"] == "1",
                          "Set INDIGO_EXPORT_PILOT=1 to export the pilot demand set.")
        let support = StoreLayout.standard.directory
        let asOf = ExplorePeriod.asOf(ExplorePeriod.containing(Date()))
        var nodes: [String: Node] = [:]
        var artists: [String: Artist] = [:]
        for (label, folder) in [("development", support.appendingPathComponent("Development", isDirectory: true)),
                                ("production", support)] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Pilot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for name in ["UserData.store", "Local.store"] {
                for suffix in ["", "-wal", "-shm"] {
                    let from = folder.appendingPathComponent(name + suffix)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                    }
                }
            }
            let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                               local: copy.appendingPathComponent("Local.store"))
            let rows = PersonalInputs.read(context: ModelContext(container), asOf: asOf)
            for origin in ExploreRanker.startingPoints(rows) {
                let node = Node(id: origin.id, kind: origin.kind.rawValue, key: origin.key, provider: origin.providerID ?? "",
                                handle: origin.handle ?? "", mbid: origin.mbid, why: "starting point (\(label))")
                if let held = nodes[node.id] { nodes[node.id]?.why = held.why.contains(label) ? held.why : held.why + ", \(label)" }
                else { nodes[node.id] = node }
            }
            for key in BackendKnowledgeAdapter.artistsWanted(rows, deviceLocal: .empty) {
                if let held = artists[key] { artists[key]?.why = held.why.contains(label) ? held.why : held.why + ", \(label)" }
                else { artists[key] = Artist(key: key, why: "named by the rows (\(label))") }
            }
        }
        for (name, why) in Self.cases {
            let node = MusicNode.artist(name)
            if nodes[node.id] == nil {
                nodes[node.id] = Node(id: node.id, kind: "artist", key: node.key, provider: "", handle: "", mbid: nil, why: "case: \(why)")
            } else {
                nodes[node.id]?.why += "; case: \(why)"
            }
            if artists[node.key] == nil { artists[node.key] = Artist(key: node.key, why: "case: \(why)") }
        }
        struct Set_: Codable { let format: String; let nodes: [Node]; let artists: [Artist] }
        let set = Set_(format: "indigo.pilot-demand/1", nodes: nodes.values.sorted(), artists: artists.values.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(set).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pilot-demand.json"))
    }
}
