//
//  LiveRadioSampleMeasurement.swift
//  IndigoTests
//
//  Hear next's radio lookup on a broad sample of catalogue pages: each page's
//  cards from its bundle (recordings from the R2 documents, no radio), then
//  the live, verified radio lookup for its top three, then the cards again.
//
//  Opt-in: `INDIGO_DIG_MEASURE_DIR` (as for DigRecommendationMeasurement) and
//  `INDIGO_LIVE_RADIO=1`. Reads the backend (read-only) and checks archives.
//  Report: `live-radio-sample.txt` in the host's temporary directory.
//

import XCTest
@testable import Indigo

final class LiveRadioSampleMeasurement: XCTestCase {
    override func tearDown() { MusicianFirst.override = nil }

    private struct Manifest: Decodable { struct Entry: Decodable { let digest: String }; let artists: [String: Entry] }
    private struct Release: Decodable { let title: String; let year: Int?; let playable: String?; let playableTitle: String? }

    func testRadioOnASampleOfPages() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_RADIO"] == "1",
              let root = ProcessInfo.processInfo.environment["INDIGO_DIG_MEASURE_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Live: set INDIGO_LIVE_RADIO=1 and INDIGO_DIG_MEASURE_DIR.")
        }
        MusicianFirst.override = true
        let dir = root.appendingPathComponent("bundles")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let releases = try JSONDecoder().decode([String: Release].self, from: Data(contentsOf: root.appendingPathComponent("releases.json")))
        func ids(_ file: String) throws -> [Int] {
            try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8).split(separator: "\n").compactMap { Int($0) }.sorted()
        }
        let pilot = try ids("pilot-ids.txt"), batch1 = try ids("batch1-ids.txt")
        // 75 from the pilot, 75 spread through batch 1: fixed, so a rerun asks the same.
        let sample = Array(pilot.prefix(75)) + stride(from: 0, to: batch1.count, by: batch1.count / 75).map { batch1[$0] }.prefix(75)

        let finder = RadioListenFinder.live
        var asked = 0, before = (cards: 0, hear: 0, first: 0), after = (cards: 0, hear: 0, first: 0, radio: 0)
        var times: [Double] = [], totals = RadioListenFinder.Report(), examples: [String] = []
        for id in sample {
            guard let entry = manifest.artists[String(id)] else { continue }
            let bundle = try JSONDecoder().decode(ArtistBundle.self, from: Data(contentsOf: dir.appendingPathComponent("\(entry.digest).json")))
            let origin = MusicNode.artist(bundle.artist.name, discogsID: id)
            let edges = BundleEdges.edges(from: origin, bundle: bundle, ownIdentities: [id], sqlTargets: [])
            var byTitle: [String: (Int, Int?)] = [:]
            for release in bundle.releases where byTitle[release.title] == nil { byTitle[release.title] = (release.id, release.year) }
            var lookups = DigRecommender.Lookups()
            lookups.release = { byTitle[$0].map { (id: $0.0, year: $0.1) } }
            lookups.recordings = { release in
                guard let found = releases[String(release)], let uri = found.playable, let url = URL(string: uri) else { return [] }
                return [(url: url, title: found.playableTitle ?? found.title)]
            }
            let cards = DigRecommender.recommend(from: edges, origin: origin, lookups: lookups, listener: .init())
            before.cards += cards.count
            before.hear += cards.filter { $0.listen != nil }.count
            before.first += cards.first?.listen != nil ? 1 : 0

            let wanted = cards.filter { if case .recording? = $0.listen { false } else { $0.artist.discogsID != nil } }
                .compactMap(\.artist.discogsID)
            var found: [Int: RadioListen?] = [:]
            if !wanted.isEmpty {
                asked += 1
                let started = ContinuousClock.now
                let (answer, report) = await finder.find(Array(wanted.prefix(3)))
                let spent = ContinuousClock.now - started
                times.append(Double(spent.components.attoseconds) / 1e15 + Double(spent.components.seconds) * 1000)
                found = answer
                totals.identityReads += report.identityReads; totals.appearanceReads += report.appearanceReads
                totals.checks += report.checks; totals.verified += report.verified; totals.notPlayable += report.notPlayable
                totals.unknown += report.unknown; totals.noAppearance += report.noAppearance; totals.failures += report.failures
            }
            lookups.radio = { artist in artist.discogsID.flatMap { found[$0] ?? nil }.map { .radio($0) } }
            let again = DigRecommender.recommend(from: edges, origin: origin, lookups: lookups, listener: .init())
            after.cards += again.count
            after.hear += again.filter { $0.listen != nil }.count
            after.first += again.first?.listen != nil ? 1 : 0
            let radioCards = again.filter { if case .radio? = $0.listen { true } else { false } }
            after.radio += radioCards.count
            if let card = radioCards.first, examples.count < 8, case .radio(let episode)? = card.listen {
                examples.append("\(bundle.artist.name) → \(card.artist.title) [\(card.chip)]\(card.evidence.map { " — \($0.title)" } ?? "") ▶ \(RecommendationCardView.radioLine(episode))")
            }
        }
        times.sort()
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        let pages = sample.count
        let lines = [
            "Radio on \(pages) catalogue pages (75 pilot, 75 across batch 1); asked on \(asked) (the rest had a recording for every card or nothing verified to ask about)",
            "cards with something to hear: \(pct(before.hear, before.cards)) → \(pct(after.hear, after.cards)) (\(after.radio) radio); first card playable: \(pct(before.first, pages)) → \(pct(after.first, pages))",
            "lookup: \(String(format: "%.0f", times.isEmpty ? 0 : times[times.count / 2])) ms median, \(String(format: "%.0f", times.isEmpty ? 0 : times[min(times.count - 1, times.count * 9 / 10)])) ms at the 90th percentile, \(String(format: "%.0f", times.last ?? 0)) ms slowest",
            "requests: \(totals.identityReads) identity, \(totals.appearanceReads) appearances, \(totals.checks) playability checks (\(String(format: "%.1f", Double(totals.identityReads + totals.appearanceReads + totals.checks) / Double(max(1, asked)))) a page)",
            "episodes verified \(totals.verified); archives that do not play \(totals.notPlayable); could not tell \(totals.unknown); artists never on radio \(totals.noAppearance); failed reads \(totals.failures)",
            "", "examples:"
        ] + examples.map { "  " + $0 }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-radio-sample.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
