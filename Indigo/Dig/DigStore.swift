//
//  DigStore.swift
//  Indigo
//
//  The observable face of DIG. Views read profiles synchronously from the
//  local cache and kick off enrichment separately, so a page always renders
//  immediately and fills in when MusicBrainz answers.
//

import Foundation
import Observation
import SwiftData

@Observable
final class DigStore {
    private(set) var isEnriching = false
    /// Bumped when enrichment writes, so profiles are re-read.
    private(set) var revision = 0
    var notice: String?

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let client: MusicBrainzClient
    /// Keys already looked up this session, so revisiting a page doesn't
    /// re-hit a rate-limited public service.
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var backgroundWarmupStarted = false

    init(context: ModelContext, client: MusicBrainzClient = MusicBrainzClient()) {
        self.context = context
        self.client = client
    }

    private var engine: DigEngine { DigEngine(context: context) }
    private var enricher: MusicBrainzEnricher { MusicBrainzEnricher(context: context, client: client) }

    // MARK: - Profiles

    func artistProfile(name: String, mbid: String?) -> ArtistProfile {
        let _ = revision
        return engine.artistProfile(name: name, mbid: mbid)
    }

    func labelProfile(mbid: String, fallbackName: String) -> LabelProfile? {
        let _ = revision
        return engine.labelProfile(mbid: mbid, fallbackName: fallbackName)
    }

    /// Where "DIG →" on a recording should land. Prefers the MusicBrainz
    /// artist we already resolved so the page opens with a real graph.
    func destination(for recording: Recording) -> DetailPage? {
        guard let artist = recording.artistName, !artist.isEmpty else { return nil }
        let mbid = engine.metadata(for: recording.id)?.artistMBID
        return .digArtist(mbid: mbid, name: artist)
    }

    func genres(for recording: Recording) -> [String] {
        let _ = revision
        guard let mbid = engine.metadata(for: recording.id)?.artistMBID else { return [] }
        return enricher.cachedArtist(mbid)?.genreTags ?? []
    }

    // MARK: - Enrichment

