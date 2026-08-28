//
//  DigEngine.swift
//  Indigo
//
//  Builds the profiles DIG renders by composing four sources: what MusicBrainz
//  knows, what's in the listener's library, what's in their crate, and what
//  they actually heard on air. The last two are the ones no catalogue has, and
//  they're the reason this is worth building.
//
//  Everything here reads the local cache. A profile must render with the
//  network off; enrichment fills the cache separately.
//

import Foundation
import SwiftData

nonisolated struct ArtistProfile: Sendable {
    let name: String
    let mbid: String?
    let origin: String?
    let disambiguation: String?
    let releases: [ReleaseLine]
    let labels: [LabelRef]
    let related: [RelatedArtist]
    let libraryTrackCount: Int
    let crateCount: Int
    let radioAppearances: [AppearanceLine]

    nonisolated struct ReleaseLine: Identifiable, Hashable, Sendable {
        let title: String
        let year: String?
        var id: String { "\(title)|\(year ?? "")" }
    }

    nonisolated struct LabelRef: Identifiable, Hashable, Sendable {
        let name: String
        let mbid: String?
        var id: String { mbid ?? name }
    }

    nonisolated struct AppearanceLine: Identifiable, Hashable, Sendable {
        let label: String
        let count: Int
        var id: String { label }
    }

    /// True when there is nothing but a name — the state where DIG should say
    /// so instead of rendering a page of empty headings.
    var isBare: Bool {
        releases.isEmpty && labels.isEmpty && related.isEmpty
            && libraryTrackCount == 0 && crateCount == 0 && radioAppearances.isEmpty
    }
}

nonisolated struct LabelProfile: Sendable {
    let name: String
    let mbid: String
    let origin: String?
    let founded: String?
    let artists: [RelatedArtist]
    let releases: [String]
    let catalogueSize: Int
    let libraryTrackCount: Int
    let crateCount: Int
    let radioAppearances: Int
}

