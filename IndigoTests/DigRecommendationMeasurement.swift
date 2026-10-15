//
//  DigRecommendationMeasurement.swift
//  IndigoTests
//
//  Whether DIG can say what to hear next, on the 3,300-artist catalogue
//  sample: musician-first DIG's top three routes beside DigRecommender's
//  cards, each judged for a concrete record, something playable, and a next
//  step; then guided journeys of up to three steps, and examples.
//
//  Opt-in: `INDIGO_DIG_MEASURE_DIR` naming the folder that holds `bundles/`,
//  `releases.json` (the R2 documents of the records the bundles rest on, with
//  the first video YouTube says can be played) and `radio.json` (each
//  Discogs artist's radio appearances, with the latest playable episode).
//  Report: `dig-recommendation-measurement.txt` in the host's temporary
//  directory.
//

import XCTest
import CryptoKit
@testable import Indigo

final class DigRecommendationMeasurement: XCTestCase {
    override func tearDown() { MusicianFirst.override = nil }

    private struct Manifest: Decodable {
        struct Entry: Decodable { let digest: String }
        let artists: [String: Entry]
    }

    private struct Release: Decodable {
        let id: Int
        let title: String
        let year: Int?
        let styles: [String]
        let genres: [String]
        let playable: String?
        let playableTitle: String?
    }

    private struct Radio: Decodable {
        struct Latest: Decodable { let title: String?; let show: String?; let url: String? }
        let episodes: Int
        let latest: Latest?
    }

