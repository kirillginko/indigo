//
//  ListeningAttributionAudit.swift
//  IndigoTests
//
//  Read-only diagnostics for listening attribution, on copies of a store:
//
//  - attributed playback by surface and by recommendation origin, one per
//    listen however many rows it wrote;
//  - whether the rows of each listen really are one listen in this history
//    (one recording, one artist, the recording's artist the artist);
//  - what a build from before attribution would make of tagged rows: its
//    taste loop read every tag, so the attribution tags take a share of each
//    event and the strongest of them sets the scale.
//
//  Opt-in: `INDIGO_ATTRIBUTION_AUDIT=1`. The store is this Mac's, or the
//  folder in `INDIGO_ATTRIBUTION_STORE` (a simulator's, say). Report
//  (private): `listening-attribution-audit.txt` in the host's temporary
//  directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListeningAttributionAudit: XCTestCase {
    func testAttributionInThisHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["INDIGO_ATTRIBUTION_AUDIT"] == "1", "Set INDIGO_ATTRIBUTION_AUDIT=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let folders: [(URL, String)] = environment["INDIGO_ATTRIBUTION_STORE"].map { path in
            [(URL(fileURLWithPath: path), "UserData.store"), (URL(fileURLWithPath: path), "Local.store")]
        } ?? [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")]
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Attribution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in folders {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        let events = try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>(sortBy: [SortDescriptor(\.at)]))
        var out: [String] = ["== store: \(environment["INDIGO_ATTRIBUTION_STORE"] ?? "this Mac")", "\(events.count) events"]

        // By surface and origin.
        out.append("")
        out += AttributionSummary(events).lines

        // Are the rows of a listen one listen?
        let playbacks = ListeningPlayback.group(events)
        var shapes: [String: Int] = [:]
        var mismatched = 0
        for p in playbacks {
            let shape = [p.recording != nil ? "recording" : nil, p.artist != nil ? "artist" : nil].compactMap { $0 } + p.others.map(\.rawValue).sorted()
            shapes[shape.joined(separator: "+"), default: 0] += 1
        }
        // The recording's artist and the artist row agree, where both exist.
        let rows = Dictionary(grouping: events.filter { $0.action == .played || $0.action == .skipped }, by: ListeningPlayback.key)
        for (_, group) in rows {
            let artists = Set(group.filter { $0.kind == .artist }.map { RecordingKey.normalizeArtist($0.title) })
            let credited = Set(group.filter { $0.kind == .recording }.compactMap { $0.subtitle.map(RecordingKey.normalizeArtist) })
            if group.filter({ $0.kind == .recording }).count > 1 || artists.count > 1 || (!artists.isEmpty && !credited.isEmpty && artists != credited) { mismatched += 1 }
        }
        out.append("")
        out.append("== one listen, several rows: \(playbacks.count) listens from \(playbacks.reduce(0) { $0 + $1.rows }) rows")
        out.append("  shapes: " + shapes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out.append("  listens whose rows disagree (two recordings, two artists, or an artist not the recording's): \(mismatched)")

        // A build from before attribution, if every event carried a typical
        // attribution (three tags). Its loop, as it was:
        func oldTaste(_ tags: (ListeningEvent) -> [String]) -> [String: Double] {
            let now = (events.last?.at ?? Date()).addingTimeInterval(60)
            var totals: [String: Double] = [:]
            for event in events {
                let weight = event.weight
                let all = tags(event)
                guard weight != 0, !all.isEmpty else { continue }
                let age = now.timeIntervalSince(event.at)
                let decayed = weight * (age <= 0 ? 1 : pow(0.5, age / TasteProfile.halfLife))
                for tag in all { totals[tag, default: 0] += decayed / Double(all.count) }
            }
            let positive = totals.filter { $0.value > 0 }
            guard let strongest = positive.values.max() else { return [:] }
            return positive.mapValues { min(1, $0 / strongest) }
        }
        let typical = ListeningSurface(screen: "foryou.mix", via: "someone", route: "track").tags
        let today = oldTaste { $0.musicTags }
        let tagged = oldTaste { $0.musicTags + typical }
        let music = today.keys.filter { tagged[$0] != nil }
        let ratios = music.map { tagged[$0]! / max(today[$0]!, 1e-12) }.sorted()
        let topToday = Array(today.sorted { $0.value > $1.value }.prefix(20).map(\.key))
        let topTagged = Array(tagged.filter { !ListeningSurface.isSurfaceTag($0.key) }.sorted { $0.value > $1.value }.prefix(20).map(\.key))
        let crossed = music.filter { today[$0]! > 0.15 && tagged[$0]! <= 0.15 }.count
        out.append("")
        out.append("== an older build reading fully attributed history (its loop counts every tag)")
        out.append("  music interests keep \(Set(topToday).intersection(topTagged).count) of today's top 20; their weights scale by \(String(format: "%.2f", ratios.first ?? 0))–\(String(format: "%.2f", ratios.last ?? 0)) (median \(String(format: "%.2f", ratios.isEmpty ? 0 : ratios[ratios.count / 2])))")
        out.append("  interests that fall from above to below the 0.15 a scene needs: \(crossed) of \(music.filter { today[$0]! > 0.15 }.count)")
        out.append("  strongest interest in that build: \(tagged.max { $0.value < $1.value }?.key ?? "–")")
        // A month of it: only the last thirty days attributed.
        let monthStart = (events.last?.at ?? Date()).addingTimeInterval(-30 * 86_400)
        let month = oldTaste { $0.at >= monthStart ? $0.musicTags + typical : $0.musicTags }
        let monthRatios = music.compactMap { key in month[key].map { $0 / max(today[key]!, 1e-12) } }.sorted()
        out.append("  with only the last 30 days attributed: weights scale by median \(String(format: "%.2f", monthRatios.isEmpty ? 0 : monthRatios[monthRatios.count / 2])); below 0.15: \(music.filter { today[$0]! > 0.15 && (month[$0] ?? 0) <= 0.15 }.count) of \(music.filter { today[$0]! > 0.15 }.count); strongest: \(month.max { $0.value < $1.value }?.key ?? "–")")

        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listening-attribution-audit.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
