//
//  DigSearch.swift
//  Indigo
//
//  Looking something up rather than being offered it.
//
//  DIG's landing page is a list of places worth going, worked out from what
//  the listener already keeps. That is the right way in most evenings, and it
//  is useless the moment somebody arrives knowing what they want — a label
//  named on a sleeve, an artist heard on air, a record somebody mentioned. So
//  this asks three catalogues at once and puts what they hold in one list.
//
//  The three answer at very different speeds, which is why they stay separate
//  all the way to the page: what Indigo already holds locally is instant and
//  is drawn first, and the two networked ones fill in underneath as they
//  arrive. A search that waits for Discogs before showing an artist already
//  on this machine would be slower than the shelf it replaces.
//

import Foundation
import SwiftData

nonisolated enum DigSearchScope: String, CaseIterable, Hashable, Sendable {
    case all
    case artists
    case releases
    case labels

    var title: String {
        switch self {
        case .all: "All"
        case .artists: "Artists"
        case .releases: "Releases"
        case .labels: "Labels"
        }
    }

    /// Which kind of result this scope admits — everything, for `.all`.
    var kind: DigSearchResult.Kind? {
        switch self {
        case .all: nil
        case .artists: .artist
        case .releases: .release
        case .labels: .label
        }
    }
}

nonisolated struct DigSearchResult: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case artist
        case release
        case label

        var label: String {
            switch self {
            case .artist: "Artist"
            case .release: "Release"
            case .label: "Label"
            }
        }
    }

    /// Which catalogue this row came out of, in the order a listener cares
    /// about them: their own shelves, then the graph Indigo shares, then
    /// everything Discogs has ever filed.
    enum Origin: Int, Sendable, Hashable, Comparable {
        case yours
        case catalogue
        case discogs

        var label: String {
            switch self {
            case .yours: "Yours"
            case .catalogue: "Indigo"
            case .discogs: "Discogs"
            }
        }

        static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let origin: Origin
    let title: String
    let detail: String?
    let artworkURL: URL?
    let destination: DetailPage

    /// What two rows have to agree on to be the same thing. A record and an
    /// artist may share a name — *Pool* is both — so the kind is part of it.
    var matchKey: String { "\(kind.rawValue)|\(RecordingKey.normalize(title))" }

    var id: String { "\(origin.rawValue)|\(matchKey)|\(detail ?? "")" }
}

/// The three answers, kept apart until the page merges them.
nonisolated struct DigSearchResults: Sendable, Hashable {
    var yours: [DigSearchResult] = []
    var catalogue: [DigSearchResult] = []
    var discogs: [DigSearchResult] = []
    /// Discogs was asked and would not answer.
    ///
    /// Kept apart from "found nothing", which is what it used to be folded
    /// into. Discogs allows sixty requests a minute, the background portrait
    /// fill can spend most of them, and a search arriving into an empty budget
    /// is refused in a millisecond. Reported as an absence, that told somebody
    /// holding the record in their hand that no such artist exists.
    var discogsRefused = false

    static let none = DigSearchResults()

    var isEmpty: Bool { yours.isEmpty && catalogue.isEmpty && discogs.isEmpty }

    /// One list, best source first and nothing said twice.
    ///
    /// The listener's own copy wins every tie: a row that says "14 in library"
    /// is more use than the same name marked "Discogs", and showing both is
    /// showing the same artist twice.
    var merged: [DigSearchResult] {
        var seen = Set<String>()
        return (yours + catalogue + discogs).filter { seen.insert($0.matchKey).inserted }
    }

    func merged(scope: DigSearchScope) -> [DigSearchResult] {
        guard let kind = scope.kind else { return merged }
        return merged.filter { $0.kind == kind }
    }
}

// MARK: - What this machine already holds

