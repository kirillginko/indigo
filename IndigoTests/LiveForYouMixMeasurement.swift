//
//  LiveForYouMixMeasurement.swift
//  IndigoTests
//
//  For You as one list, with its compass, on this Mac's real history: the
//  artists and shows as `DigWorker` ranks them, the tracks DIG Discover finds
//  (live, read-only), the records like the crate's, then the mix and the
//  compass as `DigStore.composeForYouMix` works them out -- and the result
//  drawn, Mac and phone, to PNGs.
//
//  Opt-in: `INDIGO_LIVE_FORYOU_MIX=1`. Report (private): `live-foryou-mix.txt`
//  and `foryou-mix-{mac,phone}.png` in the host's temporary directory.
//

import XCTest
import SwiftUI
import SwiftData
@testable import Indigo

@MainActor
final class LiveForYouMixMeasurement: XCTestCase {
    func testTheMixAndTheCompassOnTheRealHistory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_FORYOU_MIX"] == "1", "Live: set INDIGO_LIVE_FORYOU_MIX=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Mix-\(UUID().uuidString)")
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
        let probe = PersonalInputs.read(context: context, asOf: .distantFuture)
        let asOf = ((probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()).addingTimeInterval(3_600)
        var out: [String] = []
        func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

        var t = ContinuousClock.now
        let worker = DigWorker(modelContainer: container)
        let run = await worker.exploreRun(asOf: asOf, period: ExplorePeriod.containing(asOf), generation: 0, scenes: false,
                                          rebuild: false, now: asOf)
        let visibleOffers = await worker.exploreRecommendations(run, asOf: asOf)
        // The mix's own: deeper, producers only as artists.
        let (unfiltered, unproven) = await worker.forYouMixOffers(run, asOf: asOf)
        let evidenceStart = ContinuousClock.now
        let vouched = await ForYouArtistEvidence.onRadio(unproven)
        out.append("producer-only candidates without evidence on this device: \(unproven.map(\.title).joined(separator: ", ")); the shared catalogue vouches for \(unproven.filter { vouched.contains($0.id) }.map(\.title).joined(separator: ", ")) (\(ms(ContinuousClock.now - evidenceStart)))")
        let offers = ForYouArtistEvidence.kept(unfiltered, unproven: unproven, vouched: vouched)
        out.append("artists and shows: \(ms(ContinuousClock.now - t))")
        // Who the evidence rule left out: reached only by producing or
        // remixing, with no record or radio play of their own here.
        let plain = await worker.forYouMixOffersWithoutEvidence(run, asOf: asOf)
        let dropped = Set((plain.next + plain.artists).map(\.id)).subtracting((offers.next + offers.artists).map(\.id))
        out.append("left out as producers only: " + (plain.next + plain.artists).filter { dropped.contains($0.id) }
            .map { "\($0.node.title) (\($0.reason) · via \($0.via))" }.joined(separator: "; "))
        func origins(_ list: [ExploreSuggestion]) -> String {
            Dictionary(grouping: list, by: \.via).mapValues(\.count).sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        out.append("visible For You, by starting point: " + origins(visibleOffers.next + visibleOffers.artists))
        out.append("mix artists, by starting point: " + origins(offers.next + offers.artists))

        t = ContinuousClock.now
        var source = TrackDiscoverySource.live
        source.cache = TrackDiscoveryCache()
        let inputs = DigStore.discoverInputs(context: ModelContext(container), now: asOf)
        let tracks = await source.discover(.init(seeds: inputs.seeds, collaborators: inputs.collaborators, taste: inputs.taste,
                                                 knownArtists: inputs.knownArtists, knownTracks: inputs.knownTracks,
                                                 limit: 12, releaseLookups: 2)).tracks
        out.append("tracks (live, cold): \(ms(ContinuousClock.now - t))")

        t = ContinuousClock.now
        let similar = SimilarRecords.find(context: context, asOf: asOf)
        out.append("records: \(ms(ContinuousClock.now - t))")

        t = ContinuousClock.now
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let offered = Set(tracks.map { RecordingKey.normalizeArtist($0.artist) }
            + (offers.next + offers.artists).filter { $0.node.kind == .artist }.map { RecordingKey.normalizeArtist($0.node.title) })
        let tags = LocalKnowledgeAdapter.artistTags(for: offered.union(personal.tasteArtistKeys), in: context)
        let items = ForYouMix.mix(offers: offers, tracks: tracks, records: similar.records, artistTags: tags)
        let longTerm = TasteProfile.collected(personal: personal, artistTags: tags, now: asOf).weights
        let recent = MusicalCompass.recentTaste(personal, artistTags: tags, asOf: asOf)
        let compass = MusicalCompass.draw(longTerm: longTerm, recent: recent, items: items.map { (id: $0.id, tags: $0.tags) },
                                          vectors: similar.styleVectors)
        out.append("mix and compass: \(ms(ContinuousClock.now - t))")
        let again = ForYouMix.mix(offers: offers, tracks: tracks, records: similar.records, artistTags: tags)
        out.append("mix worked out twice, same list: \(again.map(\.id) == items.map(\.id))")

        out.append("")
        out.append("long-term taste: " + longTerm.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", "))
        out.append("last fortnight: " + recent.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", "))
        if let compass {
            out.append("compass: across \(compass.horizontal.0) ↔ \(compass.horizontal.1); up \(compass.vertical.0) ↔ \(compass.vertical.1); now at (\(String(format: "%.2f", compass.now?.x ?? 0)), \(String(format: "%.2f", compass.now?.y ?? 0))) \(compass.now?.heading ?? "-")")
        } else {
            out.append("compass: none (too little taste)")
        }
        let points = Dictionary((compass?.points ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.append("")
        out.append("mix, items per starting point: " + Dictionary(grouping: items, by: \.via).mapValues(\.count)
            .sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out.append("For you, one list (\(items.count); kinds \(Dictionary(grouping: items, by: \.kind).mapValues(\.count).sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))):")
        for (index, item) in items.enumerated() {
            let place = points[item.id].map { String(format: "(%.2f, %.2f) %@, %@", $0.x, $0.y, $0.heading, ForYouMixSection.closeness($0.distance)) } ?? "not placed (no tags)"
            out.append("\(index + 1). [\(item.kind.rawValue)] \(item.title) — \(item.subtitle) | \(item.reason) | via \(item.via) | \(place)")
        }
        // Checks, item by item.
        out.append("")
        out.append("checks:")
        let tracksInMix = items.compactMap { if case .track(let track) = $0.payload { track } else { nil } }
        out.append("  tracks not checked to play: \(tracksInMix.filter { $0.playable != .yes }.count) of \(tracksInMix.count)")
        // The listener's artists and every alias their own entries list.
        var own = personal.tasteArtistKeys
        for met in personal.met where met.node.kind == .artist { own.insert(met.node.key) }
        let discogsRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        var aliasOf: [String: String] = [:]
        for row in discogsRows where own.contains(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(row.name))) {
            for alias in row.aliasNames { aliasOf[RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(alias))] = row.name }
        }
        for record in try context.fetch(FetchDescriptor<DiscogsIdentityRecord>()) where own.contains(RecordingKey.normalizeArtist(record.name)) {
            for alias in record.aliasNames { aliasOf[RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(alias))] = record.name }
        }
        let knownHits = items.filter { !$0.artistKeys.isDisjoint(with: own) }
        let aliasHits = items.filter { $0.artistKeys.contains { aliasOf[$0] != nil } }
        out.append("  by an artist they keep or have played: \(knownHits.count)\(knownHits.isEmpty ? "" : " — " + knownHits.map { "\($0.title) (\($0.subtitle), \($0.kind.rawValue))" }.joined(separator: "; "))")
        out.append("  an alias of one of theirs: \(aliasHits.count)\(aliasHits.isEmpty ? "" : " — " + aliasHits.map { "\($0.subtitle) = \($0.artistKeys.compactMap { aliasOf[$0] }.joined())" }.joined(separator: "; "))")
        // How recent each item's starting point is.
        func lastTouched(_ title: String) -> Date? {
            let key = RecordingKey.normalizeArtist(title)
            let dates = personal.crate.filter { $0.node?.title == title || $0.tasteArtistKeys.contains(key) }.map(\.addedAt)
                + personal.met.filter { $0.node.title == title || $0.node.key == key }.map(\.lastAt)
                + personal.haunts.filter { $0.node.title == title }.map(\.lastVisitedAt)
            return dates.max()
        }
        var fresh = 0, older = 0, unknownAge = 0
        var lines: [String] = []
        for item in items {
            let via: String
            switch item.payload {
            case .track(let track): via = track.via
            case .record(let found): via = found.via.artistLine
            case .suggestion(let suggestion): via = suggestion.via
            }
            if via == "what you listen to" { unknownAge += 1; lines.append("    \(item.title): from the shape of their listening"); continue }
            guard let at = lastTouched(via) else { unknownAge += 1; lines.append("    \(item.title): via \(via), not found in the history"); continue }
            let days = asOf.timeIntervalSince(at) / 86_400
            if days <= 14 { fresh += 1 } else { older += 1 }
            lines.append(String(format: "    %@: via %@, last touched %.0f days before", item.title, via, days))
        }
        out.append("  starting points: \(fresh) items from the last fortnight, \(older) from longer ago, \(unknownAge) other")
        out += lines
        // Explanations: a record's shared styles are on both records; a
        // track's "next to X" names the starting point it came from.
        var wrong: [String] = []
        for item in items {
            switch item.payload {
            case .record(let found):
                let claimed = found.reason.components(separatedBy: " · ").first ?? ""
                for style in claimed.components(separatedBy: ", ") where !style.contains("~") && !style.isEmpty && style != "Close in sound" {
                    if !found.record.styles.contains(style.lowercased()) || !found.via.styles.contains(style.lowercased()) {
                        wrong.append("\(item.title): '\(style)' is not on both records")
                    }
                }
            case .track(let track):
                if track.reason.hasPrefix("Played next to ") && !track.reason.contains(track.via) { wrong.append("\(item.title): reason does not name \(track.via)") }
            case .suggestion(let suggestion):
                if suggestion.via != "what you listen to" && lastTouched(suggestion.via) == nil { wrong.append("\(item.title): via \(suggestion.via), not in the history") }
            }
        }
        out.append("  explanations contradicted by the data: \(wrong.count)\(wrong.isEmpty ? "" : " — " + wrong.joined(separator: "; "))")
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-foryou-mix.txt"),
                                              atomically: true, encoding: .utf8)

        // Drawn, as the app draws it.
        ForYouMixFeature.override = true
        defer { ForYouMixFeature.override = nil }
        let dig = DigStore(context: ModelContext(try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(
            schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))))
        dig.forYouMix = ForYouMixState(items: items, compass: compass, at: Date())
        func environment(_ view: some View) -> some View {
            view.environment(dig).environment(AppState()).environment(PlaybackCoordinator())
                .environment(NTSBrowseStore()).environment(LotBrowseStore()).environment(DublabBrowseStore())
                .environment(Radio80000BrowseStore()).environment(N10ASBrowseStore())
        }
        func write(_ view: some View, _ name: String) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            #if os(macOS)
            let png = try XCTUnwrap(renderer.nsImage.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
            #else
            let png = try XCTUnwrap(renderer.uiImage?.pngData())
            #endif
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        try write(environment(ForYouMixSection().frame(width: 1000).padding(.bottom, 24).background(MosaicColor.cobalt)), "foryou-mix-mac.png")
        try write(environment(ForYouMixSection(shown: 8).padding(.horizontal, 16).frame(width: 390).background(Color.black)
            .environment(\.isPhoneLayout, true)), "foryou-mix-phone.png")
    }
}
