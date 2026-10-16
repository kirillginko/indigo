//
//  LiveRecordSimilarityEvaluation.swift
//  IndigoTests
//
//  Records like Helvetia's "Junk Shop", Eiafuawn's "Birds In The Ground" and
//  Duster's "Stratosphere", three ways (`RecordSimilarity.Mode`), from one
//  pool: the records this Mac's DIG has cached, and a page of Discogs masters
//  for each of twenty styles -- the seeds' own and as many that are not, so
//  a method that only matches the obvious word is caught out. Then For You's
//  "Records like yours" on this Mac's real history, from the cache alone, as
//  the app would work it out.
//
//  Live and read-only: ~25 Discogs requests a run, paced inside the budget;
//  nothing is written. Opt-in: `INDIGO_LIVE_SIMILARITY=1`. Report (private):
//  `live-record-similarity.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class LiveRecordSimilarityEvaluation: XCTestCase {
    private struct Search: Decodable {
        struct Result: Decodable {
            let id: Int?
            let title: String
            let style: [String]?
            let genre: [String]?
            let label: [String]?
            let year: String?
            let thumb: String?
        }
        let results: [Result]?
    }

    private let seeds = [("Helvetia", "Junk Shop"), ("Eiafuawn", "Birds In The Ground"), ("Duster", "Stratosphere")]
    private let distractors = ["IDM", "Ambient", "Free Jazz", "Techno", "Deep House", "Hard Bop", "Drone", "Shoegaze",
                               "Dream Pop", "Emo", "Post Rock", "Psychedelic Rock", "Folk", "Indie Pop", "Noise",
                               "Krautrock", "Downtempo", "Soul", "Space Rock", "Slowcore", "Lo-Fi"]

    func testRecordsLikeTheThreeAlbumsAndLikeTheRealCrate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_SIMILARITY"] == "1",
                          "Live: set INDIGO_LIVE_SIMILARITY=1.")
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let token = try XCTUnwrap(ObfuscatedSecret.reveal(bundled))
        var requests = 0
        func discogs<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
            var components = try XCTUnwrap(URLComponents(string: "https://api.discogs.com/\(path)"))
            components.queryItems = query.isEmpty ? nil : query
            var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 20)
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Indigo/1.0 (similarity evaluation)", forHTTPHeaderField: "User-Agent")
            requests += 1
            try await Task.sleep(for: .milliseconds(1_200))
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(T.self, from: data)
        }

        // The seeds, read in full.
        var seedProfiles: [RecordProfile] = []
        var out: [String] = []
        for (artist, title) in seeds {
            let found: Search = try await discogs("database/search", [
                .init(name: "artist", value: artist), .init(name: "release_title", value: title),
                .init(name: "type", value: "release"), .init(name: "per_page", value: "5")])
            guard let id = found.results?.first?.id else { out.append("seed not found: \(artist) — \(title)"); continue }
            var detail: DiscogsReleaseDetail?
            if let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))),
               let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                detail = try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data)
            }
            if detail == nil { detail = try await discogs("releases/\(id)") }
            let profile = RecordProfile(detail: try XCTUnwrap(detail))
            seedProfiles.append(profile)
            out.append("seed \(profile.artistLine) — \(profile.title) (\(profile.year.map(String.init) ?? "?"), release \(id)): styles \(profile.styles.joined(separator: ", ")); genres \(profile.genres.joined(separator: ", ")); labels \(profile.labels.sorted().joined(separator: ", ")); musical credits \(profile.personnelNames.values.sorted().joined(separator: ", "))")
        }

        // The pool: a page of masters per style, and this Mac's cached records.
        let styles = Array(Set(seedProfiles.flatMap(\.styles).map { $0.capitalized } + distractors)).sorted()
        var pool: [RecordProfile] = []
        for style in styles {
            let page: Search = try await discogs("database/search", [
                .init(name: "style", value: style), .init(name: "type", value: "master"), .init(name: "per_page", value: "50")])
            for result in page.results ?? [] {
                guard let id = result.id else { continue }
                let parts = result.title.components(separatedBy: " - ")
                let artist = DiscogsClient.withoutDisambiguator(parts.first ?? result.title)
                pool.append(RecordProfile(id: -id, title: parts.dropFirst().joined(separator: " - "), artists: [artist],
                                          artistKeys: [RecordingKey.normalizeArtist(artist)],
                                          styles: (result.style ?? []).map { $0.lowercased() },
                                          genres: (result.genre ?? []).map { $0.lowercased() },
                                          year: result.year.flatMap(Int.init),
                                          labels: Set((result.label ?? []).prefix(1).filter(LabelName.isRealLabel).map(RecordingKey.normalize))))
            }
        }
        let searched = pool.count
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Similarity-\(UUID().uuidString)")
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
        let cached = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        pool += cached
        let started = ContinuousClock.now
        let similarity = RecordSimilarity(pool: pool)
        let built = ContinuousClock.now - started
        out.append("")
        out.append("pool: \(searched) Discogs masters from \(styles.count) styles + \(cached.count) cached records = \(similarity.pool.count); \(similarity.vectors.count) styles embedded in \(built)")

        for seed in seedProfiles {
            out.append("")
            out.append("== like \(seed.artistLine) — \(seed.title)")
            var lists: [RecordSimilarity.Mode: [Int]] = [:]
            for mode in RecordSimilarity.Mode.allCases {
                let t = ContinuousClock.now
                let found = similarity.similar(to: seed, limit: 10, mode: mode)
                lists[mode] = found.map(\.record.id)
                out.append("-- \(mode.rawValue) (\(ContinuousClock.now - t))")
                for (index, match) in found.enumerated() {
                    out.append(String(format: "  %2d. %@ — %@ (%@) | %.3f [meta %.3f, emb %.3f] | %@", index + 1,
                                      match.record.artistLine as NSString, match.record.title as NSString,
                                      (match.record.year.map(String.init) ?? "?") as NSString, match.score, match.metadata,
                                      match.embedding, match.reason as NSString))
                }
            }
            let meta = Set(lists[.metadata] ?? []), emb = Set(lists[.embedding] ?? []), hyb = Set(lists[.hybrid] ?? [])
            out.append("  overlap of the top tens: metadata∩embedding \(meta.intersection(emb).count), hybrid∩metadata \(hyb.intersection(meta).count), hybrid∩embedding \(hyb.intersection(emb).count)")
        }

        // For You on the real history: the cache as the pool, the crate's
        // records as seeds, as `DigStore.similarRecords` works them out.
        let quick = ContinuousClock.now
        _ = SimilarRecords.find(context: context, asOf: Date(), scenes: false)
        let withoutScenes = ContinuousClock.now - quick
        let t = ContinuousClock.now
        let found = SimilarRecords.find(context: context, asOf: Date())
        out.append("")
        out.append("== Records like yours, this Mac's history (\(ContinuousClock.now - t) with scenes, \(withoutScenes) without): seeds \(found.seeds.map { "\($0.artistLine) — \($0.title)" }.joined(separator: "; "))")
        for record in found.records {
            out.append("  \(record.record.artistLine) — \(record.record.title) (\(record.record.year.map(String.init) ?? "?")) | like \(record.via.title) | \(record.reason)")
        }
        out.append("")
        out.append("Discogs requests: \(requests)")
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-record-similarity.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