/// Everything local worth searching, read once and then scanned.
///
/// Built from six tables, which is most of the store — the same read that
/// makes the DIG landing page take half a second. Doing that on every
/// keystroke would make typing feel like the page was thinking about
/// something else, so it is built once per generation and held by `DigWorker`
/// exactly the way the graph is; a keystroke is then a scan of an array.
nonisolated struct DigSearchIndex: Sendable {
    struct Entry: Sendable {
        let kind: DigSearchResult.Kind
        /// The name, normalized. What a query is compared against.
        let key: String
        let title: String
        let detail: String?
        let artworkURL: URL?
        let destination: DetailPage
        /// Whether that destination names the thing or merely describes it.
        ///
        /// A page opened by id is the record, the artist or the imprint; one
        /// opened by name is whatever the catalogue ranks first for that
        /// string, which for a label sharing its name with another is
        /// routinely the wrong one. See `DiscogsReleaseRecord.labelDiscogsIDs`.
        let opensByIdentity: Bool
        /// How much of it is theirs: crated, then in the library, then merely
        /// dug through before. Breaks ties between equally good name matches.
        let closeness: Int

        /// Two rows for one name, folded into the row that helps most.
        ///
        /// The closer copy wins what the row says — "crated" is a better line
        /// than "dug before" — but the destination is taken from whichever
        /// side can open the thing itself. A record in the library and the
        /// same record already read out of Discogs is one row that says it is
        /// in the library and opens onto a tracklist.
        func merged(with other: Entry) -> Entry {
            let closer = closeness <= other.closeness ? self : other
            let precise = opensByIdentity ? self : (other.opensByIdentity ? other : closer)
            return Entry(
                kind: closer.kind,
                key: closer.key,
                title: closer.title,
                detail: closer.detail,
                artworkURL: artworkURL ?? other.artworkURL,
                destination: precise.destination,
                opensByIdentity: precise.opensByIdentity,
                closeness: closer.closeness
            )
        }
    }

    static let crated = 0
    static let inLibrary = 1
    static let dug = 2

    private let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// Nothing shorter is a search. One letter matches most of a library and
    /// the answer is a list nobody scrolls.
    static let shortestQuery = 2

    static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= shortestQuery
    }

    /// Matches, best first.
    ///
    /// Three tiers, because where a query lands in a name is most of what
    /// makes a match good. "boards" should find Boards Of Canada before it
    /// finds Surfboards, and both before it finds anything with "boards" in
    /// the middle of a word.
    func search(_ query: String, limit: Int = 30) -> [DigSearchResult] {
        let key = RecordingKey.normalize(query)
        guard key.count >= Self.shortestQuery else { return [] }

        var scored: [(tier: Int, entry: Entry)] = []
        for entry in entries {
            guard let tier = Self.tier(of: entry.key, matching: key) else { continue }
            scored.append((tier, entry))
        }

        scored.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.entry.closeness != $1.entry.closeness {
                return $0.entry.closeness < $1.entry.closeness
            }
            // A shorter name containing the query matches more of it. "Pool"
            // before "Pool Party Vol. 3" for somebody who typed "pool".
            if $0.entry.key.count != $1.entry.key.count {
                return $0.entry.key.count < $1.entry.key.count
            }
            return $0.entry.title.localizedCaseInsensitiveCompare($1.entry.title)
                == .orderedAscending
        }

        var seen = Set<String>()
        var found: [DigSearchResult] = []
        for candidate in scored where found.count < limit {
            let result = DigSearchResult(
                kind: candidate.entry.kind,
                origin: .yours,
                title: candidate.entry.title,
                detail: candidate.entry.detail,
                artworkURL: candidate.entry.artworkURL,
                destination: candidate.entry.destination
            )
            guard seen.insert(result.matchKey).inserted else { continue }
            found.append(result)
        }
        return found
    }

    /// 0 the whole name, 1 a word in it, 2 anywhere at all, nil no match.
    static func tier(of key: String, matching query: String) -> Int? {
        guard !key.isEmpty else { return nil }
        if key == query { return 0 }
        if key.hasPrefix(query) { return 0 }
        if key.contains(" " + query) { return 1 }
        return key.contains(query) ? 2 : nil
    }
}

// MARK: - Building it

extension DigSearchIndex {
    /// Reads the store once. Called on `DigWorker`, never on the main actor.
    init(context: ModelContext) {
        var entries: [Entry] = []
        /// Keeps one entry per name per kind, preferring the closest copy —
        /// an artist in the crate and the same artist in a dug discography is
        /// one row that should say "crated".
        var best: [String: Int] = [:]

        func add(_ entry: Entry) {
            guard !entry.key.isEmpty else { return }
            let slot = "\(entry.kind.rawValue)|\(entry.key)"
            if let existing = best[slot] {
                entries[existing] = entries[existing].merged(with: entry)
                return
            }
            best[slot] = entries.count
            entries.append(entry)
        }

        Self.addLibrary(to: add, context: context)
        Self.addCrate(to: add, context: context)
        Self.addDugArtists(to: add, context: context)
        Self.addDugReleases(to: add, context: context)
        Self.addLabels(to: add, context: context)

        self.init(entries: entries)
    }

