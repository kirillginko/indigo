//
//  BlindEvaluationSet.swift
//  IndigoTests
//
//  The material for a blinded evaluation, and its key, kept apart.
//
//  Records: eight seeds from styles the similarity weights were never tuned
//  on, and for each, the top three of four systems -- hybrid, metadata,
//  embedding, and a control (records sharing a genre, in an arbitrary fixed
//  order) -- pooled, deduplicated and shuffled, with nothing that says which
//  system found what, nor why.
//
//  For You: on this Mac's history, the pre-Phase-1 visible list (read from
//  `blind-before.txt`, the report taken before d6f5be2), today's visible
//  list, the Phase 4 mix, and a control (candidates the walk reaches but
//  nothing ranks, in an arbitrary fixed order) -- pooled the same way.
//
//  Live and read-only (~30 Discogs requests). Opt-in: `INDIGO_BLIND_SET=1`.
//  Writes `blind-items.json` (what a rater sees) and `blind-key.json` (which
//  systems produced each item; never shown to the rater) to the host's
//  temporary directory.
//

import XCTest
import SwiftData
import CryptoKit
@testable import Indigo

final class BlindEvaluationSet: XCTestCase {
    struct Item: Codable { let id: String; let kind: String; let title: String; let subtitle: String; let info: String; let link: String? }
    struct RecordGroup: Codable { let seed: Item; let items: [Item] }
    struct Items: Codable { let records: [RecordGroup]; let forYou: [Item] }

    private struct Search: Decodable {
        struct Result: Decodable {
            let id: Int?; let title: String; let style: [String]?; let genre: [String]?; let label: [String]?; let year: String?
        }
        let results: [Result]?
    }

    /// Styles none of the tuning ever saw.
    private let fresh = ["Dub", "Bossa Nova", "Doom Metal", "Afrobeat", "Modern Classical", "Electric Blues", "Highlife", "Grime"]
    /// The pool's other styles: Phase 3's, so the pool is as large and as mixed.
    private let others = ["IDM", "Ambient", "Free Jazz", "Techno", "Deep House", "Hard Bop", "Drone", "Shoegaze", "Dream Pop",
                          "Emo", "Post Rock", "Psychedelic Rock", "Folk", "Indie Pop", "Noise", "Krautrock", "Downtempo", "Soul",
                          "Space Rock", "Slowcore", "Lo-Fi", "Indie Rock"]

