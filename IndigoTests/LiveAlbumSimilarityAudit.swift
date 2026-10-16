//
//  LiveAlbumSimilarityAudit.swift
//  IndigoTests
//
//  Records like a record, looked at beyond "same style": on seeds from
//  styles no tuning or earlier evaluation used, chosen to be the hard cases
//  -- one-style records, records filed under two or more genres, and the
//  least-collected record on each style's page -- the hybrid's top five,
//  with what each pick shares beyond tags: a label, an era, how widely it is
//  collected next to the seed (Discogs "have"), and whether a cross-genre
//  seed's picks cover its genres or collapse into one. Nothing is tuned.
//
//  Live and read-only (~38 Discogs requests). Opt-in:
//  `INDIGO_ALBUM_AUDIT=1`. Report: `album-similarity-audit.txt`.
//

import XCTest
import SwiftData
@testable import Indigo

final class LiveAlbumSimilarityAudit: XCTestCase {
    private struct Search: Decodable {
        struct Community: Decodable { let have: Int?; let want: Int? }
        struct Result: Decodable {
            let id: Int?; let title: String; let style: [String]?; let genre: [String]?; let label: [String]?
            let year: String?; let community: Community?
        }
        let results: [Result]?
    }

    private let fresh = ["Ethio-Jazz", "Cumbia", "Sludge Metal", "Coldwave", "Footwork", "Chanson", "Gospel", "Sound Collage"]
    private let others = ["IDM", "Ambient", "Free Jazz", "Techno", "Deep House", "Hard Bop", "Drone", "Shoegaze", "Dream Pop",
                          "Emo", "Post Rock", "Psychedelic Rock", "Folk", "Indie Pop", "Noise", "Krautrock", "Downtempo", "Soul",
                          "Space Rock", "Slowcore", "Lo-Fi", "Indie Rock", "Dub", "Bossa Nova", "Doom Metal", "Afrobeat",
                          "Modern Classical", "Electric Blues", "Highlife", "Grime"]

    func testAlbumSimilarityOnHardSeeds() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_ALBUM_AUDIT"] == "1", "Set INDIGO_ALBUM_AUDIT=1.")
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let token = try XCTUnwrap(ObfuscatedSecret.reveal(bundled))
        var have: [Int: Int] = [:]
        func search(_ style: String) async throws -> [RecordProfile] {
            var components = try XCTUnwrap(URLComponents(string: "https://api.discogs.com/database/search"))
            components.queryItems = [.init(name: "style", value: style), .init(name: "type", value: "master"), .init(name: "per_page", value: "50")]
            var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 20)
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Indigo/1.0 (album audit)", forHTTPHeaderField: "User-Agent")
            for attempt in 0..<3 {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 1_400 : 20_000))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let results = try? JSONDecoder().decode(Search.self, from: data).results else { continue }
                return results.compactMap { result in
                    guard let id = result.id else { return nil }
                    let parts = result.title.components(separatedBy: " - ")
                    let artist = DiscogsClient.withoutDisambiguator(parts.first ?? result.title)
                    if let count = result.community?.have { have[-id] = count }
                    return RecordProfile(id: -id, title: parts.dropFirst().joined(separator: " - "), artists: [artist],
                                         artistKeys: [RecordingKey.normalizeArtist(artist)],
                                         styles: (result.style ?? []).map { $0.lowercased() }, genres: (result.genre ?? []).map { $0.lowercased() },
                                         year: result.year.flatMap(Int.init),
                                         labels: Set((result.label ?? []).prefix(1).filter(LabelName.isRealLabel).map(RecordingKey.normalize)))
                }
            }
            return []
        }

        var pool: [RecordProfile] = []
        var seeds: [(RecordProfile, String)] = []
        for style in fresh {
            let page = try await search(style)
            pool += page
            let dated = page.filter { $0.year != nil }
            var picked = Set<Int>()
            func pick(_ record: RecordProfile?, _ why: String) {
                guard let record, picked.insert(record.id).inserted else { return }
                seeds.append((record, "\(style): \(why)"))
            }
            pick(dated.first { Set($0.genres).count >= 2 }, "filed under several genres")
            pick(dated.first { Set($0.styles).count == 1 }, "one style")
            pick(dated.filter { have[$0.id] != nil }.min { (have[$0.id] ?? 0, $0.id) < (have[$1.id] ?? 0, $1.id) }, "least collected on the page")
        }
        for style in others { pool += try await search(style) }
        let seedIDs = Set(seeds.map(\.0.id))
        let similarity = RecordSimilarity(pool: pool.filter { !seedIDs.contains($0.id) })

        var out: [String] = ["pool \(similarity.pool.count) masters from \(fresh.count + others.count) styles; \(seeds.count) seeds", ""]
        var labelShare: [Double] = [], eraGaps: [Int] = [], haveRatios: [Double] = [], coverage: [String] = []
        for (seed, why) in seeds {
            let found = similarity.similar(to: seed, limit: 5)
            out.append("== \(seed.artistLine) — \(seed.title) (\(seed.year.map(String.init) ?? "?")) [\(why)] styles \(seed.styles.joined(separator: ", ")); genres \(seed.genres.joined(separator: ", ")); have \(have[seed.id].map(String.init) ?? "?")")
            if found.isEmpty { out.append("   nothing over the threshold") }
            for match in found {
                let record = match.record
                out.append(String(format: "   %.2f %@ — %@ (%@) | %@ | have %@", match.score, record.artistLine as NSString, record.title as NSString,
                                  (record.year.map(String.init) ?? "?") as NSString,
                                  (record.styles + record.genres).joined(separator: ", ") as NSString,
                                  (have[record.id].map(String.init) ?? "?") as NSString))
                if let a = seed.year, let b = record.year { eraGaps.append(abs(a - b)) }
                if let s = have[seed.id], let r = have[record.id], s > 0 { haveRatios.append(Double(r) / Double(s)) }
            }
            if !found.isEmpty {
                labelShare.append(Double(found.filter { !$0.record.labels.isDisjoint(with: seed.labels) }.count) / Double(found.count))
            }
            if Set(seed.genres).count >= 2 {
                let covered = Set(seed.genres).filter { genre in found.contains { $0.record.genres.contains(genre) } }
                coverage.append("\(seed.title): \(covered.count) of \(Set(seed.genres).count) genres (\(Set(seed.genres).subtracting(covered).sorted().joined(separator: ", ")) missing)")
            }
        }
        func median<T: Comparable>(_ values: [T]) -> T? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        out.insert("picks sharing the seed's label: \(String(format: "%.0f%%", 100 * (labelShare.reduce(0, +) / Double(max(1, labelShare.count)))))", at: 1)
        out.insert("era gap, median years: \(median(eraGaps).map(String.init) ?? "–"); picks collected more widely than the seed (median ratio of Discogs 'have'): \(median(haveRatios).map { String(format: "%.1f×", $0) } ?? "–")", at: 2)
        out.insert("cross-genre seeds, genres their picks cover: " + coverage.joined(separator: "; "), at: 3)
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("album-similarity-audit.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
