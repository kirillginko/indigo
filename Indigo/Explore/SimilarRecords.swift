//
//  SimilarRecords.swift
//  Indigo
//
//  "Records like yours" on For You: records that resemble the ones the
//  listener keeps (`RecordSimilarity`, hybrid), from the records DIG already
//  holds -- no request is made for it. Seeded from the crate's records in the
//  order For You chooses its starting points (what they are into now, then
//  what they have kept over time), or, for a crate of tracks, from records by
//  the artists they keep. Never a record they have, nor one by an artist they
//  keep or have played: these are for finding.
//
//  Development builds only (`SimilarRecordsFeature`).
//

import Foundation
import SwiftData
import SwiftUI

/// A record found, and the one of theirs it is like.
nonisolated struct SimilarRecord: Identifiable, Equatable, Sendable {
    let record: RecordProfile
    let via: RecordProfile
    let reason: String
    let score: Double
    var id: Int { record.id }
}

nonisolated enum SimilarRecords {
    /// Worked out from a context: the seeds chosen and the records found.
    static func find(context: ModelContext, asOf: Date, limit: Int = 8, scenes withScenes: Bool = true)
        -> (seeds: [RecordProfile], records: [SimilarRecord], styleVectors: [String: [String: Double]]) {
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let records = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []
        let pool = records.map(RecordProfile.init(record:))
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // What they have: never offered back.
        var held = Set<Int>()
        for item in personal.crate { if let id = item.node?.discogsID, item.node?.kind == .release { held.insert(id) } }
        for met in personal.met where met.node.kind == .release { if let id = met.node.discogsID { held.insert(id) } }
        var knownArtists = personal.tasteArtistKeys
        for met in personal.met where met.node.kind == .artist { knownArtists.insert(met.node.key) }

        let seeds = Self.seeds(personal: personal, records: byID, asOf: asOf)
        var scenes: [String: Set<String>] = [:]
        if withScenes {
            for city in LocalKnowledgeAdapter(context: context).sceneCatalogue().cities {
                for scene in city.scenes { for member in scene.members { scenes[member, default: []].insert(scene.id) } }
            }
        }
        let similarity = RecordSimilarity(pool: pool, scenes: scenes)
        let found = similarity.similar(to: seeds, limit: limit, perSeed: 2, excluding: held, excludingArtists: knownArtists)
        return (seeds, found.map { SimilarRecord(record: $0.match.record, via: $0.seed, reason: $0.match.reason, score: $0.match.score) },
                similarity.vectors)
    }

    /// Up to eight records of theirs with two styles or more, at most two by one artist: the crate's
    /// records in For You's starting-point order, then records DIG holds by
    /// the artists they keep.
    static func seeds(personal: PersonalInputs, records: [Int: RecordProfile], asOf: Date, count: Int = 8) -> [RecordProfile] {
        var chosen: [RecordProfile] = []
        var perArtist: [String: Int] = [:]
        // At most two records by any one artist, joint records counting for
        // each of theirs: eight records by one saxophonist and his sidemen
        // are one taste, not eight.
        func take(_ record: RecordProfile) {
            // A record with one style tag finds everything else with that
            // tag, which is not a resemblance worth showing.
            guard chosen.count < count, !chosen.contains(where: { $0.id == record.id }),
                  Set(record.styles).count >= 2,
                  record.artistKeys.allSatisfy({ perArtist[$0, default: 0] < 2 }) else { return }
            for artist in record.artistKeys { perArtist[artist, default: 0] += 1 }
            chosen.append(record)
        }
        for origin in MusicianFirstRanker.startingPoints(personal, asOf: asOf, count: 40)
        where origin.node.kind == .release {
            if let id = origin.node.discogsID, let record = records[id] { take(record) }
        }
        for item in personal.crate where item.node?.kind == .release {
            if let id = item.node?.discogsID, let record = records[id] { take(record) }
        }
        if chosen.count < count {
            // Their artists' records DIG holds, the artists they play most first.
            let artists = personal.artistPlays.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
                + personal.tasteArtistKeys.sorted()
            var seen = Set<String>()
            for artist in artists where seen.insert(artist).inserted && chosen.count < count {
                for record in records.values.sorted(by: { $0.id < $1.id }) where record.artistKeys.contains(artist) {
                    take(record)
                }
            }
        }
        return chosen
    }
}

/// What "Records like yours" is showing.
struct SimilarRecordsState: Sendable {
    var records: [SimilarRecord] = []
    /// The pool's style embedding, kept for the musical compass.
    var styleVectors: [String: [String: Double]] = [:]
    var at: Date?
    var working = false
}

/// On the Mac, a band under "Tracks to hear"; each row opens the record.
struct SimilarRecordsSection: View {
    @Environment(DigStore.self) private var dig
    @Environment(AppState.self) private var appState

    var body: some View {
        let state = dig.similarRecords
        Group {
            if !state.records.isEmpty {
                DigSection(title: "Records like yours", trailing: "from what DIG holds") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.records) { found in
                            Button { appState.open(.digRelease(id: found.record.id, title: found.record.title)) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    ArtworkView(remoteURL: found.record.artworkURL, side: 44, glyphScale: 0.3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(found.record.title).font(Typeface.body(13.5, weight: .medium)).lineLimit(1)
                                        Text([found.record.artistLine, found.record.year.map(String.init)].compactMap { $0 }
                                            .joined(separator: " · ")).font(Typeface.mono(11))
                                        Text("Like \(found.via.title) · \(found.reason)").font(Typeface.mono(10.5)).opacity(0.65)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .foregroundStyle(Palette.ink)
                .background(Color.white.opacity(0.94))
                .padding(.horizontal, 28).padding(.top, 18)
            }
        }
        .task { await dig.refreshSimilarRecords() }
    }
}

extension DigStore {
    /// Works "Records like yours" out again unless a fresh answer is held:
    /// off the main thread, from the store alone, kept half an hour.
    func refreshSimilarRecords(force: Bool = false) async {
        guard SimilarRecordsFeature.isEnabled || ForYouMixFeature.isEnabled else { return }
        if !force, let at = similarRecords.at, Date().timeIntervalSince(at) < 30 * 60 { return }
        guard !similarRecords.working else { return }
        similarRecords.working = true
        let container = context.container
        let found = await Task.detached(priority: .utility) {
            Trace.step("foryou.similar") {
                let found = SimilarRecords.find(context: ModelContext(container), asOf: Date())
                return (found.records, found.styleVectors)
            }
        }.value
        similarRecords = SimilarRecordsState(records: found.0, styleVectors: found.1, at: Date(), working: false)
    }
}
