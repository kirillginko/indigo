//
//  MusicBrainzEnricher.swift
//  Indigo
//
//  Turns a recording into a node with edges: who made it, what it came out on,
//  and which label put it there. Everything it learns is folded into the
//  existing Recording — MusicBrainz contributes identifiers, it does not
//  become the identity.
//

import Foundation
import SwiftData

nonisolated struct MusicBrainzEnricher {
    let context: ModelContext
    let client: MusicBrainzClient

    init(context: ModelContext, client: MusicBrainzClient = MusicBrainzClient()) {
        self.context = context
        self.client = client
    }

    // MARK: - Recording

    /// Looks a recording up and caches what comes back. Unknown recordings are
    /// skipped outright: there is nothing to search MusicBrainz with, and a
    /// blind query would return somebody else's music with high confidence.
    @discardableResult
    func enrich(_ recording: Recording, force: Bool = false) async throws -> RecordingMetadata? {
        guard recording.isIdentified, let title = recording.title, !title.isEmpty else { return nil }

        let existing = metadata(for: recording.id)
        if !force, let existing, !existing.lookupFailed { return existing }

        let match: MBRecording?
        if let mbid = recording.musicBrainzRecordingID, !mbid.isEmpty {
            match = try await client.recording(id: mbid)
        } else {
            match = try await client.searchRecording(artist: recording.artistName, title: title)
        }

        let metadata = existing ?? {
            let fresh = RecordingMetadata(recordingID: recording.id)
            context.insert(fresh)
            return fresh
        }()

        guard let match else {
            metadata.lookupFailed = true
            metadata.fetchedAt = Date()
            return metadata
        }

        // Fold the canonical facts back into the recording itself.
        recording.apply(
            title: match.title,
            artistName: match.primaryArtist?.name,
            albumTitle: match.primaryRelease?.title,
            musicBrainzRecordingID: match.id,
            isrc: match.isrcs?.first,
            durationSeconds: match.durationSeconds
        )

        metadata.artistMBID = match.primaryArtist?.id
        metadata.artistName = match.primaryArtist?.name
        metadata.releaseMBID = match.primaryRelease?.id
        metadata.releaseTitle = match.primaryRelease?.title
        metadata.releaseDate = match.primaryRelease?.date
        metadata.releaseType = match.primaryRelease?.releaseGroup?.primaryType
        metadata.lookupFailed = false
        metadata.fetchedAt = Date()

        // The search endpoint carries no label info, so the release has to be
        // fetched to find out who put it out — the edge DIG leans on hardest.
        //
        // Plenty of MusicBrainz releases genuinely have no label attached, so
        // one miss is not an answer: try the next pressing before giving up.
        // Errors deliberately propagate rather than being swallowed — a
        // throttled lookup that quietly wrote "no label" would be cached as
        // fact and never retried.
        if metadata.labelMBID == nil {
            for candidate in match.releaseCandidates.prefix(2) {
                guard let releaseID = candidate.id else { continue }
                let release = try await client.release(id: releaseID)
                guard let info = release.labelInfo?.first(where: { $0.label?.id != nil }) else {
                    continue
                }
                metadata.labelMBID = info.label?.id
                metadata.labelName = info.label?.name
                metadata.catalogNumber = info.catalogNumber
                // The release that named a label is the one worth showing.
                metadata.releaseMBID = releaseID
                metadata.releaseTitle = release.title ?? metadata.releaseTitle
                metadata.releaseDate = release.date ?? metadata.releaseDate
                break
            }
        }
        return metadata
    }

    // MARK: - Artist

    /// Resolves an artist from a name alone — the case that matters most,
    /// because an artist you only own files by has no catalogued recording to
    /// work back from.
    ///
    /// Two requests: find them, then browse their discography. Deriving the
    /// same thing by enriching their tracks one at a time cost upwards of
    /// thirty, which is how you get throttled.
    @discardableResult
    func artist(named name: String, force: Bool = false) async throws -> Artist? {
        if !force, let cached = cachedArtistNamed(name), !cached.releaseTitles.isEmpty {
            return cached
        }
        guard let match = try await client.searchArtist(name: name), let mbid = match.id else {
            return nil
        }

        let groups = try await client.releaseGroups(artistID: mbid)
        let sorted = (groups.releaseGroups ?? [])
            .filter { $0.primaryType == "Album" || $0.primaryType == "EP" }
            .sorted { ($0.firstReleaseDate ?? "") > ($1.firstReleaseDate ?? "") }

        let artist = cachedArtist(mbid) ?? {
            let fresh = Artist(mbid: mbid, name: match.name ?? name)
            context.insert(fresh)
            return fresh
        }()
        artist.name = match.name ?? artist.name
        artist.origin = match.origin ?? artist.origin
        artist.disambiguation = match.disambiguation
        artist.type = match.type
        artist.releaseTitles = sorted.compactMap(\.title)
        artist.releaseDates = sorted.map { $0.firstReleaseDate ?? "" }
        artist.genreTags = Self.genreTags(match.tags)
        artist.fetchedAt = Date()
        return artist
    }

    /// Matches on the normalised name, so a cached "Kelly Moran" is found for
    /// "kelly moran" without a round trip.
    func cachedArtistNamed(_ name: String) -> Artist? {
        let key = RecordingKey.normalize(name)
        guard !key.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Artist>())) ?? []
        return all.first { RecordingKey.normalize($0.name) == key }
    }

    @discardableResult
    func artist(mbid: String, force: Bool = false) async throws -> Artist {
        if !force, let cached = cachedArtist(mbid) { return cached }

        let fetched = try await client.artist(id: mbid)
        let groups = (fetched.releaseGroups ?? [])
            .filter { $0.primaryType == "Album" || $0.primaryType == "EP" || $0.primaryType == nil }
            .sorted { ($0.firstReleaseDate ?? "") > ($1.firstReleaseDate ?? "") }

        if let cached = cachedArtist(mbid) {
            cached.name = fetched.name ?? cached.name
            cached.origin = fetched.origin ?? cached.origin
            cached.disambiguation = fetched.disambiguation
            cached.type = fetched.type
            cached.releaseTitles = groups.compactMap(\.title)
            cached.releaseDates = groups.map { $0.firstReleaseDate ?? "" }
            cached.genreTags = Self.genreTags(fetched.tags)
            cached.fetchedAt = Date()
            return cached
        }

        let artist = Artist(
            mbid: mbid,
            name: fetched.name ?? "Unknown Artist",
            sortName: fetched.sortName,
            disambiguation: fetched.disambiguation,
            type: fetched.type,
            origin: fetched.origin,
            releaseTitles: groups.compactMap(\.title),
            releaseDates: groups.map { $0.firstReleaseDate ?? "" },
            genreTags: Self.genreTags(fetched.tags)
        )
        context.insert(artist)
        return artist
    }

    // MARK: - Label

    /// MusicBrainz has no "who is on this label" endpoint, so the roster is
    /// derived: browse the catalogue and count who accounts for it.
    @discardableResult
    func label(mbid: String, force: Bool = false) async throws -> MusicLabel {
        if !force, let cached = cachedLabel(mbid), !cached.artistNames.isEmpty { return cached }

        let fetched = try await client.label(id: mbid)
        let browse = try await client.releases(labelID: mbid)
        let releases = browse.releases ?? []

        var counts: [String: Int] = [:]
        var identifiers: [String: String] = [:]
        for release in releases {
            for credit in release.artistCredit ?? [] {
                guard let name = credit.artist?.name ?? credit.name, name != "Various Artists" else { continue }
                counts[name, default: 0] += 1
                if let id = credit.artist?.id { identifiers[name] = id }
            }
        }
        let roster = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(24)

        let label = cachedLabel(mbid) ?? {
            let fresh = MusicLabel(mbid: mbid, name: fetched.name ?? "Unknown Label")
            context.insert(fresh)
            return fresh
        }()

        label.name = fetched.name ?? label.name
        label.type = fetched.type
        label.origin = fetched.origin
        label.foundedYear = fetched.lifeSpan?.begin.map { String($0.prefix(4)) }
        label.artistNames = roster.map(\.key)
        label.artistMBIDs = roster.map { identifiers[$0.key] ?? "" }
        label.releaseTitles = Array(
            releases
                .sorted { ($0.date ?? "") > ($1.date ?? "") }
                .compactMap(\.title)
                .reduce(into: [String]()) { unique, title in
                    if !unique.contains(title) { unique.append(title) }
                }
                .prefix(30)
        )
        label.catalogueSize = browse.releaseCount ?? releases.count
        label.fetchedAt = Date()
        return label
    }

    // MARK: - Cache

    func metadata(for recordingID: UUID) -> RecordingMetadata? {
        var descriptor = FetchDescriptor<RecordingMetadata>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func cachedArtist(_ mbid: String) -> Artist? {
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.mbid == mbid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func cachedLabel(_ mbid: String) -> MusicLabel? {
        var descriptor = FetchDescriptor<MusicLabel>(predicate: #Predicate { $0.mbid == mbid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func genreTags(_ tags: [MBTag]?) -> [String] {
        (tags ?? [])
            .filter { ($0.count ?? 0) > 0 }
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .compactMap(\.name)
            .prefix(5)
            .map { $0.capitalized }
    }
}
