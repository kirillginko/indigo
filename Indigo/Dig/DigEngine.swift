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
    /// The small version, shown coarsely while the full one is fetched.
    let thumbnailURL: URL?
    let genres: [String]
    let styles: [String]
    let aliases: [String]
    let discogsURL: URL?
    /// What this artist put out on Bandcamp, with the player each one
    /// advertises. Often the only record of music that is nowhere else.
    let bandcamp: [BandcampLine]
    let releases: [ReleaseLine]

    nonisolated struct BandcampLine: Identifiable, Hashable, Sendable {
        let title: String
        let year: String?
        let label: String?
        let pageURL: URL
        let imageURL: URL?
        /// The small cut, which arrives at once and stands in while the other
        /// loads.
        let thumbnailURL: URL?
        var id: String { pageURL.absoluteString }
    }
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

        // The two halves of a sleeve, and what to do when only one arrived.
        //
        // Sources fill these unevenly and always have: an artist's catalogue
        // listing carries a thumbnail and often no cover, a release fetched by
        // id carried a cover and — until now — no thumbnail at all. Views were
        // each picking a field, so the same record showed a sleeve in the grid
        // and a blank square on its own page, or the reverse. Neither half is
        // worth nothing, so neither is allowed to mean nothing.

        /// The biggest picture there is — or the small one, rather than a
        /// blank square.
        var coverURL: URL? { imageURL ?? thumbnailURL }

        /// The small cut to stand in while the cover loads — or the cover
        /// itself, when that is all there is.
        var previewURL: URL? { thumbnailURL ?? imageURL }
        /// Identity is the record, not what is currently known about it.
        ///
        /// This used to include the year and the Discogs id, both of which
        /// arrive partway through enrichment — so a row's identity changed
        /// under it, and the list treated the same record as one row vanishing
        /// and a different one appearing further down. Which is exactly what
        /// it looked like.
        ///
        /// It also used to drop bracketed asides, which the merge that builds
        /// these rows does not: "The Sunset Violent" and "The Sunset Violent
        /// (LP)" survive that merge as two records, and were then handed
        /// identical identities. Two rows claiming to be the same row is a
        /// crash in anything that files them by it, and it was — every time
        /// somebody opened an artist pressed on more than one format.
        /// Identity and the merge now ask the same question.
        var id: String { "release:\(Self.key(title))" }

        /// One record, however the title was punctuated. Shared with the
        /// merge in `DigEngine`, which is the point: what counts as the same
        /// record has to be one answer, not two.
        static func key(_ title: String) -> String {
            title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
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
            biography: nil, imageURL: nil, thumbnailURL: nil,
            genres: [], styles: [], aliases: [],
            discogsURL: nil, bandcamp: [], releases: [], labels: [], related: [],
            libraryTrackCount: 0, crateCount: 0, radioAppearances: [], listen: []
        )
    }

    /// The biggest picture of them there is, or the small one rather than an
    /// empty frame. See `ReleaseLine` for why neither half may mean nothing.
    var coverURL: URL? { imageURL ?? thumbnailURL }
    /// The small cut to stand in while the portrait loads, or the portrait.
    var previewURL: URL? { thumbnailURL ?? imageURL }

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
    /// The small cut, which is often the only half a record has when it is
    /// first opened — see `ArtistProfile.ReleaseLine`.
    let thumbnailURL: URL?
    let tracks: [TrackLine]
    let notes: String?
    let sourceURL: URL?
    /// Recordings catalogued alongside this release, playable in the app's own
    /// transport through YouTube's official player.
    let listen: [ListenLine]
    let related: [RelatedArtist]

    /// The biggest picture there is, or the small one rather than nothing.
    var coverURL: URL? { imageURL ?? thumbnailURL }
    /// The small cut to stand in while the cover loads, or the cover itself.
    var previewURL: URL? { thumbnailURL ?? imageURL }

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

    /// One graph store for the life of this engine.
    ///
    /// Building its caches reads six tables whole, which is most of the cost
    /// of a profile. An engine that is kept alive across calls — see
    /// `DigWorker` — therefore pays that once rather than per question.
    private let shared = GraphBox()

    private final class GraphBox {
        var store: GraphStore?
    }

    private var graph: GraphStore {
        if let existing = shared.store { return existing }
        let fresh = GraphStore(context: context)
        shared.store = fresh
        return fresh
    }

    /// Shares one walked graph with whoever else answers for this page.
    ///
    /// Assembling a `GraphStore`'s caches reads several whole tables. Each
    /// engine built its own, so a page that asks for a profile and a descent
    /// paid for the same tables twice.
    init(context: ModelContext, graph: GraphStore? = nil) {
        self.context = context
        shared.store = graph
    }

    // MARK: - Artist

    func artistProfile(name: String, mbid: String?) -> ArtistProfile {
        // Everything below reads the graph's fold — the recordings credited
        // to this artist, their catalogue entries, the library and crate
        // counts, the neighbourhood. Assembled once here rather than by
        // whichever question reaches it first.
        graph.prepare()
        // Falls back to the name when there is no MusicBrainz ID: an artist
        // reached from the library alone never has one, and that is exactly
        // the case the page must still fill in.
        let enricher = MusicBrainzEnricher(context: context)
        let cached = mbid.flatMap { enricher.cachedArtist($0) } ?? enricher.cachedArtistNamed(name)
        let cachedDiscogs = DiscogsEnricher(context: context, client: DiscogsClient()).cachedArtist(named: name)
        let discogs = cachedDiscogs?.isFresh == true ? cachedDiscogs : nil
        let byArtist = recordings(byArtist: name)
        let entries = byArtist.compactMap { metadata(for: $0.id) }

        // Bandcamp is a first-class source here, not a postscript. A great
        // deal of this music is on it and in no catalogue at all, so its tags
        // and its imprints belong beside the ones Discogs knows.
        let bandcampReleases = BandcampEnricher(context: context).cachedReleases(forArtist: name)
        let places = PlaceIndex(context: context)
        let bandcampTags = bandcampReleases
            .flatMap { places.split(keywords: $0.keywords).tags }
        let bandcampLabels = bandcampReleases.compactMap(\.labelName)
        let bandcampByTitle = Dictionary(
            bandcampReleases.map { (Self.releaseKey($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Labels come from what this artist's music actually came out on.
        var labelNames: [String: String?] = [:]
        for entry in entries {
            guard let labelName = entry.labelName else { continue }
            labelNames[labelName] = entry.labelMBID
        }
        for label in (discogs?.labelNames ?? []) + bandcampLabels where labelNames[label] == nil {
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
        // The picture the row was already showing.
        //
        // A connection row draws from `ArtistPortrait`, filled in by the
        // background fill; the page drew only from the artist's own catalogue
        // entry. So a row could show somebody's face and their page open
        // blank beside it — the same artist, two different places to look.
        let storedPortrait: URL? = {
            var descriptor = FetchDescriptor<ArtistPortrait>(
                predicate: #Predicate { $0.nameKey == artistKey }
            )
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first?.imageURL
        }()
        let resolvedReleases = graph.releases(creditedTo: artistKey)
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
            // The artist's own Bandcamp often has a sleeve for a record
            // Discogs pictures with nothing. It is already cached, so this
            // costs no request at all — which is the fastest an image gets.
            let fromBandcamp = bandcampByTitle[Self.releaseKey(title)]
            return ArtistProfile.ReleaseLine(
                title: title,
                // `.nonEmpty`, because the listing stores a blank string
                // rather than nothing — and a blank is not a year. Left as-is
                // it wins the merge against a real one.
                year: index < (discogs?.releaseYears.count ?? 0)
                    ? discogs?.releaseYears[index].nonEmpty : nil,
                discogsID: identifier,
                imageURL: (index < (discogs?.releaseImageURLStrings.count ?? 0)
                    ? discogs?.releaseImageURLStrings[index].nonEmptyURL : nil)
                    ?? resolved?.imageURL
                    ?? BandcampImage.sized(fromBandcamp?.imageURL, BandcampImage.cover),
                // The same ladder the cover half climbs. It used to stop at
                // the listing, so a record whose only picture came from the
                // release cache had a cover and no thumbnail — and every
                // surface that asked for the small one got nothing.
                thumbnailURL: (index < (discogs?.releaseThumbnailURLStrings.count ?? 0)
                    ? discogs?.releaseThumbnailURLStrings[index].nonEmptyURL : nil)
                    ?? resolved?.thumbnailURL
                    ?? BandcampImage.sized(fromBandcamp?.imageURL, BandcampImage.thumbnail),
                label: (index < (discogs?.releaseLabels.count ?? 0)
                    ? discogs?.releaseLabels[index].nonEmpty : nil) ?? resolved?.labelNames.first
            )
        }
        let mbReleases = (cached?.releases ?? []).map {
            let resolved = resolvedByTitle[Self.releaseKey($0.title)]
            // The same Bandcamp fallback the Discogs rows get. A record that
            // MusicBrainz lists and nobody pictures is exactly the one whose
            // sleeve is sitting in the Bandcamp cache already.
            let fromBandcamp = bandcampByTitle[Self.releaseKey($0.title)]
            return ArtistProfile.ReleaseLine(
                title: $0.title, year: $0.year, discogsID: resolved?.discogsID,
                imageURL: resolved?.imageURL
                    ?? BandcampImage.sized(fromBandcamp?.imageURL, BandcampImage.cover),
                thumbnailURL: resolved?.thumbnailURL
                    ?? BandcampImage.sized(fromBandcamp?.imageURL, BandcampImage.thumbnail),
                label: resolved?.labelNames.first ?? fromBandcamp?.labelName
            )
        }
        // Records Indigo has already resolved for this artist, whether or not
        // their catalogue listing mentions them.
        //
        // A Discogs artist entry can name no releases at all while the app
        // holds a dozen of their records — pulled in one at a time by crated
        // tracks and cover lookups. Building the discography only from the
        // listing threw all of those away, so a page could show twenty-five
        // things to listen to and no records to show for them.
        let resolvedLines = resolvedReleases.map { record in
            ArtistProfile.ReleaseLine(
                title: record.title,
                year: record.year.map(String.init),
                discogsID: record.discogsID,
                imageURL: record.imageURL,
                thumbnailURL: record.thumbnailURL,
                label: record.labelNames.first { LabelName.isRealLabel($0) }
            )
        }

        // Records only the artist published, folded into the same list.
        //
        // A discography is a discography. Keeping Bandcamp apart implied its
        // records were a lesser kind of thing, when for a lot of this music it
        // is the only place the work exists at all — so they take their place
        // in the run by title, and only the ones no catalogue already covers
        // are added.
        let bandcampOnly = bandcampReleases.map { release in
            ArtistProfile.ReleaseLine(
                title: release.title,
                year: release.year,
                discogsID: nil,
                imageURL: BandcampImage.sized(release.imageURL, BandcampImage.cover),
                thumbnailURL: BandcampImage.sized(release.imageURL, BandcampImage.thumbnail),
                label: release.labelName
            )
        }

        // Discogs rows are navigable and carry sleeves, so they always win a
        // title collision with MusicBrainz's text-only catalogue entry; both
        // outrank a Bandcamp row for the same record, which is last only
        // because the others can be dug into further.
        // Merged, not first-past-the-post.
        //
        // The same record arrives from the artist listing, the resolved
        // release cache, MusicBrainz and Bandcamp, and each knows different
        // things about it — the listing often has the title and nothing else
        // while the resolved record has the sleeve. Keeping whichever arrived
        // first threw the picture away, which is why a tile could be blank
        // here and full on the record's own page.
        var merged: [String: ArtistProfile.ReleaseLine] = [:]
        var order: [String] = []
        for line in discogsReleases + mbReleases + resolvedLines + bandcampOnly {
            let key = Self.releaseKey(line.title)
            guard let existing = merged[key] else {
                merged[key] = line
                order.append(key)
                continue
            }
            // Whichever half actually says something. A blank string is not
            // an answer, and letting one win means a record shows no year
            // because the first source to mention it left the field empty.
            merged[key] = ArtistProfile.ReleaseLine(
                title: existing.title,
                year: existing.year?.nonEmpty ?? line.year?.nonEmpty,
                discogsID: existing.discogsID ?? line.discogsID,
                imageURL: existing.imageURL ?? line.imageURL,
                thumbnailURL: existing.thumbnailURL ?? line.thumbnailURL,
                label: existing.label?.nonEmpty ?? line.label?.nonEmpty
            )
        }
        let releases = order.compactMap { merged[$0] }
            .sorted { lhs, rhs in
                let left = Int(lhs.year?.prefix(4) ?? "") ?? 0
                let right = Int(rhs.year?.prefix(4) ?? "") ?? 0
                if left != right { return left > right }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        return ArtistProfile(
            // Cleaned on the way out, not only on the way in. A row cached
            // before the fix still holds "Oliwa (2)", and that is the name at
            // the top of their own page — the one place a Discogs filing
            // number is most obviously not the artist's name.
            name: DiscogsClient.withoutDisambiguator(
                discogs?.name ?? cached?.name ?? name
            ),
            mbid: mbid ?? cached?.mbid,
            origin: cached?.origin,
            disambiguation: cached?.disambiguation,
            realName: discogs?.realName.map(DiscogsClient.withoutDisambiguator),
            biography: discogs?.biography.map(DiscogsEnricher.cleanProfile),
            imageURL: discogs?.imageURL ?? storedPortrait,
            thumbnailURL: discogs?.thumbnailURLString.flatMap(URL.init(string:))
                ?? storedPortrait,
            genres: Self.merged(discogs?.genres ?? cached?.genreTags ?? [], with: bandcampTags),
            styles: discogs?.styles ?? [],
            aliases: discogs?.aliasNames ?? [],
            discogsURL: discogs?.profileURL,
            bandcamp: bandcampReleases.map {
                ArtistProfile.BandcampLine(
                    title: $0.title, year: $0.year, label: $0.labelName,
                    pageURL: URL(string: $0.urlString) ?? URL(string: "https://bandcamp.com")!,
                    imageURL: BandcampImage.sized($0.imageURL, BandcampImage.cover),
                    thumbnailURL: BandcampImage.sized($0.imageURL, BandcampImage.thumbnail)
                )
            },
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
    ///
    /// Twice over, because a recording repeats itself two ways. The same
    /// video arrives under two shapes of its address, so identity is the
    /// video's id rather than the link; and the same recording is uploaded
    /// twice, once as "[Official Audio]" and once plain, which is one
    /// recording as far as somebody reading the list is concerned. Titles are
    /// compared after cleaning, which is what makes those two meet.
    private static func listenLines(from releases: [DiscogsReleaseRecord]) -> [DigReleaseProfile.ListenLine] {
        var seenRecordings = Set<String>()
        var seenTitles = Set<String>()
        return releases
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            .flatMap(\.videos)
            .compactMap { video in
                let identity = YouTubeLink.videoID(from: video.url) ?? video.url.absoluteString
                guard seenRecordings.insert(identity).inserted else { return nil }
                let title = YouTubeTitle.clean(video.title)
                // "Untitled" is not a name — it is the absence of one, and
                // white labels are full of them. It never stands in the way
                // of the next recording.
                let key = RecordingKey.normalize(title)
                guard key.isEmpty || key == "untitled" || seenTitles.insert(key).inserted
                else { return nil }
                return DigReleaseProfile.ListenLine(url: video.url, title: title, seconds: video.seconds)
            }
    }

    /// Tags from two sources, without repeating what either already said.
    private static func merged(_ first: [String], with second: [String]) -> [String] {
        var seen = Set<String>()
        return (first + second).filter {
            !$0.isEmpty && seen.insert(RecordingKey.normalize($0)).inserted
        }
    }

    private static func releaseKey(_ title: String) -> String {
        ArtistProfile.ReleaseLine.key(title)
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
        // The same ladder every other surface uses, so a record does not have
        // a sleeve in the grid and a blank square on its own page.
        let artwork = DigArtwork(context: context).release(
            title: record.title, artist: record.artistNames.first { ArtistName.isRealArtist($0) }
        )
        return DigReleaseProfile(
            id: id, title: record.title, year: record.year, artists: record.artistNames,
            labels: labels, genres: record.genres, styles: record.styles,
            imageURL: record.imageURL ?? artwork.full,
            thumbnailURL: record.thumbnailURL ?? artwork.thumbnail,
            tracks: tracks, notes: record.notes,
            sourceURL: record.profileURL,
            listen: Self.listenLines(from: [record]),
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
        graph.relatedArtists(to: .artist(name))
            .map { RelatedArtist(name: $0.node.title, mbid: $0.node.mbid,
                                 reasons: $0.edges.map(\.relationship),
                                 imageURL: $0.node.artworkURL) }
    }

    /// Everything next to something, of any kind — the step DEEP takes.
    func connections(from node: MusicNode) -> [MusicGraph.Connection] {
        var graph = MusicGraph()
        graph.absorb(self.graph.neighbors(of: node).all)
        return graph.connections(from: node)
    }

    private static func decade(_ year: String) -> Int? {
        guard let value = Int(year.prefix(4)), value > 0 else { return nil }
        return value / 10 * 10
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

    /// Everything credited to an artist.
    ///
    /// Read from the graph's fold rather than by fetching every recording and
    /// normalising its credit. This is asked several times while a page
    /// builds — and a page rebuilds itself on every write during a cold
    /// load — so a scan here was paid for many times over per artist.
    func recordings(byArtist name: String) -> [Recording] {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return [] }
        return graph.recordings(byArtistKey: key)
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

    /// How much of this artist the listener already owns.
    ///
    /// The same fold the graph walk uses. This used to fetch the whole track
    /// table and normalise two credits for every file in it — the exact scan
    /// that was taken out of the walk and left in the profile, where it ran
    /// just as often and grew with the size of somebody's music folder.
    func libraryTrackCount(artist name: String) -> Int {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return 0 }
        return graph.libraryTrackCount(forArtistKey: key)
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
        return graph.crateCount(forArtistKey: key)
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

    /// What a recording's catalogue entry says.
    ///
    /// Asked once per recording while a profile is built, and it used to be a
    /// fetch each time. The tables were already read into a dictionary by the
    /// graph; this reads that.
    func metadata(for recordingID: UUID) -> RecordingMetadata? {
        graph.metadata(for: recordingID)
    }
}

private nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var nonEmptyURL: URL? { nonEmpty.flatMap(URL.init(string:)) }
}
