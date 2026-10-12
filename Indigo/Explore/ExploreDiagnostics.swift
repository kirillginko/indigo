//
//  ExploreDiagnostics.swift
//  Indigo
//
//  Why For You says what it says on this device, in a form another device can
//  be compared with.
//
//  The Mac and the phone showing different suggestions used to be a mystery
//  with a dozen suspects. Each look now leaves its stamp -- the evaluation
//  day, and digests of the listener's rows, the shared knowledge and this
//  device's own -- beside a digest of what was ranked. Two devices' stamps
//  side by side say which of those differs, and so where to look: the same
//  stamp with different rankings would be a bug in the ranker; different
//  shared knowledge is what Indigo's backend is for; different device-local
//  knowledge is a library on one of them.
//
//  It is written to the trace file on every look, and the debug panel shows it
//  as a short code that can be pasted into the other device's panel.
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreDiagnostics {
    static let shared = ExploreDiagnostics()

    /// The last look this process made.
    private(set) var latest: Entry?
    /// The last time the backend's For You was set beside it.
    private(set) var shadow: ShadowReport?

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var stamp: ExploreStamp
        /// What was ranked, in the page's order: every id in every block, then
        /// the direction named.
        var ranked: [String]
        var report: ExploreBuildReport
        /// The pinned generation the shadow ranked from on this device and
        /// how much of these rows it covers (`PinnedShadow.codePart`), once
        /// the shadow has run. Never part of what the visible page used.
        var pinned: String? = nil

        var rankedDigest: String { CanonicalDigest.of(ranked) }

        /// `FY<format>.<day>.<personal>.<shared>.<device>.<identity>.<known>.<ranked>`,
        /// then `.g<manifest>.<coverage>` once the pinned generation's shadow
        /// has run,
        /// each digest cut to twelve characters: short enough to read out, long
        /// enough that two different inputs never share one in practice.
        ///
        /// The identity parts say whether two devices placed the same artists
        /// on the same evidence, apart from what they know about the music:
        /// the same shared digest with a different identity one means one
        /// device has verified an artist the other has not yet.
        var code: String {
            ["FY\(stamp.format)", "\(stamp.period)", Self.cut(stamp.personal), Self.cut(stamp.shared),
             Self.cut(stamp.deviceLocal), Self.cut(stamp.identity ?? "-"), Self.cut(stamp.known ?? "-"),
             Self.cut(rankedDigest)].joined(separator: ".") + (pinned.map { ".\($0)" } ?? "")
        }

        static func cut(_ digest: String) -> String { String(digest.prefix(12)) }

        /// The ranked ids for a set of offers.
        static func ranked(_ offers: ExploreOffers) -> [String] {
            var ids: [String] = offers.next.map(\.id)
            ids += offers.shows.map(\.id)
            ids += offers.artists.map(\.id)
            let toward: String = offers.movingToward.map { "toward:\($0.city)|\($0.sound)" } ?? "toward:-"
            ids.append(toward)
            return ids
        }
    }

    /// One line of a comparison.
    nonisolated struct Row: Equatable, Sendable {
        let input: String
        let here: String
        let there: String
        var matches: Bool { here == there }
    }

    /// Two codes side by side, part by part. Nil when either is not a code.
    /// A code from a build before identity has six parts; its identity parts
    /// read as "—".
    nonisolated static func compare(_ here: String, _ there: String) -> [Row]? {
        func parts(_ code: String) -> [String]? {
            let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map(String.init)
            guard parts.first?.hasPrefix("FY") == true else { return nil }
            switch parts.count {
            case 10: return parts
            case 8: return parts + ["—", "—"]
            case 6: return Array(parts[0..<5]) + ["—", "—", parts[5], "—", "—"]
            default: return nil
            }
        }
        guard let mine = parts(here), let theirs = parts(there) else { return nil }
        var names = ["Format", "Evaluation day", "Personal digest", "Shared knowledge digest",
                     "Device-local digest", "Identity evidence digest", "Known artists digest",
                     "Ranked recommendation IDs", "Pinned generation", "Pinned coverage"]
        // The pinned rows only when either code has them.
        if mine[8] == "—", theirs[8] == "—" { names.removeLast(2) }
        return names.indices.map { Row(input: names[$0], here: mine[$0], there: theirs[$0]) }
    }

    func record(_ entry: Entry) {
        latest = entry
        let parts = entry.report.milliseconds.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Int($0.value.rounded()))ms" }.joined(separator: " ")
        let sizes = entry.report.bytes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)B" }.joined(separator: " ")
        let identity = entry.report.counts.filter { $0.key.hasPrefix("identity") }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Trace.note("explore.stamp \(entry.code) rebuilt=[\(entry.report.rebuilt.joined(separator: ","))] \(parts) \(sizes) \(identity)")
    }

    func record(shadow report: ShadowReport) {
        shadow = report
        if let pinned = report.pinned, latest != nil {
            latest?.pinned = pinned.codePart
            let f = pinned.fetch
            Trace.note("explore.pinned \(latest!.code) source=\(f.source) selected=\(f.selected ?? "-") "
                       + "objects=\(f.objectsDownloaded)+\(f.objectsReused) bytes=\(f.bytesDownloaded) "
                       + "ms=\(Int(f.milliseconds.rounded())) cache=\(f.cacheBytes)B kept=\(f.keptGenerations) "
                       + "revoked=[\(f.revoked.joined(separator: ","))] errors=\(f.errors.count) "
                       + "top20=\(pinned.stage.top20Overlap)/20 shared=\(pinned.shared.prefix(12)) ranked=\(pinned.ranked.prefix(12))")
        }
        let c = report.comparison
        let ms = report.fetch.milliseconds.map { "\(Int($0.rounded()))" }.joined(separator: "+")
        Trace.note("explore.shadow source=\(report.source) top12=\(c.top12Overlap)/12 top20=\(c.top20Overlap)/20 "
                   + "missing=[\(c.missingKinds.joined(separator: ","))] reworded=\(c.reworded.count) "
                   + "calls=\(report.fetch.calls) bytes=\(report.fetch.bytes) ms=\(ms) errors=\(report.fetch.errors.count) "
                   + "stale=\(report.coverage.staleAnswers) generation=\(report.fetch.generation)")
    }

    /// Never freed; a main-actor deinit hop would abort if it were.
    nonisolated deinit {}
}