    /// The artists and the records on this machine. Counted the way the DIG
    /// landing page counts them, so the two pages agree about what the library
    /// holds.
    private static func addLibrary(to add: (Entry) -> Void, context: ModelContext) {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []

        var artistCounts: [String: Int] = [:]
        var artistNames: [String: String] = [:]
        var albums: [String: (title: String, artist: String, tracks: Int)] = [:]

        for track in tracks {
            for key in DigEngine.artistKeys(for: track) {
                artistCounts[key, default: 0] += 1
                if artistNames[key] == nil {
                    artistNames[key] = RecordingKey.normalizeArtist(track.artist) == key
                        ? track.artist : track.albumArtist
                }
            }
            guard !track.album.isEmpty else { continue }
            let albumKey = RecordingKey.normalize(track.album)
            guard !albumKey.isEmpty else { continue }
            let existing = albums[albumKey]
            albums[albumKey] = (
                track.album,
                existing?.artist ?? track.displayAlbumArtist,
                (existing?.tracks ?? 0) + 1
            )
        }

        for (key, count) in artistCounts {
            guard let name = artistNames[key], ArtistName.isRealArtist(name) else { continue }
            add(Entry(
                kind: .artist,
                key: key,
                title: name,
                detail: "\(count) in library",
                artworkURL: nil,
                destination: .digArtist(mbid: nil, name: name),
                opensByIdentity: false,
                closeness: inLibrary
            ))
        }

        for (key, album) in albums {
            add(Entry(
                kind: .release,
                key: key,
                title: album.title,
                detail: [album.artist.nilIfEmpty, "in library"].compactMap { $0 }
                    .joined(separator: " · "),
                artworkURL: nil,
                destination: .digReleaseNamed(title: album.title, artist: album.artist),
                opensByIdentity: false,
                closeness: inLibrary
            ))
        }
    }

    /// What the listener actually chose to keep. Closest of all, so a crated
    /// artist outranks the same name arriving from anywhere else.
    private static func addCrate(to add: (Entry) -> Void, context: ModelContext) {
        let engine = DigEngine(context: context)
        var counts: [String: (name: String, count: Int, mbid: String?)] = [:]

        for item in (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [] {
            let name = item.recording?.artistName
                ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let name, ArtistName.isRealArtist(name) else { continue }
            let key = RecordingKey.normalizeArtist(name)
            guard !key.isEmpty else { continue }
            let mbid = item.recording.flatMap { engine.metadata(for: $0.id)?.artistMBID }
                ?? (item.providerID == "dig.artist.mbid" ? item.showID : nil)
            let existing = counts[key]
            counts[key] = (existing?.name ?? name, (existing?.count ?? 0) + 1, existing?.mbid ?? mbid)
        }

        for (key, entry) in counts {
            add(Entry(
                kind: .artist,
                key: key,
                title: entry.name,
                detail: entry.count == 1 ? "crated" : "\(entry.count) crated",
                artworkURL: nil,
                destination: .digArtist(mbid: entry.mbid, name: entry.name),
                opensByIdentity: entry.mbid != nil,
                closeness: crated
            ))
        }
    }

    /// Artists whose page has already been built once — the ones with a
    /// portrait and a discography behind them, which is what makes their row
    /// worth showing over an identical name from a search.
    private static func addDugArtists(to add: (Entry) -> Void, context: ModelContext) {
        for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] {
            guard ArtistName.isRealArtist(artist.name) else { continue }
            let picture = artist.thumbnailURLString?.nilIfEmpty ?? artist.imageURLString?.nilIfEmpty
            add(Entry(
                kind: .artist,
                key: RecordingKey.normalizeArtist(artist.name),
                title: artist.name,
                detail: artist.labelNames.first.map { "on \($0)" } ?? "dug before",
                artworkURL: picture.flatMap(URL.init(string:)),
                destination: .digArtist(mbid: nil, name: artist.name),
                opensByIdentity: false,
                closeness: dug
            ))
        }

        for artist in (try? context.fetch(FetchDescriptor<Artist>())) ?? [] {
            guard ArtistName.isRealArtist(artist.name) else { continue }
            add(Entry(
                kind: .artist,
                key: RecordingKey.normalizeArtist(artist.name),
                title: artist.name,
                detail: artist.disambiguation?.nilIfEmpty ?? "dug before",
                artworkURL: nil,
                destination: .digArtist(mbid: artist.mbid, name: artist.name),
                opensByIdentity: true,
                closeness: dug
            ))
        }
    }

