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
    let realName: String?
    let biography: String?
    let imageURL: URL?
    let genres: [String]
    let styles: [String]
    let aliases: [String]
    let discogsURL: URL?
    let releases: [ReleaseLine]
    let labels: [LabelRef]
    let related: [RelatedArtist]
    let libraryTrackCount: Int
    let crateCount: Int
    let radioAppearances: [AppearanceLine]
    /// Recordings of this artist's records, gathered from the releases already
    /// catalogued. Playable in the app's own transport.
    let listen: [DigReleaseProfile.ListenLine]

    nonisolated struct ReleaseLine: Identifiable, Hashable, Sendable {
        let title: String
        let year: String?
        let discogsID: Int?
        let imageURL: URL?
        let thumbnailURL: URL?
        let label: String?
        var id: String { discogsID.map { "discogs:\($0)" } ?? "\(title)|\(year ?? "")" }
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

    /// What a page can draw before the graph has been walked: the name it was
    /// opened with, and nothing claimed that is not known.
    static func placeholder(name: String, mbid: String?) -> ArtistProfile {
        ArtistProfile(
            name: name, mbid: mbid, origin: nil, disambiguation: nil, realName: nil,
            biography: nil, imageURL: nil, genres: [], styles: [], aliases: [],
            discogsURL: nil, releases: [], labels: [], related: [],
            libraryTrackCount: 0, crateCount: 0, radioAppearances: [], listen: []
        )
    }

    /// True when there is nothing but a name — the state where DIG should say
    /// so instead of rendering a page of empty headings.
    var isBare: Bool {
        releases.isEmpty && labels.isEmpty && related.isEmpty
            && biography == nil && imageURL == nil
            && libraryTrackCount == 0 && crateCount == 0 && radioAppearances.isEmpty
    }
}