nonisolated struct DigEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Artist

    func artistProfile(name: String, mbid: String?) -> ArtistProfile {
        // Falls back to the name when there is no MusicBrainz ID: an artist
        // reached from the library alone never has one, and that is exactly
        // the case the page must still fill in.
        let enricher = MusicBrainzEnricher(context: context)
        let cached = mbid.flatMap { enricher.cachedArtist($0) } ?? enricher.cachedArtistNamed(name)
        let byArtist = recordings(byArtist: name)
        let entries = byArtist.compactMap { metadata(for: $0.id) }

        // Labels come from what this artist's music actually came out on.
        var labelNames: [String: String?] = [:]
        for entry in entries {
            guard let labelName = entry.labelName else { continue }
            labelNames[labelName] = entry.labelMBID
        }
        let labels = labelNames
            .sorted { $0.key < $1.key }
            .map { ArtistProfile.LabelRef(name: $0.key, mbid: $0.value) }

        return ArtistProfile(
            name: cached?.name ?? name,
            mbid: mbid ?? cached?.mbid,
            origin: cached?.origin,
            disambiguation: cached?.disambiguation,
            releases: (cached?.releases ?? []).map {
                ArtistProfile.ReleaseLine(title: $0.title, year: $0.year)
            },
            labels: labels,
            related: relatedArtists(to: name, labels: labels),
            libraryTrackCount: libraryTrackCount(artist: name),
            crateCount: crateCount(artist: name),
            radioAppearances: appearanceLines(for: byArtist)
        )
    }

    /// The spec's RELATED list. Every entry has to survive the question
    /// "why?" — so the only edges built here are ones with a stated reason.
    func relatedArtists(to name: String, labels: [ArtistProfile.LabelRef]) -> [RelatedArtist] {
        var found: [String: [Relationship]] = [:]
        let subject = RecordingKey.normalizeArtist(name)

        for label in labels {
            guard let mbid = label.mbid,
                  let cached = MusicBrainzEnricher(context: context).cachedLabel(mbid)
            else { continue }
            for peer in cached.roster where RecordingKey.normalizeArtist(peer.name) != subject {
                found[peer.name, default: []].append(
                    Relationship(
                        kind: .sharedLabel,
                        source: .musicBrainz,
                        detail: "Same label: \(cached.name)",
                        confidence: 0.9
                    )
                )
            }
        }

        // Being in the crate is evidence too — the listener's own judgement,
        // which is worth more than a catalogue edge in a discovery tool.
        for (peerName, count) in cratedArtistCounts() where RecordingKey.normalizeArtist(peerName) != subject {
            guard found[peerName] != nil else { continue }
            found[peerName]?.append(
                Relationship(
                    kind: .inYourCrate,
                    source: .crate,
                    detail: "\(count) \(count == 1 ? "track" : "tracks") in your crate",
                    confidence: 0.4
                )
            )
        }

        let identifiers = labelRosterIdentifiers(labels)
        return found
            .map { RelatedArtist(name: $0.key, mbid: identifiers[$0.key], reasons: $0.value) }
            .sorted { $0.weight == $1.weight ? $0.name < $1.name : $0.weight > $1.weight }
    }

    // MARK: - Label

    func labelProfile(mbid: String, fallbackName: String) -> LabelProfile? {
        guard let cached = MusicBrainzEnricher(context: context).cachedLabel(mbid) else {
            return LabelProfile(
                name: fallbackName, mbid: mbid, origin: nil, founded: nil,
                artists: [], releases: [], catalogueSize: 0,
                libraryTrackCount: 0, crateCount: 0, radioAppearances: 0
            )
        }

        let roster = cached.roster.map { entry in
            RelatedArtist(
                name: entry.name,
                mbid: entry.mbid,
                reasons: [
                    Relationship(kind: .sharedLabel, source: .musicBrainz,
                                 detail: "Releases on \(cached.name)", confidence: 0.9)
                ]
            )
        }

        let onLabel = recordings(onLabel: mbid)
        return LabelProfile(
            name: cached.name,
            mbid: mbid,
            origin: cached.origin,
            founded: cached.foundedYear,
            artists: roster,
            releases: cached.releaseTitles,
            catalogueSize: cached.catalogueSize,
            libraryTrackCount: roster.reduce(0) { $0 + libraryTrackCount(artist: $1.name) },
            crateCount: onLabel.filter { isCrated($0) }.count,
            radioAppearances: onLabel.reduce(0) { $0 + $1.appearances.count }
        )
    }

    // MARK: - Local evidence

    func recordings(byArtist name: String) -> [Recording] {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        return all.filter { RecordingKey.normalizeArtist($0.artistName) == key }
    }

    private func recordings(onLabel mbid: String) -> [Recording] {
        let entries = (try? context.fetch(
            FetchDescriptor<RecordingMetadata>(predicate: #Predicate { $0.labelMBID == mbid })
        )) ?? []
        let ids = Set(entries.map(\.recordingID))
        guard !ids.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        return all.filter { ids.contains($0.id) }
    }

    func libraryTrackCount(artist name: String) -> Int {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return 0 }
        let all = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        return all.filter { Self.artistKeys(for: $0).contains(key) }.count
    }

    /// Which artists a track counts towards. A track credited to one performer
    /// on a compilation belongs to both them and the compilation, so it is
    /// filed under each — and the index and the artist page have to agree
    /// about that, or the same library reads as 5 in one place and 6 in the
    /// other.
    static func artistKeys(for track: Track) -> Set<String> {
        Set([
            RecordingKey.normalizeArtist(track.artist),
            RecordingKey.normalizeArtist(track.albumArtist)
        ].filter { !$0.isEmpty })
    }

    func crateCount(artist name: String) -> Int {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return 0 }
        let items = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        return items.filter {
            RecordingKey.normalizeArtist($0.recording?.artistName) == key
        }.count
    }

    private func cratedArtistCounts() -> [String: Int] {
        let items = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        var counts: [String: Int] = [:]
        for item in items {
            guard let artist = item.recording?.artistName, !artist.isEmpty else { continue }
            counts[artist, default: 0] += 1
        }
        return counts
    }

    private func labelRosterIdentifiers(_ labels: [ArtistProfile.LabelRef]) -> [String: String] {
        var identifiers: [String: String] = [:]
        let enricher = MusicBrainzEnricher(context: context)
        for label in labels {
            guard let mbid = label.mbid, let cached = enricher.cachedLabel(mbid) else { continue }
            for entry in cached.roster where entry.mbid != nil {
                identifiers[entry.name] = entry.mbid
            }
        }
        return identifiers
    }

    /// "NTS / Moxie ×3" — the part no catalogue can tell you.
    private func appearanceLines(for recordings: [Recording]) -> [ArtistProfile.AppearanceLine] {
        var counts: [String: Int] = [:]
        for recording in recordings {
            for appearance in recording.appearances {
                counts[appearance.sourceLine, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ArtistProfile.AppearanceLine(label: $0.key, count: $0.value) }
    }

    private func isCrated(_ recording: Recording) -> Bool {
        let id = recording.id
        var descriptor = FetchDescriptor<CrateItem>(predicate: #Predicate { $0.recording?.id == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first) != nil
    }

    func metadata(for recordingID: UUID) -> RecordingMetadata? {
        MusicBrainzEnricher(context: context).metadata(for: recordingID)
    }
}