    /// Records already read out of Discogs. These open by id, which is the
    /// difference between a page and a guess.
    private static func addDugReleases(to add: (Entry) -> Void, context: ModelContext) {
        for release in (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] {
            guard !ReleaseFormat.isVideo(anyOf: release.formats) else { continue }
            let credit = release.artistNames.first
            let year = release.year.map(String.init)
            add(Entry(
                kind: .release,
                key: RecordingKey.normalize(release.title),
                title: release.title,
                detail: [credit, year].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
                    .nilIfEmpty,
                artworkURL: (release.thumbnailURLString?.nilIfEmpty
                    ?? release.imageURLString?.nilIfEmpty).flatMap(URL.init(string:)),
                destination: .digRelease(id: release.discogsID, title: release.title),
                opensByIdentity: true,
                closeness: dug
            ))
        }
    }

    /// Imprints, from both places one is known: the MusicBrainz rows DIG
    /// caches, and the labels named on records already read.
    ///
    /// The second is where the ids come from. A label reached by name alone
    /// can be the wrong label of that name — see `labelDiscogsIDs` — so a
    /// release that recorded which one it was is worth more than a match on
    /// the string.
    private static func addLabels(to add: (Entry) -> Void, context: ModelContext) {
        var counts: [String: (name: String, records: Int, discogsID: Int?)] = [:]

        for release in (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] {
            for (index, name) in release.labelNames.enumerated() {
                guard LabelName.isRealLabel(name) else { continue }
                let key = RecordingKey.normalize(name)
                guard !key.isEmpty else { continue }
                let id = index < release.labelDiscogsIDs.count
                    ? release.labelDiscogsIDs[index] : nil
                let existing = counts[key]
                counts[key] = (
                    existing?.name ?? name,
                    (existing?.records ?? 0) + 1,
                    existing?.discogsID ?? id
                )
            }
        }

        for (key, label) in counts {
            add(Entry(
                kind: .label,
                key: key,
                title: label.name,
                detail: label.records == 1 ? "1 record here" : "\(label.records) records here",
                artworkURL: nil,
                destination: .digDiscogsLabel(name: label.name, discogsID: label.discogsID),
                opensByIdentity: label.discogsID != nil,
                closeness: dug
            ))
        }

        for label in (try? context.fetch(FetchDescriptor<MusicLabel>())) ?? [] {
            guard LabelName.isRealLabel(label.name) else { continue }
            add(Entry(
                kind: .label,
                key: RecordingKey.normalize(label.name),
                title: label.name,
                detail: label.catalogueSize > 0 ? "\(label.catalogueSize) releases" : "dug before",
                artworkURL: nil,
                destination: .digLabel(mbid: label.mbid, name: label.name),
                opensByIdentity: true,
                closeness: dug
            ))
        }
    }
}

// MARK: - What the shared catalogue holds

extension DigSearchResult {
    /// Indigo's own graph, as rows. Ordered artists, then labels, then
    /// releases: somebody typing a name is far more often after a person or
    /// an imprint than a particular pressing, and `search_catalog` has already
    /// ranked within each kind.
    static func rows(from results: Catalog.SearchResults) -> [DigSearchResult] {
        results.artists.map {
            DigSearchResult(
                kind: .artist,
                origin: .catalogue,
                title: $0.name,
                detail: $0.country?.nilIfEmpty,
                artworkURL: nil,
                destination: .digArtist(mbid: nil, name: $0.name)
            )
        }
        + results.labels.map { label in
            DigSearchResult(
                kind: .label,
                origin: .catalogue,
                title: label.name,
                detail: label.country?.nilIfEmpty,
                artworkURL: nil,
                // The id where the catalogue has one: two labels can share a
                // name, and only the id says which of them this row is.
                destination: .digDiscogsLabel(
                    name: label.name, discogsID: label.discogsID.flatMap(Int.init)
                )
            )
        }
        + results.releases.map { release in
            let detail = [
                release.artistName?.nilIfEmpty,
                release.labelName?.nilIfEmpty,
                release.releaseYear.map(String.init),
                release.catalogNumber?.nilIfEmpty
            ].compactMap { $0 }.joined(separator: " · ")
            return DigSearchResult(
                kind: .release,
                origin: .catalogue,
                title: release.title,
                detail: detail.nilIfEmpty,
                artworkURL: nil,
                destination: release.discogsID.flatMap(Int.init).map {
                    DetailPage.digRelease(id: $0, title: release.title)
                } ?? .digReleaseNamed(
                    title: release.title, artist: release.artistName ?? ""
                )
            )
        }
    }
}