nonisolated struct DigReleaseProfile: Sendable {
    let id: Int
    let title: String
    let year: Int?
    let artists: [String]
    let labels: [(name: String, catalogNumber: String?)]
    let genres: [String]
    let styles: [String]
    let imageURL: URL?
    let tracks: [TrackLine]
    let notes: String?
    let sourceURL: URL?
    /// Recordings catalogued alongside this release, playable in the app's own
    /// transport through YouTube's official player.
    let listen: [ListenLine]
    let related: [RelatedArtist]

    nonisolated struct ListenLine: Identifiable, Sendable {
        let url: URL
        let title: String
        let seconds: Int?
        var id: String { url.absoluteString }

        var durationLabel: String? {
            guard let seconds, seconds > 0 else { return nil }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }

    nonisolated struct TrackLine: Identifiable, Sendable {
        let position: String
        let title: String
        let duration: String?
        /// Named on compilations, absent on everything else.
        var artist: String?
        var id: String { "\(position)|\(title)" }
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
        let cachedDiscogs = DiscogsEnricher(context: context, client: DiscogsClient()).cachedArtist(named: name)
        let discogs = cachedDiscogs?.isFresh == true ? cachedDiscogs : nil
        let byArtist = recordings(byArtist: name)
        let entries = byArtist.compactMap { metadata(for: $0.id) }

        // Labels come from what this artist's music actually came out on.
        var labelNames: [String: String?] = [:]
        for entry in entries {
            guard let labelName = entry.labelName else { continue }
            labelNames[labelName] = entry.labelMBID
        }
        for label in discogs?.labelNames ?? [] where labelNames[label] == nil {
            // Assigning nil into a dictionary whose values are themselves
            // optional removes the key. `updateValue` is what actually stores
            // "known label, unknown MBID" — the ordinary case for anything
            // Discogs knows and MusicBrainz does not.
            labelNames.updateValue(nil, forKey: label)
        }
        let labels = labelNames
            .filter { LabelName.isRealLabel($0.key) }
            .sorted { $0.key < $1.key }
            .map { ArtistProfile.LabelRef(name: $0.key, mbid: $0.value) }

        let artistKey = RecordingKey.normalizeArtist(name)
        let resolvedReleases = ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
            .filter { release in
                release.artistNames.contains { RecordingKey.normalizeArtist($0) == artistKey }
            }
        let resolvedByTitle = Dictionary(
            resolvedReleases.map { (Self.releaseKey($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolvedByID = Dictionary(
            resolvedReleases.map { ($0.discogsID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let discogsReleases = (discogs?.releaseTitles ?? []).enumerated().map { index, title in
            let identifier = index < (discogs?.releaseDiscogsIDs.count ?? 0)
                ? discogs?.releaseDiscogsIDs[index] : nil
            // The artist's own catalogue row often carries no cover, while the
            // release we have already opened does. Reading the sleeve back off
            // the release cache is what stops a tile staying blank until
            // somebody clicks it.
            let resolved = identifier.flatMap { resolvedByID[$0] }
                ?? resolvedByTitle[Self.releaseKey(title)]
            return ArtistProfile.ReleaseLine(
                title: title,
                year: index < (discogs?.releaseYears.count ?? 0) ? discogs?.releaseYears[index] : nil,
                discogsID: identifier,
                imageURL: (index < (discogs?.releaseImageURLStrings.count ?? 0)
                    ? discogs?.releaseImageURLStrings[index].nonEmptyURL : nil) ?? resolved?.imageURL,
                thumbnailURL: index < (discogs?.releaseThumbnailURLStrings.count ?? 0)
                    ? discogs?.releaseThumbnailURLStrings[index].nonEmptyURL : nil,
                label: (index < (discogs?.releaseLabels.count ?? 0)
                    ? discogs?.releaseLabels[index].nonEmpty : nil) ?? resolved?.labelNames.first
            )
        }
        let mbReleases = (cached?.releases ?? []).map {
            let resolved = resolvedByTitle[Self.releaseKey($0.title)]
            return ArtistProfile.ReleaseLine(
                title: $0.title, year: $0.year, discogsID: resolved?.discogsID,
                imageURL: resolved?.imageURL, thumbnailURL: nil,
                label: resolved?.labelNames.first
            )
        }
        // Discogs rows are navigable and carry sleeves, so they always win a
        // title collision with MusicBrainz's text-only catalogue entry.
        var releaseTitles = Set<String>()
        let releases = (discogsReleases + mbReleases).filter {
            releaseTitles.insert(Self.releaseKey($0.title)).inserted
        }

        return ArtistProfile(
            name: discogs?.name ?? cached?.name ?? name,
            mbid: mbid ?? cached?.mbid,
            origin: cached?.origin,
            disambiguation: cached?.disambiguation,
            realName: discogs?.realName,
            biography: discogs?.biography.map(DiscogsEnricher.cleanProfile),
            imageURL: discogs?.imageURL,
            genres: discogs?.genres ?? cached?.genreTags ?? [],
            styles: discogs?.styles ?? [],
            aliases: discogs?.aliasNames ?? [],
            discogsURL: discogs?.profileURL,
            releases: releases,
            labels: labels,
            related: relatedArtists(to: name),
            libraryTrackCount: libraryTrackCount(artist: name),
            crateCount: crateCount(artist: name),
            radioAppearances: appearanceLines(for: byArtist),
            listen: Self.listenLines(from: resolvedReleases)
        )
    }

    /// Everything playable across an artist's catalogued releases, newest
    /// first and deduplicated — the same recording is often attached to a
    /// pressing and its reissue.
    private static func listenLines(from releases: [DiscogsReleaseRecord]) -> [DigReleaseProfile.ListenLine] {
        var seen = Set<String>()
        return releases
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            .flatMap(\.videos)
            .filter { seen.insert($0.url.absoluteString).inserted }
            .map { DigReleaseProfile.ListenLine(url: $0.url, title: $0.title, seconds: $0.seconds) }
    }

    private static func releaseKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    func releaseProfile(id: Int) -> DigReleaseProfile? {
        guard let record = DiscogsEnricher(context: context, client: DiscogsClient()).cachedRelease(id: id),
              record.isFresh else { return nil }
        let labels = record.labelNames.enumerated().map { index, name in
            (name, index < record.catalogNumbers.count ? record.catalogNumbers[index].nonEmpty : nil)
        }
        let tracks = record.trackTitles.enumerated().map { index, title in
            DigReleaseProfile.TrackLine(
                position: index < record.trackPositions.count ? record.trackPositions[index] : "",
                title: title,
                duration: index < record.trackDurations.count ? record.trackDurations[index].nonEmpty : nil,
                artist: index < record.trackArtists.count ? record.trackArtists[index].nonEmpty : nil
            )
        }
        var relatedByName: [String: RelatedArtist] = [:]
        for artist in record.artistNames {
            for peer in relatedArtists(to: artist) {
                relatedByName[peer.name] = peer
            }
        }
        return DigReleaseProfile(
            id: id, title: record.title, year: record.year, artists: record.artistNames,
            labels: labels, genres: record.genres, styles: record.styles,
            imageURL: record.imageURL, tracks: tracks, notes: record.notes,
            sourceURL: record.profileURL,
            listen: record.videos.map {
                DigReleaseProfile.ListenLine(url: $0.url, title: $0.title, seconds: $0.seconds)
            },
            related: relatedByName.values.sorted {
                $0.weight == $1.weight ? $0.name < $1.name : $0.weight > $1.weight
            }
        )
    }

    /// The spec's RELATED list. Every entry has to survive the question
    /// "why?" — so the only edges built here are ones with a stated reason.
    ///
    /// The reasoning itself lives in `GraphStore` now. It used to live here,
    /// which quietly meant DIG could only ever relate an artist to another
    /// artist: a label, a broadcast or a white label had nowhere to be put.
    /// This stays as the shape the existing pages read.
    func relatedArtists(to name: String) -> [RelatedArtist] {
        GraphStore(context: context)
            .relatedArtists(to: .artist(name))
            .map { RelatedArtist(name: $0.node.title, mbid: $0.node.mbid,
                                 reasons: $0.edges.map(\.relationship),
                                 imageURL: $0.node.artworkURL) }
    }

    /// Everything next to something, of any kind — the step DEEP takes.
    func connections(from node: MusicNode) -> [MusicGraph.Connection] {
        var graph = MusicGraph()
        graph.absorb(GraphStore(context: context).neighbors(of: node).all)
        return graph.connections(from: node)
    }

    private static func decade(_ year: String) -> Int? {
        guard let value = Int(year.prefix(4)), value > 0 else { return nil }
        return value / 10 * 10
    }

    private func addRadioConnections(
        for name: String,
        subject: String,
        into found: inout [String: [Relationship]]
    ) {
        let subjectShows = recordings(byArtist: name).flatMap(\.appearances).reduce(into: [String: String]()) {
            guard let showID = $1.showID else { return }
            $0["\($1.providerID)|\(showID)"] = $1.showTitle ?? $1.sourceLine
        }
        guard !subjectShows.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        for recording in all {
            guard let peer = recording.artistName,
                  RecordingKey.normalizeArtist(peer) != subject else { continue }
            if let match = recording.appearances.first(where: {
                guard let showID = $0.showID else { return false }
                return subjectShows["\($0.providerID)|\(showID)"] != nil
            }), let showID = match.showID {
                let title = subjectShows["\(match.providerID)|\(showID)"] ?? match.sourceLine
                found[peer, default: []].append(
                    Relationship(kind: .sharedBroadcast, source: .radio,
                                 detail: "Played in the same broadcast: \(title)", confidence: 0.7)
                )
            }
        }
    }

    private func addCollectionConnections(
        for name: String,
        subject: String,
        into found: inout [String: [Relationship]]
    ) {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let albums = Set(tracks.filter { Self.artistKeys(for: $0).contains(subject) }
            .map(\.albumKey).filter { !$0.isEmpty })
        guard !albums.isEmpty else { return }
        for track in tracks where albums.contains(track.albumKey) {
            let peer = track.artist.isEmpty ? track.albumArtist : track.artist
            guard !peer.isEmpty, RecordingKey.normalizeArtist(peer) != subject else { continue }
            found[peer, default: []].append(
                Relationship(kind: .sharedCollection, source: .library,
                             detail: "Together in your library: \(track.album)", confidence: 0.65)
            )
        }
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
                || ($0.kind == .artist && RecordingKey.normalizeArtist($0.displayTitle) == key)
        }.count
    }

    private func cratedArtistCounts() -> [String: Int] {
        let items = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        var counts: [String: Int] = [:]
        for item in items {
            let artist = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let artist, !artist.isEmpty else { continue }
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

private nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var nonEmptyURL: URL? { nonEmpty.flatMap(URL.init(string:)) }
}