    /// A stable, arbitrary order: what a control is sorted by, and the shuffle.
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testWriteTheBlindSet() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_BLIND_SET"] == "1", "Set INDIGO_BLIND_SET=1.")
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let token = try XCTUnwrap(ObfuscatedSecret.reveal(bundled))
        var log: [String] = []
        defer { try? log.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("blind-log.txt"), atomically: true, encoding: .utf8) }
        func search(_ style: String) async throws -> [Search.Result] {
            var components = try XCTUnwrap(URLComponents(string: "https://api.discogs.com/database/search"))
            components.queryItems = [.init(name: "style", value: style), .init(name: "type", value: "master"), .init(name: "per_page", value: "50")]
            var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 20)
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Indigo/1.0 (blind evaluation)", forHTTPHeaderField: "User-Agent")
            for attempt in 0..<4 {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 1_500 : 20_000))
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let results = (try? JSONDecoder().decode(Search.self, from: data).results) ?? nil
                log.append("\(style): HTTP \(status), \(results?.count ?? -1) results (attempt \(attempt + 1))")
                if status == 200, let results { return results }
            }
            return []
        }
        func profile(_ result: Search.Result) -> RecordProfile? {
            guard let id = result.id else { return nil }
            let parts = result.title.components(separatedBy: " - ")
            let artist = DiscogsClient.withoutDisambiguator(parts.first ?? result.title)
            return RecordProfile(id: -id, title: parts.dropFirst().joined(separator: " - "), artists: [artist],
                                 artistKeys: [RecordingKey.normalizeArtist(artist)],
                                 styles: (result.style ?? []).map { $0.lowercased() }, genres: (result.genre ?? []).map { $0.lowercased() },
                                 year: result.year.flatMap(Int.init),
                                 labels: Set((result.label ?? []).prefix(1).filter(LabelName.isRealLabel).map(RecordingKey.normalize)))
        }

        // The stores, as the other measurements copy them.
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Blind-\(UUID().uuidString)")
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

        var key: [String: [String]] = [:]
        func note(_ id: String, _ system: String) { key[id, default: []].append(system) }

        // MARK: Records
        var seeds: [RecordProfile] = []
        var pool: [RecordProfile] = []
        for style in fresh {
            let page = try await search(style).compactMap(profile)
            // Discogs' own first answer, two styles preferred: most of a
            // style's page carries that style alone, which is the common case
            // and is kept (flagged in the key) rather than searched around.
            if let seed = page.first(where: { Set($0.styles).count >= 2 && $0.year != nil }) ?? page.first(where: { $0.year != nil }) {
                seeds.append(seed)
                if Set(seed.styles).count < 2 { note("seed\(-seed.id)", "one-style seed") }
            } else { log.append("\(style): no seed with two styles and a year among \(page.count): " + page.prefix(4).map { "\($0.title) \($0.styles) \($0.year.map(String.init) ?? "nil")" }.joined(separator: "; ")) }
            pool += page
        }
        for style in others { pool += try await search(style).compactMap(profile) }
        pool += try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let seedIDs = Set(seeds.map(\.id))
        let similarity = RecordSimilarity(pool: pool.filter { !seedIDs.contains($0.id) })
        func recordItem(_ record: RecordProfile) -> Item {
            Item(id: "r" + Self.hash("record|\(record.id)").prefix(10), kind: "record", title: record.title,
                 subtitle: [record.artistLine, record.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                 info: (record.styles + record.genres).map { $0.capitalized }.joined(separator: ", "),
                 link: record.id < 0 ? "https://www.discogs.com/master/\(-record.id)" : "https://www.discogs.com/release/\(record.id)")
        }
        var groups: [RecordGroup] = []
        for seed in seeds {
            var found: [String: Item] = [:]
            for mode in RecordSimilarity.Mode.allCases {
                for match in similarity.similar(to: seed, limit: 3, mode: mode) {
                    let item = recordItem(match.record)
                    found[item.id] = item
                    note("\(item.id)@\(seed.id)", mode.rawValue)
                }
            }
            // The control: sharing a genre, by an arbitrary fixed order.
            let control = similarity.pool
                .filter { !RecordSimilarity.isSameWork(seed, $0) && !Set(seed.genres).isDisjoint(with: $0.genres) }
                .sorted { Self.hash("\(seed.id)|\($0.id)") < Self.hash("\(seed.id)|\($1.id)") }
                .prefix(3)
            for record in control {
                let item = recordItem(record)
                found[item.id] = item
                note("\(item.id)@\(seed.id)", "control")
            }
            let shuffled = found.values.sorted { Self.hash("shuffle|\(seed.id)|\($0.id)") < Self.hash("shuffle|\(seed.id)|\($1.id)") }
            var seedItem = recordItem(seed)
            seedItem = Item(id: "seed\(-seed.id)", kind: "seed", title: seedItem.title, subtitle: seedItem.subtitle,
                            info: seedItem.info, link: seedItem.link)
            groups.append(RecordGroup(seed: seedItem, items: shuffled.map {
                Item(id: "\($0.id)@\(seed.id)", kind: $0.kind, title: $0.title, subtitle: $0.subtitle, info: $0.info, link: $0.link)
            }))
        }

        // MARK: For You
        let probe = PersonalInputs.read(context: context, asOf: .distantFuture)
        let asOf = ((probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()).addingTimeInterval(3_600)
        let worker = DigWorker(modelContainer: container)
        let run = await worker.exploreRun(asOf: asOf, period: ExplorePeriod.containing(asOf), generation: 0, scenes: false,
                                          rebuild: false, now: asOf)
        let offers = await worker.exploreRecommendations(run, asOf: asOf)
        var source = TrackDiscoverySource.live
        source.cache = TrackDiscoveryCache()
        let inputs = DigStore.discoverInputs(context: ModelContext(container), now: asOf)
        let tracks = await source.discover(.init(seeds: inputs.seeds, collaborators: inputs.collaborators, taste: inputs.taste,
                                                 knownArtists: inputs.knownArtists, knownTracks: inputs.knownTracks,
                                                 limit: 12, releaseLookups: 2)).tracks
        let similar = SimilarRecords.find(context: context, asOf: asOf)
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let tags = LocalKnowledgeAdapter.artistTags(
            for: Set(tracks.map { RecordingKey.normalizeArtist($0.artist) } + (offers.next + offers.artists).map { RecordingKey.normalizeArtist($0.node.title) })
                .union(personal.tasteArtistKeys), in: context)
        let mix = ForYouMix.mix(offers: offers, tracks: tracks, records: similar.records, artistTags: tags)

        var forYou: [String: Item] = [:]
        func artistItem(_ name: String, kind: String) -> Item {
            let folded = RecordingKey.normalizeArtist(name)
            let info = (tags[folded] ?? []).prefix(4).map { $0.capitalized }.joined(separator: ", ")
            let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            return Item(id: "f" + Self.hash("\(kind)|\(folded)").prefix(10), kind: kind, title: name,
                        subtitle: kind == "show" ? "Radio show" : kind == "label" ? "Label" : "Artist", info: info,
                        link: kind == "show" ? nil : "https://www.discogs.com/search/?q=\(query)&type=\(kind == "label" ? "label" : "artist")")
        }
        func kindOf(_ node: MusicNode) -> String {
            switch node.kind { case .broadcast: "show"; case .label: "label"; case .release: "record"; default: "artist" }
        }
        // Before Phase 1: the report taken then.
        let before = try String(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("blind-before.txt"), encoding: .utf8)
        for line in before.split(separator: "\n") where line.hasPrefix("next |") || line.hasPrefix("show |") || line.hasPrefix("artist |") {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count > 2 else { continue }
            let kind = parts[1] == "broadcast" ? "show" : parts[1] == "label" ? "label" : "artist"
            let item = artistItem(parts[2], kind: kind)
            forYou[item.id] = item
            note(item.id, "before")
        }
        // Today's visible For You.
        for suggestion in offers.next + offers.shows + offers.artists {
            let item = artistItem(suggestion.node.title, kind: kindOf(suggestion.node))
            forYou[item.id] = item
            note(item.id, "now")
        }
        // The mix.
        for entry in mix {
            let item: Item
            switch entry.payload {
            case .suggestion(let suggestion): item = artistItem(suggestion.node.title, kind: kindOf(suggestion.node))
            case .record(let found): item = Item(id: "f" + Self.hash("record|\(found.record.id)").prefix(10), kind: "record",
                                                 title: found.record.title, subtitle: found.record.artistLine,
                                                 info: found.record.styles.map { $0.capitalized }.joined(separator: ", "),
                                                 link: "https://www.discogs.com/release/\(found.record.id)")
            case .track(let track):
                let link: String
                switch track.source {
                case .recording(let url, _): link = url.absoluteString
                case .episode(let listen, let at): link = "\(listen.archiveURL.absoluteString) (at \(at / 60):\(String(format: "%02d", at % 60)))"
                }
                item = Item(id: "f" + Self.hash("track|\(track.id)").prefix(10), kind: "track", title: track.title,
                            subtitle: track.artist, info: (track.tags ?? []).prefix(4).map { $0.capitalized }.joined(separator: ", "),
                            link: link)
            }
            forYou[item.id] = item
            note(item.id, "mix")
        }
        // The control: reached by the walk, ranked by nothing.
        let known = ExploreRanker.knownGround(run.personal)
        let seen = Set(known.map(\.node.id)), encountered = Set(run.personal.met.map(\.node.id)).union(run.alsoKnown)
        let sets = ExploreRanker.edgeSets(run.knowledge)
        var reached: [String: MusicNode] = [:]
        for origin in known.prefix(ExploreSuggestionEngine.origins) {
            for connection in (sets[origin.node] ?? EdgeSet()).byDestination
            where connection.node.kind == .artist && connection.node.destination != nil
                && !seen.contains(connection.node.id) && !encountered.contains(connection.node.id) {
                reached[connection.node.id] = connection.node
            }
        }
        for node in reached.values.sorted(by: { Self.hash($0.id) < Self.hash($1.id) }).prefix(8) {
            let item = artistItem(node.title, kind: "artist")
            forYou[item.id] = item
            note(item.id, "control")
        }
        let forYouItems = forYou.values.sorted { Self.hash("shuffle|\($0.id)") < Self.hash("shuffle|\($1.id)") }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Items(records: groups, forYou: forYouItems))
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("blind-items.json"))
        try encoder.encode(key).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("blind-key.json"))
    }
}
