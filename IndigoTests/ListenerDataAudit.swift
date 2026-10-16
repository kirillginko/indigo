//
//  ListenerDataAudit.swift
//  IndigoTests
//
//  What the listener's synced history holds, and how much of it the taste
//  model and the starting points actually use: events by action, kind and
//  length; identity and style coverage at recording, release and artist
//  level; and what is left once activity is collapsed into Discover's
//  verified artist seeds and For You's twelve starting points.
//
//  Read-only, on copies of the stores. Opt-in: `INDIGO_LISTENER_AUDIT=1`.
//  Report (private): `listener-data-audit.txt` in the host's temporary
//  directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListenerDataAudit: XCTestCase {
    func testWhatTheHistoryHolds() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LISTENER_AUDIT"] == "1", "Set INDIGO_LISTENER_AUDIT=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ListenerAudit-\(UUID().uuidString)")
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
        var out: [String] = []
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }

        // Events.
        let events = try context.fetch(FetchDescriptor<ListeningEvent>(sortBy: [SortDescriptor(\.at)]))
        out.append("== listening events: \(events.count), \(events.first?.at.formatted(date: .abbreviated, time: .omitted) ?? "–") to \(events.last?.at.formatted(date: .abbreviated, time: .omitted) ?? "–")")
        let byActionKind = Dictionary(grouping: events) { "\($0.action.rawValue) \($0.kind.rawValue)" }.mapValues(\.count)
        out.append("  by action and kind: " + byActionKind.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let plays = events.filter { $0.action == .played }
        func bucket(_ s: Double) -> String { s < 5 ? "<5s" : s < 30 ? "5-30s" : s < 120 ? "30s-2m" : s < 600 ? "2-10m" : ">10m" }
        out.append("  played, by length: " + Dictionary(grouping: plays) { bucket($0.seconds) }.mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out.append("  played with a completion fraction: \(pct(plays.filter { $0.completion > 0 }.count, plays.count)); weight > 0: \(pct(plays.filter { $0.weight > 0 }.count, plays.count))")
        out.append("  carrying a Discogs id: \(pct(events.filter { $0.discogsID != nil }.count, events.count)); tags: \(pct(events.filter { !$0.tags.isEmpty }.count, events.count)); a radio source: \(pct(events.filter { $0.sourceProviderID != nil }.count, events.count))")
        let recordingEvents = events.filter { $0.kind == .recording }
        let distinctRecordings = Set(recordingEvents.map(\.nodeKey)).count
        let artistOf: (ListeningEvent) -> String? = { event in
            switch event.kind {
            case .artist: event.nodeKey
            case .recording: event.subtitle.map(RecordingKey.normalizeArtist)
            default: nil
            }
        }
        let distinctArtists = Set(events.compactMap(artistOf).filter { !$0.isEmpty }).count
        out.append("  distinct recordings \(distinctRecordings), distinct artists (artist or recording events) \(distinctArtists)")
        let skipped = events.filter { $0.action == .skipped }
        let skippedOnly = Set(skipped.compactMap(artistOf)).subtracting(events.filter { $0.weight > 0 }.compactMap(artistOf))
        out.append("  artists only ever skipped: \(skippedOnly.count); skips that were a station or show: \(skipped.filter { $0.kind == .station || $0.kind == .broadcast }.count) of \(skipped.count)")

        // Where listens started (recorded only by builds with ListeningSurface).
        let surfaced = events.filter { $0.surface != nil }
        out.append("  carrying the surface that started them: \(pct(surfaced.count, events.count))" + (surfaced.isEmpty ? "" : "; by screen: "
            + Dictionary(grouping: surfaced, by: { $0.surface!.screen }).mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        // First positive listen of each artist, by the surface that started it:
        // what found what.
        var firstFound: [String: ListeningEvent] = [:]
        for event in events where event.weight > 0 { if let key = artistOf(event), !key.isEmpty, firstFound[key] == nil { firstFound[key] = event } }
        let credited = firstFound.values.filter { $0.surface != nil }
        if !credited.isEmpty {
            out.append("  artists first heard, by the surface that found them: "
                + Dictionary(grouping: credited, by: { $0.surface!.screen }).mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }

        // Crate.
        let crate = try context.fetch(FetchDescriptor<CrateItem>())
        out.append("")
        out.append("== crate: \(crate.count)")
        out.append("  by kind: " + Dictionary(grouping: crate) { $0.kind.rawValue }.mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out.append("  with genre tags: \(pct(crate.filter { !$0.genreTags.isEmpty }.count, crate.count)); an artist: \(pct(crate.filter { !($0.artistName ?? "").isEmpty }.count, crate.count)); an album title: \(pct(crate.filter { !($0.albumTitle ?? "").isEmpty }.count, crate.count))")
        let releases = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>())
        var byTitleArtist: [String: DiscogsReleaseRecord] = [:]
        for record in releases {
            for artist in record.artistNames {
                byTitleArtist["\(RecordingKey.normalize(record.title))|\(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(artist)))"] = record
            }
        }
        let crateWithRelease = crate.filter { item in
            guard let album = item.albumTitle, let artist = item.artistName else { return false }
            return byTitleArtist["\(RecordingKey.normalize(album))|\(RecordingKey.normalizeArtist(artist))"] != nil
        }
        out.append("  recordings whose album is a release DIG holds (styles at release level): \(crateWithRelease.count)")

        // DIG.
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let steps = try context.fetch(FetchDescriptor<DigStep>())
        out.append("")
        out.append("== DIG: \(visits.count) pages visited (\(visits.reduce(0) { $0 + $1.visits }) visits), \(steps.count) steps between pages")
        out.append("  pages by kind: " + Dictionary(grouping: visits) { $0.kind.rawValue }.mapValues(\.count).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // Style coverage of the artists in the history.
        let discogsArtists = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let styled = Set(discogsArtists.filter { !$0.styles.isEmpty }.map(\.nameKey))
        let historyArtists = Set(events.filter { $0.weight > 0 }.compactMap(artistOf) + crate.compactMap { $0.artistName.map(RecordingKey.normalizeArtist) })
        out.append("")
        out.append("== style coverage: \(historyArtists.count) artists with positive history; \(pct(historyArtists.intersection(styled).count, historyArtists.count)) have Discogs styles on this device")

        // The collapse.
        let now = (events.last?.at ?? Date()).addingTimeInterval(3_600)
        let personal = PersonalInputs.read(context: context, asOf: now)
        let inputs = DigStore.discoverInputs(personal: personal, context: context, now: now, collaborators: false)
        let seedKeys = Set(inputs.seeds.map { RecordingKey.normalizeArtist($0.name) })
        var weightByArtist: [String: Double] = [:]
        for event in events where event.weight > 0 { if let key = artistOf(event) { weightByArtist[key, default: 0] += event.weight } }
        for item in crate { if let artist = item.artistName { weightByArtist[RecordingKey.normalizeArtist(artist), default: 0] += 1.5 } }
        let total = weightByArtist.values.reduce(0, +)
        let covered = weightByArtist.filter { seedKeys.contains($0.key) }.values.reduce(0, +)
        out.append("")
        out.append("== collapse into seeds")
        out.append("  Discover's seeds: \(inputs.seeds.count) verified artists, carrying \(String(format: "%.0f%%", 100 * covered / max(total, 1e-9))) of the positive weight across \(weightByArtist.count) artists")
        let starting = ExploreRanker.startingPoints(personal)
        out.append("  For You's starting points: \(starting.count) (" + Dictionary(grouping: starting) { $0.kind.rawValue }.mapValues(\.count).map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ") + ")")
        let taste = TasteProfile.collected(personal: personal, artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context), now: now)
        out.append("  today's taste profile: \(taste.weights.count) interests in one vector, evidence \(String(format: "%.1f", taste.evidence)); top: " + taste.top(10).map { "\($0.interest) \(String(format: "%.2f", $0.weight))" }.joined(separator: ", "))
        let lost = events.filter { $0.weight > 0 && $0.kind == .recording }.count
        out.append("  recording-level positive events reduced to their artist (title, release, completion dropped): \(lost)")

        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-data-audit.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
