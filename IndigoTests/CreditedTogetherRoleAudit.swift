//
//  CreditedTogetherRoleAudit.swift
//  IndigoTests
//
//  DIG's "Credited together" names come from an artist's Discogs shelf --
//  the records they appear on under another artist's name -- with the role
//  dropped when the row is written (`DiscogsArtist.collaboratorNames`). Which
//  of them rest only on a technical credit ("Mixed by"), and could the role
//  be recovered without a new schema version?
//
//  Truth: the shelves, read from Discogs (read-only, paced). Recovery tried:
//  the release records the device already holds, which name the subject
//  among each record's credits with the role it had.
//
//  Opt-in: `INDIGO_CREDITED_AUDIT=1`. Report: `credited-together-audit.txt`
//  in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class CreditedTogetherRoleAudit: XCTestCase {
    private struct Shelf: Decodable {
        struct Entry: Decodable { let id: Int?; let role: String?; let artist: String?; let title: String? }
        struct Pages: Decodable { let pages: Int? }
        let releases: [Entry]?
        let pagination: Pages?
    }

    func testWhichCreditedTogetherNamesAreTechnical() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_CREDITED_AUDIT"] == "1", "Set INDIGO_CREDITED_AUDIT=1.")
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let token = try XCTUnwrap(ObfuscatedSecret.reveal(bundled))
        var requests = 0
        func shelf(_ id: Int, page: Int) async throws -> Shelf? {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.discogs.com/artists/\(id)/releases?per_page=100&page=\(page)")),
                                     timeoutInterval: 20)
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Indigo/1.0 (credit audit)", forHTTPHeaderField: "User-Agent")
            try await Task.sleep(for: .milliseconds(1_300))
            requests += 1
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(Shelf.self, from: data)
        }

        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Credited-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>())
        // The artists the listener's For You starts from, and the rest of
        // what DIG holds with collaborators, up to twelve in all.
        let personal = PersonalInputs.read(context: context, asOf: Date())
        let starting = ExploreRanker.startingPoints(personal).filter { $0.kind == .artist }.map(\.key)
        let artists = try context.fetch(FetchDescriptor<DiscogsArtist>()).filter { !$0.collaboratorNames.isEmpty && $0.discogsID > 0 }
        let chosen = (artists.filter { starting.contains(RecordingKey.normalizeArtist($0.name)) }
            + artists.filter { !starting.contains(RecordingKey.normalizeArtist($0.name)) }.sorted { $0.discogsID < $1.discogsID })
            .prefix(12)

        var out: [String] = []
        var totals = ["musical": 0, "technical only": 0, "not on the shelf": 0]
        var recovered = ["agrees": 0, "disagrees": 0, "nothing held": 0]
        for artist in chosen {
            var entries: [Shelf.Entry] = []
            var page = 1, pages = 1
            repeat {
                guard let found = try await shelf(artist.discogsID, page: page) else { break }
                entries += found.releases ?? []
                pages = min(3, found.pagination?.pages ?? 1)
                page += 1
            } while page <= pages
            var roles: [String: Set<String>] = [:]
            for entry in entries where entry.role != nil && entry.role != "Main" {
                guard let name = entry.artist.map(DiscogsClient.withoutDisambiguator) else { continue }
                roles[RecordingKey.normalizeArtist(name), default: []].insert(entry.role ?? "")
            }
            let subject = RecordingKey.normalizeArtist(artist.name)
            var lines: [String] = []
            for name in artist.collaboratorNames {
                let key = RecordingKey.normalizeArtist(name)
                let shelfRoles = roles[key] ?? []
                // On the shelf, a role is musical unless the taxonomy says the
                // job was technical; Appearance and TrackAppearance are being
                // on the record.
                let truth: String
                if shelfRoles.isEmpty { truth = "not on the shelf" }
                else if shelfRoles.allSatisfy({ ContributorRole.of(credit: $0) == .technical }) { truth = "technical only" }
                else { truth = "musical" }
                totals[truth, default: 0] += 1
                // Recovery: records held by that collaborator crediting the subject.
                let held = records.filter { record in
                    record.artistNames.contains { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0)) == key }
                        && record.creditNames.contains { RecordingKey.normalizeArtist($0) == subject }
                }
                let heldRoles = held.flatMap { record in
                    record.creditNames.indices.filter { RecordingKey.normalizeArtist(record.creditNames[$0]) == subject }
                        .map { $0 < record.creditRoles.count ? record.creditRoles[$0] : "" }
                }
                let guess: String
                if heldRoles.isEmpty { guess = "nothing held"; recovered["nothing held", default: 0] += 1 }
                else {
                    guess = heldRoles.allSatisfy({ ContributorRole.of(credit: $0) == .technical }) ? "technical only" : "musical"
                    if truth != "not on the shelf" { recovered[guess == truth ? "agrees" : "disagrees", default: 0] += 1 }
                }
                if truth != "musical" || guess != "nothing held" {
                    lines.append("    \(name): shelf \(shelfRoles.sorted().joined(separator: ", ")) → \(truth); held records \(heldRoles.joined(separator: " | ")) → \(guess)")
                }
            }
            out.append("\(artist.name) (\(artist.discogsID)): \(artist.collaboratorNames.count) credited together, shelf \(entries.count) entries")
            out += lines
        }
        out.insert("credited together, judged by the shelves: " + totals.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "), at: 0)
        out.insert("recovered from records held on the device: " + recovered.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "; Discogs requests \(requests)", at: 1)
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("credited-together-audit.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
