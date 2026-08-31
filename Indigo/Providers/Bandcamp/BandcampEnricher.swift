//
//  BandcampEnricher.swift
//  Indigo
//
//  Caches what Bandcamp says, and answers the one question radio music keeps
//  asking: which record is this track on?
//
//  A great deal of underground music is on Bandcamp and nowhere else — no
//  MusicBrainz release, no Discogs pressing. Space Afrika's "MLN ft. Tony
//  Njoku" is in neither catalogue; it is track eight of *Quiet Storm*, and
//  Bandcamp says so on the album's own page. Without this the app can only
//  report that the record does not exist, which is both wrong and the exact
//  failure this whole feature is meant to avoid.
//

import Foundation
import SwiftData

nonisolated struct BandcampEnricher {
    let context: ModelContext
    let client: BandcampClient

    /// Bandcamp is read a page at a time and each page is a real request, so
    /// an artist's catalogue is walked in a bounded pass rather than
    /// exhaustively. Their recent records are the ones radio plays.
    static let releaseLimit = 12

    init(context: ModelContext, client: BandcampClient = BandcampClient()) {
        self.context = context
        self.client = client
    }

    // MARK: Reading the cache

    func cachedReleases(forArtist name: String) -> [BandcampRelease] {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? []
        return all.filter { $0.artistKey == key }
    }

    /// The record a track is on, if Bandcamp has already been read for this
    /// artist. Purely local — no request, so it is safe to call from anywhere.
    func release(containing track: String, byArtist name: String) -> BandcampRelease? {
        cachedReleases(forArtist: name).first { $0.contains(track: track) }
    }

    func index(forArtist name: String) -> BandcampArtistIndex? {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<BandcampArtistIndex>(
            predicate: #Predicate { $0.artistKey == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: Filling it

    /// Reads an artist's Bandcamp catalogue into the cache.
    ///
    /// `page` must have come from somewhere sanctioned — the artist's own
    /// Discogs or MusicBrainz entry, or a link the listener followed. Nothing
    /// here searches Bandcamp, because Bandcamp's robots.txt says not to.
    @discardableResult
    func enrich(artist name: String, page: URL, limit: Int = releaseLimit) async throws -> [BandcampRelease] {
        guard BandcampClient.isReadable(page) else { throw BandcampError.notABandcampPage }
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return [] }

        let existing = index(forArtist: name)
        let urls: [URL]
        if let existing, existing.isFresh, !existing.releaseURLStrings.isEmpty {
            urls = existing.releaseURLStrings.compactMap(URL.init(string:))
        } else {
            urls = try await client.releaseURLs(forArtistAt: page)
            let record = existing ?? {
                let fresh = BandcampArtistIndex(
                    artistKey: key, name: name, pageURLString: page.absoluteString
                )
                context.insert(fresh)
                return fresh
            }()
            record.name = name
            record.pageURLString = page.absoluteString
            record.releaseURLStrings = urls.map(\.absoluteString)
            record.fetchedAt = Date()
        }

        var stored: [BandcampRelease] = []
        let known = Dictionary(
            ((try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? [])
                .map { ($0.urlString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for url in urls.prefix(limit) {
            guard !Task.isCancelled else { break }
            if let cached = known[url.absoluteString] {
                stored.append(cached)
                continue
            }
            guard let info = try? await client.release(at: url) else { continue }
            stored.append(store(info, fallbackArtist: name))
        }
        try? context.save()
        return stored
    }

    /// Walks the catalogue only until the track turns up.
    ///
    /// The difference matters: finding one cover should not mean reading
    /// twelve pages of somebody's discography. Most tracks are on a recent
    /// record and this stops at the first page that names it.
    func findRelease(
        containing track: String,
        byArtist name: String,
        page: URL,
        limit: Int = releaseLimit
    ) async -> BandcampRelease? {
        if let already = release(containing: track, byArtist: name) { return already }
        guard BandcampClient.isReadable(page) else { return nil }

        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return nil }

        let existing = index(forArtist: name)
        let urls: [URL]
        if let existing, existing.isFresh, !existing.releaseURLStrings.isEmpty {
            urls = existing.releaseURLStrings.compactMap(URL.init(string:))
        } else {
            guard let found = try? await client.releaseURLs(forArtistAt: page) else { return nil }
            urls = found
            let record = existing ?? {
                let fresh = BandcampArtistIndex(
                    artistKey: key, name: name, pageURLString: page.absoluteString
                )
                context.insert(fresh)
                return fresh
            }()
            record.releaseURLStrings = urls.map(\.absoluteString)
            record.fetchedAt = Date()
        }

        let known = Set(cachedReleases(forArtist: name).map(\.urlString))
        for url in urls.prefix(limit) {
            guard !Task.isCancelled else { return nil }
            guard !known.contains(url.absoluteString) else { continue }
            guard let info = try? await client.release(at: url) else { continue }
            let record = store(info, fallbackArtist: name)
            if record.contains(track: track) {
                try? context.save()
                return record
            }
        }
        try? context.save()
        return nil
    }

    @discardableResult
    private func store(_ info: BandcampReleaseInfo, fallbackArtist: String) -> BandcampRelease {
        let address = info.url.absoluteString
        var descriptor = FetchDescriptor<BandcampRelease>(
            predicate: #Predicate { $0.urlString == address }
        )
        descriptor.fetchLimit = 1
        let artist = info.artistName.isEmpty ? fallbackArtist : info.artistName

        if let existing = (try? context.fetch(descriptor))?.first {
            existing.title = info.title
            existing.artistName = artist
            existing.artistKey = RecordingKey.normalizeArtist(artist)
            existing.labelName = info.labelName
            existing.year = info.year
            existing.imageURLString = info.imageURL?.absoluteString
            existing.trackTitles = info.trackTitles
            existing.trackKeys = info.trackTitles.map(RecordingKey.normalizeTitle)
            existing.keywords = info.keywords
            existing.fetchedAt = Date()
            return existing
        }

        let record = BandcampRelease(
            urlString: address,
            title: info.title,
            artistName: artist,
            labelName: info.labelName,
            year: info.year,
            imageURLString: info.imageURL?.absoluteString,
            trackTitles: info.trackTitles,
            keywords: info.keywords
        )
        context.insert(record)
        return record
    }
}