    func testMeasureWhatToHearNext() throws {
        guard let root = ProcessInfo.processInfo.environment["INDIGO_DIG_MEASURE_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set INDIGO_DIG_MEASURE_DIR.")
        }
        let dir = root.appendingPathComponent("bundles")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var bundles: [Int: ArtistBundle] = [:]
        for (key, entry) in manifest.artists {
            guard let id = Int(key) else { continue }
            bundles[id] = try JSONDecoder().decode(ArtistBundle.self, from: Data(contentsOf: dir.appendingPathComponent("\(entry.digest).json")))
        }
        let releases = try JSONDecoder().decode([String: Release].self, from: Data(contentsOf: root.appendingPathComponent("releases.json")))
        let radio = try JSONDecoder().decode([String: Radio].self, from: Data(contentsOf: root.appendingPathComponent("radio.json")))
        func ids(_ file: String) throws -> [Int] {
            try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8).split(separator: "\n").compactMap { Int($0) }.sorted()
        }
        let pilot = try ids("pilot-ids.txt"), batch1 = try ids("batch1-ids.txt")

        // Every page's routes, musician-first.
        MusicianFirst.override = true
        var edges: [Int: [MusicEdge]] = [:]
        var musicians: [Int: Set<Int>] = [:]
        for (id, bundle) in bundles {
            let found = BundleEdges.edges(from: .artist(bundle.artist.name, discogsID: id), bundle: bundle, ownIdentities: [id], sqlTargets: [])
                .filter { $0.to.kind != .artist || !CataloguePilot.standIns.contains($0.to.discogsID ?? 0) }
            edges[id] = found
            for edge in found where edge.to.kind == .artist && [.collaborator, .personnel, .producer].contains(edge.kind) {
                guard let to = edge.to.discogsID, to != id else { continue }
                musicians[id, default: []].insert(to)
                musicians[to, default: []].insert(id)
            }
        }

        func lookups(for id: Int) -> DigRecommender.Lookups {
            let own = bundles[id]
            var byTitle: [String: (Int, Int?)] = [:]
            for release in own?.releases ?? [] where byTitle[release.title] == nil { byTitle[release.title] = (release.id, release.year) }
            var lookups = DigRecommender.Lookups()
            lookups.release = { title in byTitle[title].map { (id: $0.0, year: $0.1) } }
            lookups.recordings = { release in
                guard let found = releases[String(release)], let uri = found.playable, let url = URL(string: uri) else { return [] }
                return [(url: url, title: found.playableTitle ?? found.title)]
            }
            lookups.radio = { artist in
                guard let id = artist.discogsID, let latest = radio[String(id)]?.latest, let link = latest.url,
                      let url = URL(string: link) else { return nil }
                return .radio(title: latest.title ?? "Radio appearance", show: latest.show, url: url, page: nil)
            }
            lookups.onward = { artist in artist.discogsID.map { (musicians[$0] ?? []).subtracting([id]).count } }
            lookups.tags = { artist in
                artist.discogsID.flatMap { bundles[$0] }.map { ListeningLog.foldTags(($0.styles + $0.genres).map(\.name)) }
            }
            return lookups
        }

        /// Today's musician-first top three, judged by the same questions.
        func today(_ id: Int) -> [DigRecommendation] {
            let lookups = lookups(for: id)
            let origin = MusicNode.artist(bundles[id]?.artist.name ?? "", discogsID: id)
            return (edges[id] ?? []).filter { $0.to.kind == .artist }
                .sorted { ($0.weight * MusicianFirstRanker.worth($0), $1.to.title) > ($1.weight * MusicianFirstRanker.worth($1), $0.to.title) }
                .reduce(into: [MusicEdge]()) { kept, edge in if !kept.contains(where: { $0.to.id == edge.to.id }) { kept.append(edge) } }
                .prefix(3)
                .compactMap { edge in
                    // The same evidence and listen a card would carry, without
                    // the card's ranking.
                    DigRecommender.recommend(from: [edge], origin: origin, lookups: lookups, listener: .init(), limit: 1).first
                }
        }

        func cards(_ id: Int, visited: Set<String> = []) -> [DigRecommendation] {
            DigRecommender.recommend(from: edges[id] ?? [], origin: .artist(bundles[id]?.artist.name ?? "", discogsID: id),
                                     lookups: lookups(for: id), listener: .init(visited: visited))
        }

        var lines: [String] = []
        lines.append("What to hear next, on the catalogue sample (\(bundles.count) bundles; \(releases.count) records read, \(releases.values.filter { $0.playable != nil }.count) with a recording YouTube says plays; \(radio.count) artists with a playable radio appearance)")
        let started = ContinuousClock.now
        var timing: Duration = .zero
        for (label, set) in [("pilot (300)", pilot), ("batch 1 (3,000)", batch1)] {
            struct Tally { var pages = 0, covered = 0, full = 0, cards = 0, direct = 0, evidence = 0, playable = 0, fromRecord = 0, fromRadio = 0, firstPlayable = 0, onward = 0, releases = 0, kinds = 0 }
            func tally(_ results: [[DigRecommendation]]) -> Tally {
                var t = Tally()
                for cards in results {
                    t.pages += 1
                    if !cards.isEmpty { t.covered += 1 }
                    if cards.count >= 3 { t.full += 1 }
                    t.cards += cards.count
                    t.direct += cards.filter { $0.relationship.isDirect }.count
                    t.evidence += cards.filter { $0.evidence?.releaseID != nil }.count
                    t.playable += cards.filter { $0.listen != nil }.count
                    t.fromRecord += cards.filter { $0.listen?.isFromTheEvidence == true }.count
                    t.fromRadio += cards.filter { $0.listen != nil && $0.listen?.isFromTheEvidence == false }.count
                    if cards.first?.listen != nil { t.firstPlayable += 1 }
                    t.onward += cards.filter { ($0.onward ?? 0) > 0 }.count
                    t.releases += Set(cards.compactMap { $0.evidence?.title }).count
                    t.kinds += Set(cards.map(\.relationship)).count
                }
                return t
            }
            let pages = set.filter { bundles[$0] != nil }
            let before = tally(pages.map(today))
            let pageStarted = ContinuousClock.now
            let afterCards = pages.map { cards($0) }
            timing += ContinuousClock.now - pageStarted
            let after = tally(afterCards)
            func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "-" : String(format: "%.0f%%", 100 * Double(part) / Double(whole)) }
            lines.append("")
            lines.append("== \(label): \(before.pages) pages")
            for (name, t) in [("musician-first top three", before), ("recommendation cards  ", after)] {
                lines.append("\(name): pages with something \(pct(t.covered, t.pages)), with three \(pct(t.full, t.pages)); \(t.cards) cards, direct \(pct(t.direct, t.cards)), on a named record \(pct(t.evidence, t.cards)), something to hear \(pct(t.playable, t.cards)) (from the record \(t.fromRecord), radio \(t.fromRadio)), first card playable \(pct(t.firstPlayable, t.pages)), leads on \(pct(t.onward, t.cards)); per page \(String(format: "%.2f", Double(t.releases) / Double(max(1, t.pages)))) records and \(String(format: "%.2f", Double(t.kinds) / Double(max(1, t.pages)))) kinds of relationship")
            }
        }

        // Journeys: from each page, follow the first card, then the first
        // card there, never back to where the walk has been.
        var reached = [0, 0, 0, 0], heard = 0, steps = 0
        var examples: [String] = []
        for id in (pilot + batch1).filter({ bundles[$0] != nil }) {
            var visited: Set<String> = [MusicNode.artist(bundles[id]!.artist.name, discogsID: id).id]
            var at = id, depth = 0, walk = [bundles[id]!.artist.name]
            while depth < 3, bundles[at] != nil, let next = cards(at, visited: visited).first(where: { $0.relationship.isDirect }) {
                depth += 1; steps += 1
                if next.listen != nil { heard += 1 }
                visited.insert(next.artist.id)
                walk.append("\(next.artist.title) (\(next.reason)\(next.listen == nil ? "" : ", ▶"))")
                guard let to = next.artist.discogsID else { break }
                at = to
            }
            reached[depth] += 1
            if depth == 3, examples.count < 3 { examples.append(walk.joined(separator: " → ")) }
        }
        let total = reached.reduce(0, +)
        lines.append("")
        lines.append("== journeys (follow the first direct card, never back): \(total) starts")
        lines.append("no step \(reached[0]), one \(reached[1]), two \(reached[2]), three \(reached[3]); \(steps) steps, \(heard) with something to hear. A walk stops where the next artist has no bundle in the sample: the sample's floor, not the app's.")
        lines.append(contentsOf: examples.map { "  " + $0 })

        // Examples by family: today's top three beside the cards.
        func family(_ bundle: ArtistBundle) -> String? {
            let tags = Set((bundle.genres + bundle.styles).map { $0.name.lowercased() })
            if !tags.isDisjoint(with: ["free jazz", "hard bop", "post bop", "contemporary jazz", "modal", "free improvisation", "avant-garde jazz", "jazz-funk", "fusion"]) && tags.contains("jazz") { return "jazz" }
            if tags.contains("hip hop") { return "hip-hop" }
            if !tags.isDisjoint(with: ["ambient", "drone", "dark ambient"]) { return "ambient" }
            if !tags.isDisjoint(with: ["experimental", "idm", "noise", "abstract"]) && tags.contains("electronic") { return "experimental electronic" }
            if !tags.isDisjoint(with: ["indie rock", "indie pop", "lo-fi", "shoegaze"]) { return "indie" }
            return nil
        }
        func show(_ card: DigRecommendation) -> String {
            let record = card.evidence.map { " — \($0.title)\($0.year.map { " (\($0))" } ?? "")" } ?? ""
            let listen: String
            switch card.listen {
            case .recording(_, let title)?: listen = " ▶ \(title)"
            case .radio(let title, let show, _, _)?: listen = " ▶ radio: \(show.map { "\($0): " } ?? "")\(title)"
            case nil: listen = ""
            }
            return "\(card.artist.title) [\(card.relationship.label)]\(record)\(listen)"
        }
        var shown: [String: Int] = [:]
        lines.append("")
        lines.append("== examples")
        for id in (pilot + batch1) {
            guard let bundle = bundles[id], let kind = family(bundle), shown[kind, default: 0] < 2 else { continue }
            let after = cards(id)
            guard after.count >= 2, after.contains(where: { $0.listen != nil }) else { continue }
            shown[kind, default: 0] += 1
            lines.append("")
            lines.append("\(bundle.artist.name) [\(id)] — \(kind)")
            lines.append("  musician-first: " + today(id).map(show).joined(separator: "; "))
            lines.append("  cards:          " + after.map(show).joined(separator: "; "))
        }
        lines.append("")
        lines.append("cards for all pages: \(timing)")
        _ = started

        let body = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(lines.filter { !$0.hasPrefix("cards for all") }.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        try (body + "\n\ncontent digest (timings excluded): \(digest)\n")
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("dig-recommendation-measurement.txt"), atomically: true, encoding: .utf8)
    }
}