// MARK: - What Discogs holds

extension DigSearchResult {
    /// Discogs' answer for one kind, as rows.
    ///
    /// The disambiguator goes here rather than at the page: "Nirvana (2)" is
    /// Discogs' filing and nothing in Indigo is stored under it, so a row
    /// carrying it opens onto an empty page. See
    /// `DiscogsClient.withoutDisambiguator`.
    static func rows(
        fromDiscogs results: [DiscogsSearchResult],
        kind: DiscogsSearchKind
    ) -> [DigSearchResult] {
        results.compactMap { result in
            let artwork = (DiscogsClient.usableImage(result.thumbnail)
                ?? DiscogsClient.usableImage(result.coverImage))
                .flatMap(URL.init(string:))

            switch kind {
            case .artist:
                let name = DiscogsClient.withoutDisambiguator(result.title)
                guard ArtistName.isRealArtist(name), !name.isEmpty else { return nil }
                return DigSearchResult(
                    kind: .artist,
                    origin: .discogs,
                    title: name,
                    detail: nil,
                    artworkURL: artwork,
                    destination: .digArtist(mbid: nil, name: name)
                )

            case .label:
                let name = DiscogsClient.withoutDisambiguator(result.title)
                guard LabelName.isRealLabel(name), !name.isEmpty else { return nil }
                return DigSearchResult(
                    kind: .label,
                    origin: .discogs,
                    title: name,
                    detail: nil,
                    artworkURL: artwork,
                    destination: .digDiscogsLabel(name: name, discogsID: result.id)
                )

            case .release:
                let credit = Self.credit(inDiscogsTitle: result.title)
                guard !credit.title.isEmpty else { return nil }
                let detail = [
                    credit.artist,
                    result.year?.nilIfEmpty,
                    result.label?.first.map(DiscogsClient.withoutDisambiguator)
                ].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
                guard let id = result.id else { return nil }
                return DigSearchResult(
                    kind: .release,
                    origin: .discogs,
                    title: credit.title,
                    detail: detail.nilIfEmpty,
                    artworkURL: artwork,
                    destination: .digRelease(id: id, title: credit.title)
                )
            }
        }
    }

    /// Whether these rows are the answer, or only the start of one.
    ///
    /// Asked of the shared catalogue before Discogs is troubled at all. What
    /// counts is deliberately narrow: an artist or a label whose name *begins*
    /// with what was typed. Somebody entering a name is after a person or an
    /// imprint, both of those are filed by the backend now, and a name that
    /// starts with the query is the thing itself rather than a hint towards
    /// it.
    ///
    /// A release is not admitted however well its title matches, and neither
    /// is a name that merely contains the query somewhere. "warp" turns up a
    /// dozen records with it in the title and none of them is Warp Records —
    /// and treating those as an answer is how a search would come to
    /// confidently miss the one thing it was for.
    static func answers(_ rows: [DigSearchResult], query: String) -> Bool {
        let key = RecordingKey.normalize(query)
        guard !key.isEmpty else { return false }
        return rows.contains { row in
            guard row.kind == .artist || row.kind == .label else { return false }
            return DigSearchIndex.tier(of: RecordingKey.normalize(row.title), matching: key) == 0
        }
    }

    /// Discogs writes a release result as "Artist - Title". Kept apart so the
    /// row reads as a record with a credit rather than as one long string.
    static func credit(inDiscogsTitle title: String) -> (artist: String?, title: String) {
        guard let separator = title.range(of: " - ") else {
            return (nil, title.trimmingCharacters(in: .whitespaces))
        }
        let artist = DiscogsClient.withoutDisambiguator(String(title[..<separator.lowerBound]))
        let name = String(title[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (artist.nilIfEmpty, name)
    }
}
