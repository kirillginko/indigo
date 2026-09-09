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
        if !force, let cached = cachedArtist(named: name), cached.cacheVersion >= 12,
           cached.isFresh { return cached }
        guard let bundle = try await client.artist(named: name) else { return nil }
        return write(bundle, name: name)
    }

    /// The same, for a caller that has already done the search.
    @discardableResult
    func artist(named name: String, head: DiscogsSearchResult, force: Bool = false) async throws -> DiscogsArtist? {
        if !force, let cached = cachedArtist(named: name), cached.cacheVersion >= 12,
           cached.isFresh { return cached }
        guard let bundle = try await client.artist(named: name, head: head) else { return nil }
        return write(bundle, name: name)
    }

    private func write(_ bundle: DiscogsArtistBundle, name: String) -> DiscogsArtist? {
        Trace.step("enrich.artist", name) { writeArtist(bundle, name: name) }
    }

    /// Timed separately from the request that fetched it. A response arriving
    /// is not the same event as a response being written, and on the app's
    /// own context the second one happens on the thread that draws.
    private func writeArtist(_ bundle: DiscogsArtistBundle, name: String) -> DiscogsArtist? {

        let detail = bundle.detail
        // Records, not films. A videography is not a discography, and whoever
        // released the DVD is not one of this artist's labels — see
        // `DiscogsArtistRelease.isVideo`.
        let releases = (bundle.releases.releases ?? []).filter {
            ($0.role == nil || $0.role == "Main") && !$0.isVideo
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
        // The artist's own shelf, and only the artist's own shelf.
        //
        // This used to be `bundle.catalogue`, which is
        // `database/search?artist=<name>` — a match on the *text* of a credit.
        // For anyone filed alongside namesakes that returns their records too:
        // the cached discography for Anika held Precious Love by Anika (2),
        // Change by Anika (6) and an EP by Anika (20), none of which she made,
        // and held Change, Anika EP and Spaceman twice each because two
        // pressings are two hits. Both of those reached DEEP as rows, which is
        // how a page for one musician came to offer four other people's
        // records as things to discover.
        //
        // `artists/{id}/releases` cannot do that: it is the shelf Discogs
        // files under this artist. The search is kept for what it is actually
        // good for — it carries sleeves, and the releases endpoint does not.
        let sleeves = Dictionary(
            bundle.catalogue.compactMap { result in result.id.map { ($0, result) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Only labels a record itself names, or that this app has read off the
        // record in full. See `imprints(releasedBy:artist:catalogued:)`.
        let catalogued: (Int) -> [String] = { [self] in cachedRelease(id: $0)?.labelNames ?? [] }
        let discography = Array(
            Self.discography(uniqueReleases, artist: detail.name).prefix(30)
        )
        record.releaseTitles = discography.map(\.title)
        record.releaseYears = discography.map { $0.release.year.map(String.init) ?? "" }
        record.releaseDiscogsIDs = discography.map { $0.release.catalogueID ?? 0 }
        record.releaseImageURLStrings = discography.map {
            DiscogsClient.usableImage($0.release.catalogueID.flatMap { sleeves[$0]?.coverImage })
                ?? ""
        }
        // The record's own row first, the search second. See
        // `DiscogsArtistRelease.thumbnail`.
        record.releaseThumbnailURLStrings = discography.map {
            DiscogsClient.usableImage($0.release.thumbnail)
                ?? DiscogsClient.usableImage($0.release.catalogueID.flatMap { sleeves[$0]?.thumbnail })
                ?? ""
        }
        record.releaseLabels = discography.map {
            Self.label(of: $0.release, catalogued: catalogued) ?? ""
        }
        record.labelNames = Self.imprints(
            releasedBy: releases, artist: detail.name, catalogued: catalogued
        )
        // Only the label each release names for itself.
        //
        // The search catalogue also carries a `label` array, but it holds
        // every company credited on the record — the pressing plant, the
        // mastering house, the distributor, the magazine that ran the mix. As
        // an artist's imprints that reads as nonsense: Space Afrika listed on
        // GZ Media and Bonati Mastering alongside Dais and sferic.
        record.genres = Self.unique(bundle.catalogue.flatMap { $0.genre ?? [] })
        record.styles = Self.unique(bundle.catalogue.flatMap { $0.style ?? [] })
        record.collaboratorNames = Self.unique(
            (bundle.releases.releases ?? []).compactMap { release in
                guard release.role != nil, release.role != "Main" else { return nil }
                return release.artist.map(DiscogsClient.withoutDisambiguator)
            }.filter { RecordingKey.normalizeArtist($0) != key }
        )
        Self.repaintPortrait(of: record, in: context)
        record.fetchedAt = Date()
        record.cacheVersion = 12
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
        Trace.step("enrich.release", String(id)) { writeRelease(detail, id: id) }
    }

    private func writeRelease(_ detail: DiscogsReleaseDetail, id: Int) -> DiscogsReleaseRecord {
        let record = cachedRelease(id: id) ?? {
            let value = DiscogsReleaseRecord(discogsID: id, title: detail.title)
            context.insert(value)
            return value
        }()
        record.title = detail.title
        record.year = detail.year
        // Stripped, like every other Discogs name that becomes something you
        // can open. Discogs credits a record to "Hype Williams (2)" because
        // that is how it files the second person with the name, and carried
        // through it becomes an artist in its own right: a second page under
        // a name nothing is catalogued against, with no picture, no
        // discography and no way back to the artist it is a spelling of.
        record.artistNames = (detail.artists?.compactMap(\.name) ?? [])
            .map(DiscogsClient.withoutDisambiguator)
        // Named one per entry here rather than joined, but they carry the
        // same disambiguating numbers, and a label filed under "Aeon (5)" is
        // a label the pages cannot look up.
        record.labelNames = Self.unique(
            (detail.labels ?? []).flatMap { LabelName.names(inDiscogsField: $0.name) }
        )
        record.catalogNumbers = detail.labels?.compactMap(\.catno) ?? []

        // Everybody else on the record, minus the sleeve.
        //
        // Discogs credits the photographer and whoever did the layout in the
        // same list as the producer. Kept apart here rather than at the point
        // of drawing, so nothing downstream can accidentally offer a designer
        // as a musical connection — see `CreditRole`.
        var creditNames: [String] = []
        var creditRoles: [String] = []
        var creditTracks: [String] = []
        for credit in detail.extraartists ?? [] {
            guard CreditRole.isMusical(credit.role),
                  let name = credit.credited.map(DiscogsClient.withoutDisambiguator),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let role = CreditRole.display(credit.role)
            else { continue }
            creditNames.append(name)
            creditRoles.append(role)
            creditTracks.append(credit.tracks ?? "")
        }
        record.creditNames = creditNames
        record.creditRoles = creditRoles
        record.creditTracks = creditTracks
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

    /// The imprints this artist actually releases on, the ones they release
    /// on most first.
    ///
    /// This was the first twelve distinct labels in whatever order Discogs
    /// listed the records — which is newest first — so one appearance on a
    /// magazine's compilation last year outranked the label that has put out
    /// half their catalogue, and could push it off the end of the list
    /// entirely. A page for Anika named FACT Magazine among her labels for
    /// exactly that reason.
    ///
    /// Two changes make it an answer rather than an ordering accident.
    /// Compilations are left out: a record credited to Various is somebody
    /// else's release that this artist is on, and whoever put it out is not
    /// their label. And what remains is counted, because how many of an
    /// artist's records an imprint carries is the whole of what makes it
    /// theirs.
    static func imprints(
        releasedBy releases: [DiscogsArtistRelease],
        artist: String,
        catalogued: (Int) -> [String] = { _ in [] }
    ) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for release in releases where ArtistName.isRealArtist(release.artist ?? artist) {
            for name in Self.labels(of: release, catalogued: catalogued)
            where !LabelName.isOwnName(name, artist: artist) {
                let key = RecordingKey.normalize(name)
                guard !key.isEmpty else { continue }
                if counts[key] == nil { order.append(key); spelling[key] = name }
                counts[key, default: 0] += 1
            }
        }
        // Ties keep the order the catalogue gave them, which is newest first.
        return order
            .enumerated()
            .sorted {
                counts[$0.element, default: 0] == counts[$1.element, default: 0]
                    ? $0.offset < $1.offset
                    : counts[$0.element, default: 0] > counts[$1.element, default: 0]
            }
            .prefix(12)
            .compactMap { spelling[$0.element] }
    }

    /// Files the resolved artist's own picture as this name's portrait.
    ///
    /// Portraits are filled in bulk by `artistThumbnail(named:)`, which is one
    /// search and takes the first namesake it sees — cheap, and right until
    /// two people share a name. EXPLORE draws from that cache, so a For You
    /// page went on showing the video director's photograph beside a link
    /// that opened the duo's page: the artist row had been corrected and the
    /// portrait had not, and nothing ever asked it again because a portrait
    /// has no version to be out of date.
    ///
    /// Writing it here settles that. Once a page has been opened, the picture
    /// belongs to whoever the full lookup decided this artist is — which is
    /// the answer the cheap search was guessing at.
    private static func repaintPortrait(of record: DiscogsArtist, in context: ModelContext) {
        guard let address = DiscogsClient.usableImage(
            record.thumbnailURLString ?? record.imageURLString
        ) else { return }
        let key = record.nameKey
        guard !key.isEmpty else { return }
        var descriptor = FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        let portrait = (try? context.fetch(descriptor))?.first ?? {
            let fresh = ArtistPortrait(nameKey: key, name: record.name)
            context.insert(fresh)
            return fresh
        }()
        let wasShowing = portrait.imageURLString
        portrait.name = record.name
        portrait.imageURLString = address
        portrait.lookupFailed = false
        portrait.fetchedAt = Date()

        // And everywhere it was already copied to. See `StoredEdge.repaint`.
        guard wasShowing != address else { return }
        StoredEdge.repaint(artistKey: key, with: address, in: context)

        // EXPLORE writes its answer down, faces and all, so the copy on disk
        // is now a page of somebody who has been corrected. Thrown away
        // rather than patched: it costs a second to work out again, and it is
        // the one cache here that nothing else can put right.
        var offers = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        offers.fetchLimit = 1
        for record in (try? context.fetch(offers)) ?? [] { context.delete(record) }
    }

    /// Who put a record out, from whichever source names them.
    ///
    /// `artists/{id}/releases` carries a `label` only on its plain release
    /// rows; the master rows — which is what an artist's actual albums are
    /// filed as — have none. So reading only that field sampled an artist's
    /// labels through the one-off releases at the edge of their catalogue and
    /// missed imprints carried by masters.
    ///
    /// The gap is filled from records this app has already read in full,
    /// whose labels come from a release's own `labels` field. Deliberately
    /// **not** from the search, which was tried and is the trap the comment
    /// above `genres` describes: its `label` array holds every company
    /// credited on a record, so a page for Babyfather listed Key Production,
    /// Sony DADC and Southwater — a manufacturing broker, a disc plant and
    /// the town the plant is in — beside Hyperdub. A release's `labels` and
    /// its `companies` are different fields for a reason; the search flattens
    /// them together and cannot be un-flattened afterwards.
    ///
    /// Sparser than the search, and correct instead of full.
    static func labels(
        of release: DiscogsArtistRelease, catalogued: (Int) -> [String]
    ) -> [String] {
        let named = LabelName.names(inDiscogsField: release.label)
        guard named.isEmpty else { return named }
        guard let identifier = release.catalogueID else { return [] }
        return catalogued(identifier)
    }

    /// The one label to credit a record to, when a single line is shown.
    static func label(
        of release: DiscogsArtistRelease, catalogued: (Int) -> [String]
    ) -> String? {
        labels(of: release, catalogued: catalogued).first
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

    /// One entry per record this artist actually released, in the order the
    /// catalogue files them.
    ///
    /// Deduped on the folded title rather than the exact one, because Discogs
    /// files an album, its repress and its CD issue as separate rows, and a
    /// discography that lists Change three times reads as a bug — which is
    /// what it was.
    ///
    /// The title handed back is the cleaned one, and cleaning before the fold
    /// is what makes the fold work: some of these rows still carry the credit
    /// on the front, so "Anika - Change" and "Change" are one record and only
    /// collapse once both read as "Change". Stripping is safe here in a way it
    /// never was over a name search, because everything in this list is
    /// already known to be theirs.
    ///
    /// Everything kept has an id, because the arrays this feeds are parallel
    /// and read by index (see `DiscogsArtist.releaseLines`): an entry that
    /// could not be opened would shift every sleeve after it onto the wrong
    /// record.
    static func discography(
        _ releases: [DiscogsArtistRelease], artist: String
    ) -> [(release: DiscogsArtistRelease, title: String)] {
        var seen = Set<String>()
        return releases.compactMap { release in
            guard let raw = release.title, release.catalogueID != nil else { return nil }
            let title = releaseTitle(raw, artist: artist)
            let key = ArtistProfile.ReleaseLine.key(title)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return (release, title)
        }
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
