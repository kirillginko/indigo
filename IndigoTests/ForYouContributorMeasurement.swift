//
//  ForYouContributorMeasurement.swift
//  IndigoTests
//
//  What the visible For You recommends, and on what kind of contribution each
//  recommendation rests, for real histories and for synthetic listeners of
//  five kinds of music.
//
//  Opt-in: `INDIGO_MEASURE_CONTRIBUTORS=1` (as
//  `TEST_RUNNER_INDIGO_MEASURE_CONTRIBUTORS=1`). Copies of the stores are read,
//  never the stores the app uses:
//  - "production": the Production UserData store (the synced history) with
//    the Development Local store (the newest catalogue cache);
//  - "development": the Development UserData and Local stores;
//  - "jazz", "hiphop", "ambient", "electronic", "indie": a crate of eight
//    records chosen by style from the Development Local store's cached
//    releases (lowest Discogs ids first, one per artist, each with credits),
//    their artists' pages as places returned to. Nothing is written.
//
//  Reports (private listening data -- they stay out of Git):
//  `foryou-contributors-<profile>.txt` in the host's temporary directory, one
//  line per offer, so two runs compare with `diff`.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ForYouContributorMeasurement: XCTestCase {
    private struct Profile {
        let name: String
        let genres: Set<String>
        let styles: Set<String>
        let excludedStyles: Set<String>
    }

    private let profiles = [
        Profile(name: "jazz", genres: ["jazz"],
                styles: ["free jazz", "hard bop", "post bop", "modal", "spiritual jazz", "cool jazz", "bop",
                         "contemporary jazz", "soul-jazz", "free improvisation"], excludedStyles: []),
        Profile(name: "hiphop", genres: ["hip hop"], styles: [], excludedStyles: []),
        Profile(name: "ambient", genres: [], styles: ["ambient", "drone", "dark ambient"], excludedStyles: []),
        Profile(name: "electronic", genres: [], styles: ["techno", "house", "idm", "electro", "deep house",
                                                       "minimal", "dub techno", "breakbeat", "uk garage"],
                excludedStyles: ["ambient", "drone"]),
        Profile(name: "indie", genres: [], styles: ["indie rock", "indie pop", "lo-fi", "shoegaze", "post-punk",
                                                  "slowcore", "emo"], excludedStyles: []),
    ]

    func testMeasureWhatForYouRecommendsAndWhy() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_CONTRIBUTORS"] == "1",
                          "Set INDIGO_MEASURE_CONTRIBUTORS=1 to measure For You on real stores.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let development = support.appendingPathComponent("Development")

        for (label, userData) in [("production", support), ("development", development)] {
            let container = try copyStores(userData: userData, local: development, label: label)
            let context = ModelContext(container)
            let probe = PersonalInputs.read(context: context, asOf: .distantFuture)
            let last = (probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()
            let asOf = last.addingTimeInterval(3_600)
            let personal = PersonalInputs.read(context: context, asOf: asOf)
            try await report(label, container: container, personal: personal, asOf: asOf,
                             header: "crate \(personal.crate.count), met \(personal.met.count), haunts \(personal.haunts.count)")
            // What the app's prefill (`DigStore.prefillStartingPointCredits`)
            // keeps once For You is on screen: the starting points' credits
            // by id from R2. Network, so asked for separately.
            if ProcessInfo.processInfo.environment["INDIGO_MEASURE_CONTRIBUTORS_R2"] == "1" {
                let kept = await keepStartingPointCredits(personal, context: context)
                try await report("\(label)-credits", container: container, personal: personal, asOf: asOf,
                                 header: "after keeping credits for \(kept) starting-point releases from R2")
            }
        }

        let container = try copyStores(userData: development, local: development, label: "synthetic")
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(sortBy: [SortDescriptor(\.discogsID)]))
        let asOf = Date(timeIntervalSince1970: 1_792_000_000)
        for profile in profiles {
            var artists = Set<String>()
            var chosen: [DiscogsReleaseRecord] = []
            for record in records where chosen.count < 8 {
                let styles = Set(record.styles.map { $0.lowercased() })
                let genres = Set(record.genres.map { $0.lowercased() })
                let fits = !styles.isDisjoint(with: profile.styles) || !genres.isDisjoint(with: profile.genres)
                guard fits, styles.isDisjoint(with: profile.excludedStyles), record.creditNames.count >= 2,
                      let artist = record.artistNames.first, ArtistName.isRealArtist(artist) else { continue }
                let key = RecordingKey.normalizeArtist(artist)
                guard artists.insert(key).inserted else { continue }
                chosen.append(record)
            }
            var personal = PersonalInputs.empty
            for (index, record) in chosen.enumerated() {
                let artist = RecordingKey.normalizeArtist(record.artistNames.first ?? "")
                let at = asOf.addingTimeInterval(-Double(index + 1) * 86_400)
                personal.crate.append(.init(node: .release(record.title, discogsID: record.discogsID), addedAt: at,
                                            genreTags: record.genres + record.styles,
                                            tasteArtistKeys: [artist], sceneArtistKey: artist))
                personal.haunts.append(.init(node: .artist(record.artistNames.first ?? ""), visits: 2, lastVisitedAt: at))
            }
            let header = "crate: " + chosen.map { "\($0.title) — \($0.artistNames.joined(separator: ", ")) [\($0.styles.joined(separator: ", "))]" }
                .joined(separator: "; ")
            try await report(profile.name, container: container, personal: personal, asOf: asOf, header: header)
        }
    }

    /// The prefill, on the copy: the same releases, read from R2 directly
    /// (the app's reader stands down in a test process).
    private func keepStartingPointCredits(_ personal: PersonalInputs, context: ModelContext) async -> Int {
        let graph = GraphStore(context: context)
        let store = ReleaseCreditStore(context: context)
        var ids: [Int] = []
        for node in ExploreRanker.startingPoints(personal) {
            if node.kind == .artist {
                ids += graph.releaseIDs(creditedTo: RecordingKey.normalizeArtist(node.title))
                    .filter { $0 > 0 && store.credits(releaseID: $0) == nil }.sorted().prefix(24)
            } else if node.kind == .release, let id = node.discogsID, store.credits(releaseID: id) == nil {
                ids.append(id)
            }
        }
        var kept = 0
        for id in Set(ids).sorted() {
            guard let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let detail = try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data) else { continue }
            if store.replace(releaseID: id, from: detail, source: ReleaseCreditStore.source(storedRelease: id)) { kept += 1 }
        }
        try? context.save()
        return kept
    }

    private func copyStores(userData: URL, local: URL, label: String) throws -> ModelContainer {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Contributors-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(userData, "UserData.store"), (local, "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        return try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                  local: copy.appendingPathComponent("Local.store"))
    }

    /// The visible For You, as the app works it out, one line per offer.
    private func report(_ label: String, container: ModelContainer, personal: PersonalInputs, asOf: Date,
                        header: String) async throws {
        ForYouMusicianFirst.override = false
        defer { ForYouMusicianFirst.override = nil }
        let worker = DigWorker(modelContainer: container)
        let period = ExplorePeriod.containing(asOf)
        let started = ContinuousClock.now
        let run = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: false,
                                          rebuild: false, now: asOf, personal: personal)
        let ranking = ContinuousClock.now
        let offers = await worker.exploreRecommendations(run, asOf: asOf)
        let done = ContinuousClock.now

        var out = ["\(label): \(header)", "as of \(asOf)", ""]
        func line(_ block: String, _ offer: ExploreSuggestion) -> String {
            let route = MusicEdge(from: .artist(offer.via), to: offer.node, kind: offer.kind, source: .discogs,
                                  reason: offer.reason, confidence: 1)
            let contribution = ContributorRole.of(edge: route)?.rawValue ?? "-"
            return [block, offer.node.kind.rawValue, offer.node.title, offer.id, offer.kind.rawValue, contribution,
                    offer.reason, "via \(offer.via)", String(format: "%.4f", offer.score)].joined(separator: " | ")
        }
        out += offers.next.map { line("next", $0) } + offers.shows.map { line("show", $0) }
            + offers.artists.map { line("artist", $0) }
        // Who the walk reaches only through technical credits, and so is no
        // longer offered; and who it reaches through a technical credit and a
        // musical one, and is still offered for the second.
        let known = ExploreRanker.knownGround(run.personal)
        let seen = Set(known.map(\.node.id))
        let encountered = Set(run.personal.met.map(\.node.id)).union(run.alsoKnown)
        let sets = ExploreRanker.edgeSets(run.knowledge)
        var routes: [String: (node: MusicNode, edges: [MusicEdge])] = [:]
        for origin in known.prefix(ExploreSuggestionEngine.origins) {
            for connection in (sets[origin.node] ?? EdgeSet()).byDestination
            where connection.node.destination != nil && !seen.contains(connection.node.id)
                && !encountered.contains(connection.node.id) {
                let edges = connection.edges.filter { ExploreSuggestionEngine.worth($0) > 0 }
                guard !edges.isEmpty else { continue }
                routes[connection.node.id, default: (connection.node, [])].edges += edges
            }
        }
        let technical = routes.values.filter { $0.edges.contains { !ContributorRole.canRecommend($0) } }
            .sorted { $0.node.title < $1.node.title }
        let withheld = technical.filter { $0.edges.allSatisfy { !ContributorRole.canRecommend($0) } }
        let kept = technical.filter { $0.edges.contains(where: ContributorRole.canRecommend) }
        out.append("")
        out.append("starting points: " + known.prefix(ExploreSuggestionEngine.origins).map { "\($0.node.title) [\($0.node.id)]" }.joined(separator: "; "))
        out.append("candidates reached: \(routes.count); through a technical credit: \(technical.count); only so (withheld): \(withheld.count); also another way (kept): \(kept.count)")
        for (label, list) in [("withheld", withheld), ("kept", kept)] {
            for entry in list {
                let why = entry.edges.map { "\($0.reason) [\(ContributorRole.of(edge: $0)?.rawValue ?? $0.kind.rawValue)]" }
                out.append("\(label) | \(entry.node.title) | " + Array(Set(why)).sorted().prefix(4).joined(separator: "; "))
            }
        }
        out.append("")
        out.append("timing: build \(ranking - started), rank \(done - ranking)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foryou-contributors-\(label).txt")
        try out.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
