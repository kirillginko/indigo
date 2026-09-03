//
//  DiscogsEnricher.swift
//  Indigo
//

import Foundation
import SwiftData

nonisolated struct DiscogsEnricher {
    let context: ModelContext
    let client: DiscogsClient
    /// Indigo's own cache, tried before the provider. Defaults to the shared
    /// one, which is inert under XCTest so fixture tests stay offline.
    var catalog: CatalogReleaseSource = .shared

    /// Who they are, from the search alone.
    ///
    /// One round trip in, this is enough for the page to stop being empty:
    /// the name as the catalogue spells it, and a picture. The discography
    /// and the rest arrive a round trip later and fill in around it.
    ///
    /// Deliberately does not stamp `fetchedAt` or `cacheVersion` — this is a
    /// partial row, and it must not be mistaken for a complete one by the
    /// freshness check below.
    @discardableResult
    func artistIdentity(named name: String, head: DiscogsSearchResult) -> DiscogsArtist {
        let key = RecordingKey.normalizeArtist(name)
        let record = cachedArtist(named: name) ?? {
            let value = DiscogsArtist(nameKey: key, discogsID: head.id ?? 0, name: name)
            context.insert(value)
            return value
        }()
        if let id = head.id { record.discogsID = id }
        if record.imageURLString == nil {
            record.imageURLString = head.coverImage ?? head.thumbnail
        }
        if record.thumbnailURLString == nil {
            record.thumbnailURLString = head.thumbnail ?? head.coverImage
        }
        return record
    }

    @discardableResult
    func artist(named name: String, force: Bool = false) async throws -> DiscogsArtist? {
        // Rolled whenever what is stored changes shape: 3 added the artist's
        // own links, 4 kept the thumbnails arriving with each neighbour, 5
        // stopped filing pressing plants as imprints, 6 keeps the artist's
        // own thumbnail so a portrait has something to show before the
        // photograph arrives, 7 strips a credit off a release title even when
        // the sleeve spells it differently — rows written before that kept
        // "Boards Of Canada = ボーズ・オブ・カナダ*" in front of every title,
        // and a title like that resolves to no record at all. A row cached
        // before any of those looks current while being wrong, so it is
        // refetched once.
        if !force, let cached = cachedArtist(named: name), cached.cacheVersion >= 7,
           cached.isFresh { return cached }
        guard let bundle = try await client.artist(named: name) else { return nil }
        return write(bundle, name: name)
    }

    /// The same, for a caller that has already done the search.
    @discardableResult
    func artist(named name: String, head: DiscogsSearchResult, force: Bool = false) async throws -> DiscogsArtist? {
        if !force, let cached = cachedArtist(named: name), cached.cacheVersion >= 7,
           cached.isFresh { return cached }
        guard let bundle = try await client.artist(named: name, head: head) else { return nil }
        return write(bundle, name: name)
    }

    private func write(_ bundle: DiscogsArtistBundle, name: String) -> DiscogsArtist? {

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
        // The title of the page. Discogs files a second Oliwa as "Oliwa (2)",
        // and left alone that number becomes the artist's name at the top of
        // their own page.
        record.name = DiscogsClient.withoutDisambiguator(detail.name)
        record.realName = detail.realname.map(DiscogsClient.withoutDisambiguator)
        record.biography = detail.profile.map(Self.cleanProfile)
        record.imageURLString = detail.images?.first(where: { $0.type == "primary" })?.uri
            ?? detail.images?.first?.uri ?? bundle.searchImageURL
        record.thumbnailURLString = detail.images?.first(where: { $0.type == "primary" })?.uri150
            ?? detail.images?.first?.uri150 ?? bundle.searchThumbnailURL
            ?? record.thumbnailURLString
        record.profileURLString = detail.uri
        record.aliasNames = (detail.aliases?.compactMap(\.name) ?? []).map(DiscogsClient.withoutDisambiguator)
        record.externalURLStrings = detail.urls ?? []
        record.memberNames = (detail.members?.compactMap(\.name) ?? []).map(DiscogsClient.withoutDisambiguator)
        record.groupNames = (detail.groups?.compactMap(\.name) ?? []).map(DiscogsClient.withoutDisambiguator)
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
                return release.artist.map(DiscogsClient.withoutDisambiguator)
            }.filter { RecordingKey.normalizeArtist($0) != key }
        )
        record.fetchedAt = Date()
        record.cacheVersion = 7
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
        // Indigo's shared cache before the provider's own endpoint. On a hit
        // this release was described by somebody else's request and Discogs is
        // never asked at all — and a warm read out of Postgres is quicker than
        // asking it would have been.
        if let detail = await catalog.release(id: id) { return store(detail, id: id) }
        // A miss, so the page waits on Discogs directly rather than on the
        // backend's round trip to it. The shared copy is filled in behind us.
        let detail = try await client.release(id: id)
        catalog.populateInBackground(id: id)
        return store(detail, id: id)
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
        // Kept rather than discarded. It arrives in the same response, and
        // without it this row can only ever answer half the question — which
        // is how a record ended up with a sleeve in the grid and a blank
        // square on its own page.
        record.thumbnailURLString = detail.images?.first(where: { $0.type == "primary" })?.uri150
            ?? detail.images?.first?.uri150
            ?? record.thumbnailURLString
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

    /// "Boards Of Canada = ボーズ・オブ・カナダ* - Inferno" → "Inferno".
    ///
    /// Discogs writes the credit as it is printed on the sleeve, which can
    /// carry a translation, an alias, or a numeric disambiguator — "Speedkiller
    /// (2)". Matching the artist's name exactly misses every one of those and
    /// leaves the credit glued to the front of the title, which then reaches
    /// `releaseID(title:artist:)` as a `release_title` no catalogue can match,
    /// and the record opens as one nobody has an entry for.
    ///
    /// So the credit only has to *begin* with the artist, on a word boundary.
    static func releaseTitle(_ title: String, artist: String) -> String {
        guard let divider = title.range(of: " - ") else { return title }

        let credit = RecordingKey.normalize(String(title[..<divider.lowerBound]))
        let wanted = RecordingKey.normalize(artist)
        guard !wanted.isEmpty, credit == wanted || credit.hasPrefix(wanted + " ") else {
            return title
        }

        let remainder = String(title[divider.upperBound...])
        // Never leave nothing behind: a record actually called "X - " is worth
        // less than a record still called what the catalogue calls it.
        return remainder.trimmingCharacters(in: .whitespaces).isEmpty ? title : remainder
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
