//
//  DiscogsEnricher.swift
//  Indigo
//

import Foundation
import SwiftData

nonisolated struct DiscogsEnricher {
    let context: ModelContext
    let client: DiscogsClient

    @discardableResult
    func artist(named name: String, force: Bool = false) async throws -> DiscogsArtist? {
        // Rolled whenever what is stored changes shape: 3 added the artist's
        // own links, 4 kept the thumbnails arriving with each neighbour, 5
        // stopped filing pressing plants as imprints. A row cached before any
        // of those looks current while being wrong, so it is refetched once.
        if !force, let cached = cachedArtist(named: name), cached.cacheVersion >= 5,
           cached.isFresh { return cached }
        guard let bundle = try await client.artist(named: name) else { return nil }

        let detail = bundle.detail
        let releases = (bundle.releases.releases ?? []).filter {
            $0.role == nil || $0.role == "Main"
        }
        let uniqueReleases = releases.reduce(into: [DiscogsArtistRelease]()) { result, release in
            guard let title = release.title, !result.contains(where: { $0.title == title }) else { return }
            result.append(release)
        }
        let key = RecordingKey.normalizeArtist(name)
        let record = cachedArtist(named: name) ?? {
            let value = DiscogsArtist(nameKey: key, discogsID: detail.id, name: detail.name)
            context.insert(value)
            return value
        }()
        record.discogsID = detail.id
        record.name = detail.name
        record.realName = detail.realname
        record.biography = detail.profile.map(Self.cleanProfile)
        record.imageURLString = detail.images?.first(where: { $0.type == "primary" })?.uri
            ?? detail.images?.first?.uri ?? bundle.searchImageURL
        record.profileURLString = detail.uri
        record.aliasNames = detail.aliases?.compactMap(\.name) ?? []
        record.externalURLStrings = detail.urls ?? []
        record.memberNames = detail.members?.compactMap(\.name) ?? []
        record.groupNames = detail.groups?.compactMap(\.name) ?? []
        let catalogue = bundle.catalogue.filter { $0.id != nil }
        if !catalogue.isEmpty {
            record.releaseTitles = catalogue.map { Self.releaseTitle($0.title, artist: detail.name) }
            record.releaseYears = catalogue.map { $0.year ?? "" }
            record.releaseDiscogsIDs = catalogue.compactMap(\.id)
            record.releaseImageURLStrings = catalogue.map { $0.coverImage ?? "" }
            record.releaseThumbnailURLStrings = catalogue.map { $0.thumbnail ?? "" }
            record.releaseLabels = catalogue.map { ($0.label ?? []).first ?? "" }
        } else {
            let fallback = Array(uniqueReleases.prefix(30))
            record.releaseTitles = fallback.compactMap(\.title)
            record.releaseYears = fallback.map { $0.year.map(String.init) ?? "" }
            record.releaseDiscogsIDs = fallback.compactMap(\.id)
            record.releaseImageURLStrings = Array(repeating: "", count: fallback.count)
            record.releaseThumbnailURLStrings = Array(repeating: "", count: fallback.count)
            record.releaseLabels = fallback.map { $0.label ?? "" }
        }
        // Only the label each release names for itself.
        //
        // The search catalogue also carries a `label` array, but it holds
        // every company credited on the record — the pressing plant, the
        // mastering house, the distributor, the magazine that ran the mix. As
        // an artist's imprints that reads as nonsense: Space Afrika listed on
        // GZ Media and Bonati Mastering alongside Dais and sferic.
        record.labelNames = Array(Set(
            releases.compactMap(\.label).filter { LabelName.isRealLabel($0) }
        )).sorted()
        record.genres = Self.unique(bundle.catalogue.flatMap { $0.genre ?? [] })
        record.styles = Self.unique(bundle.catalogue.flatMap { $0.style ?? [] })
        record.collaboratorNames = Self.unique(
            (bundle.releases.releases ?? []).compactMap { release in
                guard release.role != nil, release.role != "Main" else { return nil }
                return release.artist
            }.filter { RecordingKey.normalizeArtist($0) != key }
        )
        record.fetchedAt = Date()
        record.cacheVersion = 5
        return record
    }

    func recommendations(for artist: DiscogsArtist, force: Bool = false) async throws {
        if !force, let fetchedAt = artist.recommendationsFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 { return }
        // The years the artist was actually working, so the era question is
        // about their contemporaries rather than about a decade.
        let years = artist.releaseYears.compactMap { Int($0.prefix(4)) }.filter { $0 > 1900 }
        let span = years.min().flatMap { low in years.max().map { low...$0 } }
        let bundle = try await client.recommendations(
            labels: artist.labelNames, styles: artist.styles, years: span
        )
        let subject = artist.nameKey
        let labelNeighbours = Self.unique(bundle.labelArtists.filter {
            RecordingKey.normalizeArtist($0.name) != subject
        })
        let styleNeighbours = Self.unique(bundle.styleArtists.filter {
            RecordingKey.normalizeArtist($0.name) != subject
        })
        artist.labelNeighbourNames = labelNeighbours.map(\.name)
        artist.labelNeighbourImageURLStrings = labelNeighbours.map { $0.thumbnailURL ?? "" }
        artist.styleNeighbourNames = styleNeighbours.map(\.name)
        artist.styleNeighbourImageURLStrings = styleNeighbours.map { $0.thumbnailURL ?? "" }
        artist.recommendationsFetchedAt = Date()
    }

    func cachedArtist(named name: String) -> DiscogsArtist? {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<DiscogsArtist>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @discardableResult
    func release(id: Int, force: Bool = false) async throws -> DiscogsReleaseRecord {
        if !force, let cached = cachedRelease(id: id), cached.isFresh { return cached }
        return store(try await client.release(id: id), id: id)
    }

    /// Writes a release Discogs has already described.
    ///
    /// Split from `release(id:)` so a caller can fetch several at once —
    /// which is network-bound and parallel — and then write them one at a
    /// time, which is what a single ModelContext requires.
    @discardableResult
    func store(_ detail: DiscogsReleaseDetail, id: Int) -> DiscogsReleaseRecord {
        let record = cachedRelease(id: id) ?? {
            let value = DiscogsReleaseRecord(discogsID: id, title: detail.title)
            context.insert(value)
            return value
        }()
        record.title = detail.title
        record.year = detail.year
        record.artistNames = detail.artists?.compactMap(\.name) ?? []
        record.labelNames = detail.labels?.compactMap(\.name) ?? []
        record.catalogNumbers = detail.labels?.compactMap(\.catno) ?? []
        record.genres = detail.genres ?? []
        record.styles = detail.styles ?? []
        record.imageURLString = detail.images?.first(where: { $0.type == "primary" })?.uri
            ?? detail.images?.first?.uri
        let tracks = detail.tracklist ?? []
        record.trackPositions = tracks.map { $0.position ?? "" }
        record.trackTitles = tracks.map { $0.title ?? "Untitled" }
        record.trackDurations = tracks.map { $0.duration ?? "" }
        record.trackArtists = tracks.map { $0.artistName ?? "" }
        let videos = (detail.videos ?? []).filter {
            $0.uri.flatMap(URL.init(string:)).map(YouTubeLink.isYouTube) ?? false
        }
        record.videoURLStrings = videos.map { $0.uri ?? "" }
        record.videoTitles = videos.map { $0.title ?? "" }
        record.videoDurations = videos.map { $0.duration ?? 0 }
        record.notes = detail.notes
        record.profileURLString = detail.uri
        record.fetchedAt = Date()
        return record
    }


    func cachedRelease(id: Int) -> DiscogsReleaseRecord? {
        var descriptor = FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.discogsID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }.prefix(12).map { $0 }
    }

    private static func unique(_ values: [DiscogsNeighbour]) -> [DiscogsNeighbour] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.name.lowercased()).inserted }.prefix(12).map { $0 }
    }

    private static func releaseTitle(_ title: String, artist: String) -> String {
        let prefix = "\(artist) - "
        return title.lowercased().hasPrefix(prefix.lowercased())
            ? String(title.dropFirst(prefix.count)) : title
    }


    static func cleanProfile(_ text: String) -> String {
        var value = text
        // Discogs profiles use compact database references such as [a123]
        // and [l456]. Those identifiers are meaningful to the API, never to
        // somebody reading an artist biography.
        value = value.replacingOccurrences(
            of: #"\[url=[^\]]+\]([^\[]*)\[/url\]"#,
            with: "$1", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[[almr]=([^\]]+)\]"#,
            with: "$1", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[[almr]\d+\]"#,
            with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[/?(?:b|i|u|url|a|l|m|r)\]"#,
            with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+([,.;:])"#, with: "$1", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