    /// Warms the small part of the catalogue the listener is most likely to
    /// open: crated recordings first, then a few local-library artists. This
    /// remains deliberately bounded because the public service is throttled;
    /// it is latency hiding, not a bulk library-matching job.
    func warmCacheInBackground(recordingLimit: Int = 6, artistLimit: Int = 4) async {
        guard !backgroundWarmupStarted else { return }
        backgroundWarmupStarted = true

        // Let startup indexing and radio hydration take the foreground first.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        let crated = ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? [])
            .compactMap(\.recording)
        var recordings = uniqueRecordings(crated)

        if recordings.count < recordingLimit {
            let localTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
            for track in localTracks where recordings.count < recordingLimit {
                if let recording = try? RecordingStore(context: context).recording(for: track),
                   !recordings.contains(where: { $0.id == recording.id }) {
                    recordings.append(recording)
                }
            }
        }

        // Artist profiles are the cheapest useful result (two requests) and
        // unlock both instant DIG pages and genre tags, so warm them before
        // slower release/label matching for individual recordings.
        var seenArtists = Set<String>()
        let artists = recordings.compactMap(\.artistName).filter {
            seenArtists.insert(RecordingKey.normalizeArtist($0)).inserted
        }
        for name in artists.prefix(artistLimit) {
            guard !Task.isCancelled else { return }
            do {
                if var artist = try await enricher.artist(named: name) {
                    // Tags are optional and never delay a foreground DIG
                    // page. Refresh them only during this launch warm-up.
                    if artist.genreTags.isEmpty {
                        artist = try await enricher.artist(mbid: artist.mbid, force: true)
                    }
                    backfillLocalGenres(artistName: name, genres: artist.genreTags)
                }
                try? context.save()
                revision &+= 1
            } catch is CancellationError {
                return
            } catch {
                // Background warming is opportunistic. A foreground page can
                // retry and communicate failure if the listener asks for it.
                continue
            }
        }

        for recording in recordings.prefix(recordingLimit) {
            guard !Task.isCancelled else { return }
            do {
                try await enricher.enrich(recording)
                backfillLocalTrack(from: recording)
                try? context.save()
                revision &+= 1
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    private func backfillLocalGenres(artistName: String, genres: [String]) {
        guard let genre = genres.first, !genre.isEmpty else { return }
        let key = RecordingKey.normalizeArtist(artistName)
        guard !key.isEmpty else { return }
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        for track in tracks where track.genre.isEmpty && DigEngine.artistKeys(for: track).contains(key) {
            track.genre = genre
        }
    }

    private func uniqueRecordings(_ values: [Recording]) -> [Recording] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    /// Catalogue facts only fill genuine holes; they never overwrite the
    /// listener's file tags. The local library remains the authority for its
    /// own spelling and organisation.
    private func backfillLocalTrack(from recording: Recording) {
        let paths = Set(recording.sources.filter { $0.kind == .localFile }.map(\.identifier))
        guard !paths.isEmpty else { return }
        let metadata = engine.metadata(for: recording.id)
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        for track in tracks where paths.contains(track.path) {
            if track.title.isEmpty || track.title == "Unknown" {
                track.title = recording.title ?? track.title
            }
            if track.artist.isEmpty || track.artist == "Unknown Artist" {
                track.artist = recording.artistName ?? track.artist
            }
            if track.album.isEmpty || track.album == "Unknown Album" {
                track.album = recording.albumTitle ?? metadata?.releaseTitle ?? track.album
            }
            if track.year == 0, let year = metadata?.releaseDate?.prefix(4), let value = Int(year) {
                track.year = value
            }
            track.albumKey = LibraryKey.album(
                album: track.album,
                albumArtist: track.albumArtist.isEmpty ? track.artist : track.albumArtist
            )
            track.artistKey = LibraryKey.normalize(track.albumArtist.isEmpty ? track.artist : track.albumArtist)
            track.sortTitle = LibraryKey.normalize(track.title)
            track.searchIndex = LibraryKey.searchIndex(title: track.title, artist: track.artist, album: track.album)
        }
    }

    /// Fills the cache behind an artist page, cheaply.
    ///
    /// The order matters. Resolving the artist by name costs two requests and
    /// works for anyone — including someone you only own files by, who has no
    /// catalogued recording to work back from. Only then, and only for a
    /// couple of recordings, is a label looked up, because a label is what
    /// RELATED is built from and nothing else on the page needs one.
    func enrichArtist(name: String, mbid: String?) async {
        let key = "artist:\(mbid ?? name)"
        // A notice belongs to the page that produced it. Cleared before the
        // guard, or an error from one artist follows you onto the next.
        notice = nil
        guard !attempted.contains(key) else { return }
        attempted.insert(key)

        isEnriching = true

        // Stage one: who they are and what they released. Two requests, and
        // enough on its own for a page worth looking at.
        do {
            if let mbid {
                try await enricher.artist(mbid: mbid)
            } else {
                try await enricher.artist(named: name)
            }
            // Saved here, not at the end: a throttle in stage two must not
            // discard what stage one already learned.
            try? context.save()
            revision &+= 1
        } catch is CancellationError {
            isEnriching = false
            return
        } catch {
            isEnriching = false
            attempted.remove(key)
            notice = message(for: error)
            return
        }

        isEnriching = false

        // Releases are now visible. Labels/relationships continue without
        // keeping the page's loading state alive.
        await enrichArtistConnections(name: name, mbid: mbid, key: key)
    }

    private func enrichArtistConnections(name: String, mbid: String?, key: String) async {
        // Stage two: the label, which is what RELATED is built from. A label
        // is only reachable through a recording, and an artist known only
        // from local files has none — so a couple are materialised from their
        // tracks. This is an explicit dig, not a render, so writing is fair.
        do {
            if engine.recordings(byArtist: name).isEmpty {
                materialiseRecordings(forArtist: name, limit: 2)
            }
            // Two is enough; enriching eight was up to twenty-four requests
            // for a single page, which is how the client got throttled.
            for recording in engine.recordings(byArtist: name).prefix(2) {
                try await enricher.enrich(recording)
            }
            let labels = Set(
                engine.recordings(byArtist: name)
                    .compactMap { engine.metadata(for: $0.id)?.labelMBID }
            )
            for label in labels.prefix(1) {
                try await enricher.label(mbid: label)
            }
            try? context.save()
            revision &+= 1
        } catch is CancellationError {
        } catch {
            // Stage two is an enrichment, not the page. Losing it costs the
            // RELATED column; saying so in red over a page that loaded fine
            // reads as a failure when nothing the listener asked for failed.
            attempted.remove(key)
            if engine.artistProfile(name: name, mbid: mbid).isBare {
                notice = message(for: error)
            }
        }
    }

    func enrichLabel(mbid: String) async {
        let key = "label:\(mbid)"
        notice = nil
        guard !attempted.contains(key) else { return }
        attempted.insert(key)

        isEnriching = true
        defer { isEnriching = false }

        do {
            try await enricher.label(mbid: mbid)
            try? context.save()
            revision &+= 1
        } catch is CancellationError {
        } catch {
            attempted.remove(key)
            notice = message(for: error)
        }
    }

    /// Promotes local files to canonical recordings so they have somewhere to
    /// hang a release and a label.
    private func materialiseRecordings(forArtist name: String, limit: Int) {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return }
        let tracks = ((try? context.fetch(FetchDescriptor<Track>())) ?? [])
            .filter { DigEngine.artistKeys(for: $0).contains(key) }
            .prefix(limit)

        let recordings = RecordingStore(context: context)
        for track in tracks {
            _ = try? recordings.recording(for: track)
        }
    }

    /// Lets a page retry after a throttle. The failed key was already
    /// released, so this just runs the lookup again.
    func retryArtist(name: String, mbid: String?) async {
        attempted.remove("artist:\(mbid ?? name)")
        await enrichArtist(name: name, mbid: mbid)
    }

    func retryLabel(mbid: String) async {
        attempted.remove("label:\(mbid)")
        await enrichLabel(mbid: mbid)
    }

    /// Enriches one recording on demand — used when DIG is opened straight
    /// from a crate row whose artist we have never looked up.
    func enrich(recording: Recording) async {
        let key = "recording:\(recording.id)"
        guard !attempted.contains(key) else { return }
        attempted.insert(key)

        isEnriching = true
        defer { isEnriching = false }
        do {
            try await enricher.enrich(recording)
            try? context.save()
            revision &+= 1
        } catch is CancellationError {
        } catch {
            attempted.remove(key)
            notice = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
