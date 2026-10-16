//
//  ReleaseVideoTracks.swift
//  Indigo
//
//  An artist's own tracks from the recordings Discogs catalogues with their
//  releases: for an artist radio has nothing of. A video is a track of theirs
//  only when all of it agrees -- its title names a track on that release's
//  own tracklist, the release (or that track) is credited to them by
//  Discogs entry, and it is not footage or talk or somebody else's upload.
//  Read from what Indigo keeps: the artist's shelf (`CatalogShelfSource`) and
//  the release documents in storage -- no Discogs budget.
//

import Foundation

nonisolated struct ReleaseVideoTracks: Sendable {
    var shelf: @Sendable (Int) async -> DiscogsArtistReleases?
    var release: @Sendable (Int) async -> DiscogsReleaseDetail?
    /// How many of their newest records are read.
    var releases = 3

    func tracks(artistID: Int, artist: String) async -> [TrackDiscovery.Appearance] {
        guard let found = await shelf(artistID) else { return [] }
        let own = (found.releases ?? [])
            .filter { ($0.role == nil || $0.role == "Main") && !$0.isVideo }
            .sorted { ($0.year ?? 0, $0.id ?? 0) > ($1.year ?? 0, $1.id ?? 0) }
            .compactMap { $0.type == "master" ? $0.mainRelease : $0.id }
        // Read together, matched newest first.
        let ids = Array(own.prefix(releases))
        let details = await withTaskGroup(of: (Int, DiscogsReleaseDetail?).self) { group in
            for (index, id) in ids.enumerated() { group.addTask { (index, await release(id)) } }
            var found: [Int: DiscogsReleaseDetail] = [:]
            for await (index, detail) in group { found[index] = detail }
            return found
        }
        var tracks: [TrackDiscovery.Appearance] = []
        for index in ids.indices {
            guard let detail = details[index] else { continue }
            tracks += Self.match(detail, artistID: artistID, artist: artist)
            if tracks.count >= 2 { break }
        }
        return Array(tracks.prefix(2))
    }

    /// The release's recordings that are verifiably this artist's tracks.
    static func match(_ detail: DiscogsReleaseDetail, artistID: Int, artist: String) -> [TrackDiscovery.Appearance] {
        let releaseIsTheirs = (detail.artists ?? []).contains { $0.id == artistID }
        var tracks: [TrackDiscovery.Appearance] = []
        var used = Set<String>()
        for video in detail.videos ?? [] {
            guard let link = video.uri, let url = URL(string: link), YouTubeLink.isYouTube(url),
                  let title = video.title, TrackDiscovery.isTrackUpload(title: title, artist: artist) else { continue }
            let folded = RecordingKey.normalize(title)
            // The longest track title the video names: "Archangel" before "Angel".
            let named = (detail.tracklist ?? [])
                .compactMap { line -> (title: String, line: DiscogsTrackLine)? in
                    guard let name = line.title, RecordingKey.normalize(name).count >= 3,
                          folded.contains(RecordingKey.normalize(name)) else { return nil }
                    return (name, line)
                }
                .max { RecordingKey.normalize($0.title).count < RecordingKey.normalize($1.title).count }
            guard let named, used.insert(RecordingKey.normalize(named.title)).inserted else { continue }
            // Theirs by entry: the release's artist, or this track's.
            let trackIsTheirs = (named.line.artists ?? []).contains { $0.id == artistID }
            guard trackIsTheirs || (releaseIsTheirs && (named.line.artists ?? []).isEmpty) else { continue }
            tracks.append(.init(artistDiscogsID: artistID, artist: artist, title: named.title,
                                source: .recording(url, channel: nil), artworkURL: DiscoveredTrack.thumbnail(for: url),
                                genres: ListeningLog.foldTags((detail.styles ?? []) + (detail.genres ?? [])),
                                release: detail.title, year: (detail.year ?? 0) > 0 ? detail.year : nil))
        }
        return tracks
    }

    static let live = ReleaseVideoTracks(
        shelf: { id in await CatalogShelfSource.shared.shelf(discogsID: id) },
        release: { id in
            guard let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))),
                  let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data)
        }
    )
}
