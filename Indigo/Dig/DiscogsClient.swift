//
//  DiscogsClient.swift
//  Indigo
//
//  Fast catalogue enrichment for DIG. Credentials belong to Indigo's build
//  configuration (and ultimately its backend), never to the listener.
//

import Foundation

nonisolated enum DiscogsError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case rateLimited
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add a Discogs personal access token in Indigo Settings to enable fast DIG enrichment."
        case .offline: "Discogs is unavailable while offline."
        case .rateLimited: "Discogs is busy. Indigo will use its cached data."
        case .badStatus(let code): "Discogs returned an unexpected response (\(code))."
        case .malformedResponse: "Discogs sent something Indigo couldn't read."
        case .transport(let detail): detail
        }
    }
}

protocol DiscogsTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DiscogsTransport {}

nonisolated enum DiscogsConfiguration {
    /// A developer's own token from the environment, else the one packaged
    /// with this build.
    ///
    /// The packaged copy is scrambled rather than written out in the clear, so
    /// it survives neither `strings` nor a `plutil` dump. That is the whole of
    /// what it buys — see ObfuscatedSecret. A credential inside an application
    /// belongs to whoever holds the application, and this one also travels in
    /// an Authorization header where any proxy will show it. Keep it
    /// rotatable, and watch what it does.
    static var token: String? {
        if let value = ProcessInfo.processInfo.environment["DISCOGS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            // Unit tests opt into Discogs with an injected client. Never let a
            // developer's credential turn fixture tests into live calls.
            return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? value : nil
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }

        guard let bundled = Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String
        else { return nil }
        return ObfuscatedSecret.reveal(bundled)
    }
}

/// What looking an artist up by name found, and on what evidence.
nonisolated struct DiscogsArtistLookup: Sendable {
    let head: DiscogsSearchResult?
    /// Present when nobody was filed under the name and a spelling check ran.
    let spelling: DiscogsSpellingCheck?

    /// Whether the head is somebody filed under another name, found because
    /// their records were credited under this one.
    var isCreditedSpelling: Bool {
        if case .variation? = spelling?.verdict { return head != nil }
        return false
    }
}

/// A completed spelling check: the verdict, and the entries it read to reach it.
nonisolated struct DiscogsSpellingCheck: Sendable {
    let spelling: String
    let verdict: SpellingVerdict
    let resultCount: Int
    let results: [DiscogsSearchResult]
    let facts: [DiscogsIdentityFacts]
}

nonisolated struct DiscogsClient: Sendable {
    private let transport: DiscogsTransport
    private let suppliedToken: String?
    /// Indigo's backend, which holds the Discogs credential server-side. Nil
    /// for the test initialiser, which must stay on its injected transport.
    private let gateway: CatalogDiscogsGateway?
    /// How much of this minute is left. Shared by every client in the app,
    /// because the limit is shared: it is counted per credential, not per
    /// caller. See `DiscogsBudget`.
    private let budget: DiscogsBudget

    init() {
        transport = NetworkEnvironment.metadataSession
        suppliedToken = nil
        gateway = .shared
        budget = .shared
    }

    /// A client of its own, on its own budget. A refusal arranged by one test
    /// must not convince the next one that Discogs is busy.
    ///
    /// No gateway unless a test asks for one: the injected transport is the
    /// whole point of this initialiser, and a backend in front of it would be
    /// a second route out of the fixtures.
    init(
        transport: DiscogsTransport,
        token: String,
        budget: DiscogsBudget = DiscogsBudget(),
        gateway: CatalogDiscogsGateway? = nil
    ) {
        self.transport = transport
        suppliedToken = token
        self.gateway = gateway
        self.budget = budget
    }

    /// Whether Discogs will take another request of this kind right now.
    ///
    /// Asked before spending anything on work that can be postponed or
    /// declined. A refusal costs a round trip and comes back shaped like an
    /// answer, so the cheapest 429 is the one nobody sends.
    func hasRoom(for work: DiscogsBudget.Work) async -> Bool {
        await budget.hasRoom(for: work)
    }

    /// Whether a search can be attempted.
    ///
    /// Separate from `hasRoom` because a search does not necessarily spend
    /// this app's budget. Through the backend it travels on the server's
    /// credential and is usually answered from a cache, so the local reading
    /// has no bearing on it — and refusing a free request because the portrait
    /// fill drained a budget it was never going to touch is the same bug as
    /// before, wearing the fix as a disguise.
    func canSearch() async -> Bool {
        let route = Self.route(
            preferringBackend: true, hasToken: token != nil, hasBackend: gateway?.isEnabled == true)
        switch route {
        case .backend, .backendThenDirect: return true
        case .direct: return await budget.hasRoom(for: .foreground)
        case .unconfigured: return false
        }
    }

    /// Configured when either route to Discogs is open: Indigo's backend, or a
    /// token supplied directly for development.
    var isConfigured: Bool { gateway?.isEnabled == true || token != nil }

    /// The search that finds them, and nothing else.
    ///
    /// Split out because it already carries what a page needs to stop looking
    /// empty — their name as catalogued, and a picture of them. The rest of
    /// the bundle is a second round trip, and waiting for it before drawing
    /// anything meant the portrait arrived twice as late as it had to.
    func artistHead(named name: String) async throws -> DiscogsSearchResult? {
        try await artistLookup(named: name).head
    }

    /// The search that finds them, and the evidence for it when the name was a
    /// spelling rather than what they are filed under.
    ///
    /// Asked for "Prefuse73", Discogs' search returns Prefuse 73 first — and
    /// the match below, which compares filing names, rightly refuses it:
    /// "prefuse73" and "prefuse 73" are not the same string, and folding them
    /// together is how "Arp" would become A.R.P. So the page opened with
    /// nothing on it. What makes Prefuse 73 the answer is that his entry lists
    /// "Prefuse73" as a spelling his records were credited under, and that
    /// nobody is filed under it — which `spellingCheck` establishes, or fails
    /// to, from a search that returned every match it has.
    func artistLookup(named name: String) async throws -> DiscogsArtistLookup {
        let search: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        let candidates = Self.artistMatches(name: name, results: search.results ?? [])
        if candidates.count == 1 { return DiscogsArtistLookup(head: candidates[0], spelling: nil) }
        if candidates.count > 1 {
            let head = try await Self.whicheverMakesRecords(candidates, using: self) ?? candidates.first
            return DiscogsArtistLookup(head: head, spelling: nil)
        }
        guard let check = await spellingCheck(name) else { return DiscogsArtistLookup(head: nil, spelling: nil) }
        guard case .variation(let id) = check.verdict, let head = check.results.first(where: { $0.id == id }) else {
            return DiscogsArtistLookup(head: nil, spelling: check)
        }
        return DiscogsArtistLookup(head: head, spelling: check)
    }

    /// Whether exactly one Discogs entry answers to a spelling, or nil when
    /// that could not be established.
    ///
    /// Nil is the answer to every kind of not knowing: a search that failed,
    /// one with more matches than it returned, more candidates than are worth
    /// reading, or a candidate whose entry would not load. None of those is
    /// evidence that nobody else answers to the name, and the caller stores
    /// nothing for them. See `SpellingCheck.verdict`.
    func spellingCheck(_ spelling: String) async -> DiscogsSpellingCheck? {
        let response: DiscogsSearchResponse
        do {
            response = try await get("database/search", query: [
                URLQueryItem(name: "q", value: spelling),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "per_page", value: String(SpellingCheck.pageSize))
            ])
        } catch {
            return nil
        }
        let results = response.results ?? []
        guard let total = response.pagination?.items, total <= results.count else { return nil }
        guard let candidates = SpellingCheck.candidates(for: spelling, in: results) else { return nil }

        var facts: [Int: DiscogsIdentityFacts] = [:]
        for id in candidates {
            guard let detail = try? await artistDetail(id: id) else { return nil }
            facts[id] = DiscogsIdentityFacts(detail: detail)
        }
        guard let verdict = SpellingCheck.verdict(
            spelling: spelling, results: results, complete: true, details: facts
        ) else { return nil }
        return DiscogsSpellingCheck(
            spelling: spelling, verdict: verdict, resultCount: total,
            results: results, facts: facts.keys.sorted().compactMap { facts[$0] }
        )
    }

    /// Which of several people with one name is the one who makes the records.
    ///
    /// Discogs files everybody who shares a name under the same one with a
    /// number after it, and `withoutDisambiguator` — which exists so that
    /// "Nirvana (2)" can be found at all — folds them back together. So a tie
    /// was settled by whichever Discogs happened to rank first, and for Hype
    /// Williams that is the video director rather than Dean Blunt and Inga
    /// Copeland's duo: a page for the group listed his videography.
    ///
    /// The difference is what the two of them actually put out. Asking which
    /// of them has releases of their own is not enough and was not: a
    /// director is the main credit on his own videos, so both candidates
    /// answered yes. What separates them is the format — his releases are
    /// films and theirs are records — so the question is which candidate is
    /// the main credit on something that is not a video.
    ///
    /// Bounded to three: this runs in front of somebody opening a page,
    /// against a service that rate-limits, and a wrong-but-present answer
    /// beats a spinner.
    ///
    /// A probe that *fails* stops the walk rather than advancing it, and that
    /// distinction is the whole of this function's correctness. It used to be
    /// `try?` and `continue`, which cannot tell "this candidate makes no
    /// records" from "Discogs would not say" — so a refused probe read as a
    /// negative and promoted the next namesake.
    ///
    /// That is not a rare case, it is a biased one. The real artist is the one
    /// with thousands of records, so theirs is the slowest, heaviest probe and
    /// the first to time out or be throttled — while the impostor filed beside
    /// them has two releases and answers instantly. Searching The Beatles on a
    /// starved budget did exactly this: `artists/82730/releases` took eight
    /// seconds and threw, the walk moved on to "the Beatles (4)", and the page
    /// came back holding its single hoax cassette.
    ///
    /// So on a failure this answers nil, and `artistHead` falls back to
    /// Discogs' own ranking — where the real artist is almost always first.
    /// Guessing from rank is what this function exists to improve on; guessing
    /// from a question nobody answered is worse than not guessing at all.
    private static func whicheverMakesRecords(
        _ candidates: [DiscogsSearchResult], using client: DiscogsClient
    ) async throws -> DiscogsSearchResult? {
        for candidate in candidates.prefix(3) {
            guard let id = candidate.id else { continue }

            let releases: DiscogsArtistReleases
            do {
                releases = try await client.get(
                    "artists/\(id)/releases",
                    query: [URLQueryItem(name: "per_page", value: "25")]
                )
            } catch {
                return nil
            }

            // An empty shelf is an answer, and it is a negative one.
            guard let found = releases.releases else { continue }
            if found.contains(where: { ($0.role == nil || $0.role == "Main") && !$0.isVideo }) {
                return candidate
            }
        }
        return nil
    }

    func artist(named name: String) async throws -> DiscogsArtistBundle? {
        guard let match = try await artistHead(named: name) else { return nil }
        return try await artist(named: name, head: match)
    }

    /// Everything else, once they have been found.
    ///
    /// Built from the two halves below, so a caller that wants them one at a
    /// time can have them — see `DigStore.describeArtist(named:head:)` — and
    /// a caller that does not gets the same three requests it always did.
    func artist(named name: String, head match: DiscogsSearchResult) async throws -> DiscogsArtistBundle? {
        guard let id = match.id else { return nil }
        async let detail = artistDetail(id: id)
        async let shelf = artistShelf(named: name, id: id)
        let (described, found) = try await (detail, shelf)
        return DiscogsArtistBundle(
            detail: described,
            releases: found.releases,
            searchImageURL: match.coverImage,
            searchThumbnailURL: match.thumbnail,
            catalogue: found.catalogue
        )
    }

    /// Who an artist is, from their own entry: the profile, the real name,
    /// the portrait, the aliases.
    ///
    /// The quick half. 199ms at the median in the running app's trace, where
    /// the shelf below is 442ms and over a second in the slowest twentieth —
    /// so a page held for both was held for the shelf alone.
    func artistDetail(id: Int) async throws -> DiscogsArtistDetail {
        try await get("artists/\(id)")
    }

    /// What an artist has put out: the shelf Discogs files under them, and
    /// the search that carries its sleeves.
    func artistShelf(
        named name: String, id: Int
    ) async throws -> (releases: DiscogsArtistReleases, catalogue: [DiscogsSearchResult]) {
        async let releases: DiscogsArtistReleases = artistReleases(id: id)
        async let catalogue: [DiscogsSearchResult] = artistCatalogue(named: name)
        return try await (releases, catalogue)
    }

    /// The exact query the shared cache is keyed on.
    ///
    /// Held in one place because three things have to agree on it: this
    /// request, the row `cacheDiscogsShelf` writes, and the key
    /// `CatalogShelfSource` reads. A different `per_page` on any of them is a
    /// cached shelf nobody ever finds. See `MetadataRepository.cacheKey`.
    static let shelfQuery = [
        URLQueryItem(name: "per_page", value: "50"),
        URLQueryItem(name: "sort", value: "year"),
        URLQueryItem(name: "sort_order", value: "desc")
    ]

    static func shelfPath(id: Int) -> String { "artists/\(id)/releases" }

    /// What Discogs files under an artist.
    ///
    /// Separated from the search beside it because this one is cacheable and
    /// that one is not: a shelf is an artist's discography, keyed on their id,
    /// while the search is a match on the text of a credit. It is also the
    /// slowest request a cold page makes — 2,727ms for Ryuichi Sakamoto — which
    /// is what makes serving it out of Postgres worth the split.
    func artistReleases(id: Int) async throws -> DiscogsArtistReleases {
        try await get(Self.shelfPath(id: id), query: Self.shelfQuery)
    }

    /// How many releases Discogs files under an entry, in one small request.
    /// Nil when the answer did not say — which is not zero.
    func artistReleaseCount(id: Int) async throws -> Int? {
        let shelf: DiscogsArtistReleases = try await get(
            Self.shelfPath(id: id), query: [URLQueryItem(name: "per_page", value: "1")])
        return shelf.pagination?.items
    }

    /// The sleeves the shelf does not carry.
    func artistCatalogue(named name: String) async throws -> [DiscogsSearchResult] {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "25")
        ])
        return response.results ?? []
    }

    /// What a name-only portrait search may conclude.
    nonisolated enum PortraitPick: Sendable, Equatable {
        /// Exactly one Discogs artist has the name. A picture, never an
        /// identity: nothing here says the row is that artist.
        case unique(address: String, discogsID: Int)
        /// Several namesakes and nothing to choose between them by. No face
        /// rather than a stranger's.
        case ambiguous([Int])
        case none
    }

    /// A picture of an artist by name, in one request -- only when the name
    /// is not shared.
    ///
    /// The full `artist(named:)` bundle is four requests and fetches a
    /// discography nobody asked for; this is a quarter of the cost, which is
    /// what makes filling in a page of forty neighbours possible at all. It
    /// used to take the first result whose name matched, which is how the duo
    /// Hype Williams came to wear the film director's face: Discogs ranks
    /// namesakes in no particular order. Now a name two Discogs artists share
    /// is `ambiguous`, and the caller shows none.
    func artistPortrait(named name: String) async throws -> PortraitPick {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "type", value: "artist"),
            // Enough to see a name's namesakes, not only its first answer.
            URLQueryItem(name: "per_page", value: "25")
        ])
        return Self.portraitPick(name: name, results: response.results ?? [])
    }

    /// The decision behind `artistPortrait(named:)`, for tests.
    nonisolated static func portraitPick(name: String, results: [DiscogsSearchResult]) -> PortraitPick {
        let matches = artistMatches(name: name, results: results)
        let ids = Array(Set(matches.compactMap(\.id))).sorted()
        guard !ids.isEmpty else { return .none }
        guard ids.count == 1, let match = matches.first(where: { $0.id == ids[0] }) else { return .ambiguous(ids) }
        // The cover (600 pixels), not the thumb (150): the phone draws these
        // half a screen wide, where the thumb blurred. Its address is signed,
        // so a size cannot be asked of the thumb.
        guard let address = usableImage(match.coverImage) ?? usableImage(match.thumbnail) else { return .none }
        return .unique(address: address, discogsID: ids[0])
    }

    /// The Discogs artist a Discogs image shows, read from its address.
    ///
    /// Discogs serves images through a signed proxy whose path carries the
    /// original file's location, base64-encoded:
    /// `s3://discogs-database-images/A-398459-1256391322.jpeg` is a picture
    /// filed under artist 398459. Nil for anything else (a release cover, an
    /// address of another shape). How a cached portrait is checked against the
    /// artist it is about to be drawn for, with no field to store it in.
    nonisolated static func picturedArtist(in address: String?) -> Int? {
        guard let address, let range = address.range(of: #"/w:\d+/"#, options: .regularExpression) else { return nil }
        var encoded = address[range.upperBound...]
            .split(separator: "/").joined()
            .split(separator: ".").first.map(String.init) ?? ""
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8),
              let match = path.range(of: #"/A-(\d+)-"#, options: .regularExpression) else { return nil }
        return Int(path[match].dropFirst(3).dropLast())
    }

    /// What Discogs has under a typed query, in one of the three kinds a dig
    /// can start from.
    ///
    /// Asked one kind at a time rather than as a single untyped search.
    /// Discogs ranks an untyped `q` across everything it holds, and since it
    /// holds far more releases than artists or labels, a search for "ilian"
    /// comes back as twenty-five records and no imprint. Three narrow
    /// questions each return their own best answers, and the page decides how
    /// many of each to show.
    ///
    /// Whatever the kind, `title` is what the catalogue calls the thing —
    /// except for a release, where Discogs writes it as "Artist - Title".
    func search(
        _ query: String,
        kind: DiscogsSearchKind,
        limit: Int = 8
    ) async throws -> [DiscogsSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: DiscogsSearchResponse = try await get(
            "database/search",
            query: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: kind.rawValue),
                URLQueryItem(name: "per_page", value: String(max(1, min(limit, 50))))
            ],
            // A refusal here is not worth waiting out. The ladder below costs
            // three seconds and two more requests against a budget that has
            // just been proved empty, to answer a query the listener has very
            // likely finished typing over. Saying "Discogs is busy" at once is
            // both quicker and true; see `DigSearchResults.discogsRefused`.
            retryWhenRefused: false,
            // The one caller that would rather be cached than quick. See
            // `route(preferringBackend:hasToken:hasBackend:)`.
            preferringBackend: true
        )
        return response.results ?? []
    }

    func release(id: Int) async throws -> DiscogsReleaseDetail {
        try await get("releases/\(id)")
    }

    func releaseID(title: String, artist: String) async throws -> Int? {
        let byTitle: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "release_title", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "5")
        ])

        if let id = Self.bestReleaseMatch(title: title, in: byTitle) { return id }

        // `release_title` is matched against the title alone, so a stored title
        // that still carries its credit — "Boards Of Canada = ボーズ・オブ・
        // カナダ* - Inferno" — matches nothing at all, and the record reads as
        // one no catalogue has heard of. A plain search does find it, because
        // it looks at the whole credit line.
        //
        // Only worth the second request when the first came back empty, which
        // for a well-formed title it does not.
        guard title.contains(" - ") else { return nil }

        let byQuery: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        return Self.bestReleaseMatch(title: title, in: byQuery)
    }

    /// The result whose own title matches, else the catalogue's first answer.
    private static func bestReleaseMatch(title: String, in response: DiscogsSearchResponse) -> Int? {
        guard let results = response.results, !results.isEmpty else { return nil }
        let wanted = normalized(title.split(separator: " - ", maxSplits: 1).last.map(String.init) ?? title)
        return results.first {
            let resultTitle = $0.title.split(separator: " - ", maxSplits: 1).last.map(String.init) ?? $0.title
            return normalized(resultTitle) == wanted
        }?.id ?? results.first?.id
    }

    /// The release a *track* appears on.
    ///
    /// The route that actually matters for radio music. A tracklist gives you
    /// a song, and a song is almost never the name of a record — so searching
    /// for a release called "Rev8617" finds nothing, while asking which
    /// release contains a track called "Rev8617" returns Compro, which is the
    /// album the listener heard a piece of.
    ///
    /// Ordered results are left in Discogs' own relevance order and the
    /// earliest pressing wins ties, so a track resolves to the record it came
    /// out on rather than to a later compilation that also carries it.
    func releaseID(track: String, artist: String) async throws -> Int? {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "track", value: track),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        guard let results = response.results, !results.isEmpty else { return nil }
        let earliest = results
            .filter { ($0.year.flatMap(Int.init) ?? 0) > 0 }
            .min { ($0.year.flatMap(Int.init) ?? 0) < ($1.year.flatMap(Int.init) ?? 0) }
        return earliest?.id ?? results.first?.id
    }

    /// A label's catalogue, asked for by identity.
    ///
    /// `labelCatalogue(named:)` below searches on the label's *name*, and
    /// Discogs numbers labels that share one exactly as it numbers artists.
    /// Dean Blunt's World Music and the World Music that issued *Boot
    /// Scootin' Two Steppin' Country Dances* in 1995 are the same string, so
    /// a page for the first opened the catalogue of the second. Where a
    /// record has told us which label it was, that is asked instead.
    func labelCatalogue(id: Int) async throws -> [DiscogsLabelRelease] {
        let response: DiscogsLabelReleases = try await get("labels/\(id)/releases", query: [
            URLQueryItem(name: "per_page", value: "50")
        ])
        return response.releases ?? []
    }

    func labelCatalogue(named name: String) async throws -> [DiscogsSearchResult] {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "label", value: name),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "50")
        ])
        return response.results ?? []
    }

    /// Two bounded searches expand the graph without issuing one request per
    /// recommendation. Results are cached on the artist by DiscogsEnricher.
    /// Who else is nearby, asked several ways.
    ///
    /// This used to ask about one label and one style — the first of each —
    /// which is why the same handful of names came back every time. An artist
    /// on three imprints working in four styles has a far wider neighbourhood
    /// than their first label's roster, and it is the overlap between those
    /// answers that makes a recommendation worth offering.
    ///
    /// Bounded deliberately: two of each, plus one that asks for a style
    /// within the years the artist was actually working, which is what makes
    /// an era mean something rather than "the same decade".
    func recommendations(
        labels: [String],
        styles: [String],
        years: ClosedRange<Int>? = nil
    ) async throws -> DiscogsRecommendationBundle {
        async let firstLabel = recommendationSearch(field: "label", value: labels.first)
        async let secondLabel = recommendationSearch(field: "label", value: labels.dropFirst().first)
        async let firstStyle = recommendationSearch(field: "style", value: styles.first)
        async let secondStyle = recommendationSearch(field: "style", value: styles.dropFirst().first)
        async let era = eraSearch(style: styles.first, years: years)

        let responses = try await [firstLabel, secondLabel, firstStyle, secondStyle, era]
        return DiscogsRecommendationBundle(
            labelArtists: Self.neighbours(from: (responses[0].results ?? []) + (responses[1].results ?? [])),
            styleArtists: Self.neighbours(
                from: (responses[2].results ?? []) + (responses[3].results ?? []) + (responses[4].results ?? [])
            )
        )
    }

    /// A style, narrowed to when the artist was actually working. Records made
    /// alongside theirs rather than merely in the same decade.
    private func eraSearch(style: String?, years: ClosedRange<Int>?) async throws -> DiscogsSearchResponse {
        guard let style, !style.isEmpty, let years else { return DiscogsSearchResponse(results: []) }
        return try await get("database/search", query: [
            URLQueryItem(name: "style", value: style),
            URLQueryItem(name: "year", value: String(years.lowerBound + (years.count / 2))),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "20")
        ])
    }

    private func recommendationSearch(field: String, value: String?) async throws -> DiscogsSearchResponse {
        guard let value, !value.isEmpty else { return DiscogsSearchResponse(results: []) }
        return try await get("database/search", query: [
            URLQueryItem(name: field, value: value),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "20")
        ])
    }

    /// Discogs writes a release result as "Artist - Title" and includes a
    /// thumbnail with it. Both halves are worth keeping: the name is the
    /// connection and the thumbnail is the only picture of these artists that
    /// can be had without a request each.
    static func neighbours(from results: [DiscogsSearchResult]) -> [DiscogsNeighbour] {
        var seen = Set<String>()
        var found: [DiscogsNeighbour] = []
        for result in results {
            guard let separator = result.title.range(of: " - ") else { continue }
            let credit = String(result.title[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // The cover: these are drawn as half-screen cards on the phone,
            // where the 150-pixel thumb blurred.
            let thumbnail = result.coverImage ?? result.thumbnail
            for artist in Self.creditedNames(credit) {
                // "Name*" is Discogs saying the record credited somebody under
                // a variant spelling: the entry is filed under another name,
                // and opening this one by name can land on a different
                // artist ("Drama Aka Treason*" is Drama Treason, 9087331; the
                // entry called "Drama aka Treason" is 10218922). No row
                // rather than a stranger's page.
                if credit.contains(artist + "*") { continue }
                let key = RecordingKey.normalizeArtist(artist)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                found.append(DiscogsNeighbour(name: artist, thumbnailURL: thumbnail))
            }
        }
        return found
    }

    /// The artists named in a release credit, rather than the credit itself.
    ///
    /// A row read straight off a release title said "Hayden James, Bob Moses
    /// (5)" or "Flight Facilities With Emma Louise", and nothing is filed
    /// under either — so the row showed a sleeve and then opened onto an
    /// empty page.
    ///
    /// Split only where the credit says it is a collaboration. A comma alone
    /// does not: "Earth, Wind & Fire" is one act, and cutting it into three
    /// would replace one row that works with three that do not. So commas are
    /// only honoured when the credit carries a marker that Discogs itself put
    /// there — a "Feat.", a "With", a slash, or a disambiguating number.
    static func creditedNames(_ credit: String) -> [String] {
        // Almost every name is just a name.
        //
        // This runs once per edge, and a page has tens of thousands of them.
        // Reaching for two regular expressions and a dozen string splits to
        // decide that "Space Afrika" is "Space Afrika" doubled the cost of
        // walking the graph. A scan for the handful of characters that could
        // possibly matter settles the common case first.
        let punctuation: Set<Character> = ["(", "*", ",", "/", "&"]
        if !credit.contains(where: { punctuation.contains($0) }),
           credit.range(of: " feat", options: .caseInsensitive) == nil,
           credit.range(of: " ft", options: .caseInsensitive) == nil,
           credit.range(of: " with ", options: .caseInsensitive) == nil {
            return [credit]
        }

        let strong = [" / ", " Feat. ", " feat. ", " Feat ", " feat ",
                      " Featuring ", " featuring ", " Ft. ", " ft. ", " With ", " with "]
        // An asterisk is Discogs saying "credited under a variant name", and
        // it only ever appears on one member of a joint credit — so it marks
        // the credit as joint just as surely as a number does.
        let marked = strong.contains { credit.contains($0) }
            || credit.contains("*")
            || credit.range(of: #"\(\d+\)"#, options: .regularExpression) != nil

        var parts = [credit]
        for separator in strong {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        if marked {
            // "&" is left alone unless the credit is marked, because it is
            // part of a great many single acts — Earth, Wind & Fire among
            // them — and splitting those invents artists nobody has heard of.
            for separator in [", ", " & ", " And ", " and "] {
                parts = parts.flatMap { $0.components(separatedBy: separator) }
            }
        }
        var seen = Set<String>()
        return parts
            .map { Self.withoutDisambiguator($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && seen.insert(RecordingKey.normalizeArtist($0)).inserted }
    }

    static func artistNames(from results: [DiscogsSearchResult]) -> [String] {
        neighbours(from: results).map(\.name)
    }

    /// The artist that was asked for, or nobody.
    ///
    /// This used to fall back to the first result, which is how searching for
    /// somebody Discogs has never heard of opened a complete page — portrait,
    /// biography, aliases, discography — belonging to a stranger who happened
    /// to rank first for the name. It was also slow in exactly the case it
    /// was wrong: a miss cost four requests and a dozen sleeve fetches for a
    /// catalogue nobody had asked for, where saying so costs one and stops.
    ///
    /// Discogs' own disambiguator is stripped before comparing, so the artist
    /// really called Bandulu still matches the row filed as "Bandulu (3)".
    /// `normalizeArtist` does not do this itself — it folds punctuation to
    /// spaces, which turns that row into "bandulu 3" and would match nobody.
    static func bestArtistMatch(name: String, results: [DiscogsSearchResult]) -> DiscogsSearchResult? {
        artistMatches(name: name, results: results).first
    }

    /// Everybody Discogs files under this name, in the order it ranked them.
    ///
    /// More than one is the ordinary case rather than an oddity — Discogs
    /// numbers namesakes precisely because they are common — and which of
    /// them is meant cannot be read off a search result. See
    /// `whicheverMakesRecords(_:using:)`.
    static func artistMatches(name: String, results: [DiscogsSearchResult]) -> [DiscogsSearchResult] {
        let wanted = RecordingKey.normalizeArtist(name)
        guard !wanted.isEmpty else { return [] }
        return results.filter {
            RecordingKey.normalizeArtist(Self.withoutDisambiguator($0.title)) == wanted
        }
    }

    /// "Nirvana (2)" → "Nirvana", "Flowdan*" → "Flowdan".
    ///
    /// Both marks belong to Discogs' filing rather than to the artist: the
    /// number distinguishes two people who share a name, and the asterisk
    /// says a record credited them under a variant spelling. Carried into the
    /// app they become names nothing is filed under — so every "Bing (14)"
    /// and "VA*" offered as a connection was a row that opened onto nothing,
    /// which is worse than not offering it.
    static func withoutDisambiguator(_ title: String) -> String {
        // Anywhere, not only at the end. "Sima Kim* & Saito Koji" carries its
        // asterisk in the middle, and stripping only a trailing one left the
        // mark sitting inside the name.
        var value = title.replacingOccurrences(
            of: #"\s*\(\d+\)"#, with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(of: "*", with: "")
        return value
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A Discogs image address, or nil where Discogs is saying there is none.
    ///
    /// Search results carry `st.discogs.com/.../images/spacer.gif` for a
    /// record with no sleeve in the index — a real URL that loads a
    /// transparent one-pixel image. Stored and drawn, that is a tile showing
    /// nothing where the placeholder artwork should be, on a record whose own
    /// page fetches a perfectly good cover a moment later.
    /// Whether an address is Discogs' 150-pixel thumb, too small for a card.
    nonisolated static func isSmallCut(_ address: String?) -> Bool {
        address?.contains("/h:150/") == true || address?.contains("/w:150/") == true
    }

    static func usableImage(_ address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        return address.contains("/images/spacer") ? nil : address
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var token: String? {
        let value = suppliedToken ?? DiscogsConfiguration.token
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The backend where it is worth the hop, direct where it is not.
    ///
    /// The listener's search field prefers the backend even where this build
    /// carries a credential. A search there is answered from a cache anybody's
    /// earlier search filled and costs Discogs nothing, and it is the only
    /// route that files what it finds into `artists` and `labels` — so a query
    /// that costs a request today is free for everybody tomorrow. That is
    /// worth the extra half second, because results stream in and the local
    /// ones are already on screen.
    ///
    /// **Everything else goes direct, and the difference is the caller rather
    /// than the path.** This was keyed on `database/search` at first, which
    /// swept up far more than the search field: `artistHead`,
    /// `artistThumbnail`, `recommendations` and both `releaseID` lookups all
    /// use that path too. Nine of them run when an artist page opens, and each
    /// went from about two hundred milliseconds to about six hundred — a page
    /// somebody is watching, made a second slower to cache work nobody was
    /// waiting on. Whether a request wants the shared cached copy is a
    /// property of what it is for, not of the URL it happens to use.
    ///
    /// Release lookups by id have always gone through the backend and still
    /// do: read far more often than written, they normalize into the graph,
    /// and Postgres genuinely beats Discogs for them. See CatalogReleaseSource.
    /// Where a request goes, and what happens if that fails.
    ///
    /// Stated as a value rather than as a ladder of `if`s because it is the
    /// whole of the decision and every branch of it matters — one of them is
    /// the difference between a search costing Discogs a request and costing
    /// it nothing. Pure, so it can be checked without a network.
    enum Route: Sendable, Hashable {
        /// The backend, and Discogs if the backend cannot answer.
        case backendThenDirect
        /// The backend, whose failure is the answer: there is no credential
        /// here to fall back to.
        case backend
        case direct
        case unconfigured
    }

    /// - Parameter preferringBackend: whether this caller would rather be slow
    ///   and cached than quick and direct. True for the listener's search
    ///   field and nothing else.
    static func route(preferringBackend: Bool, hasToken: Bool, hasBackend: Bool) -> Route {
        if preferringBackend, hasBackend {
            return hasToken ? .backendThenDirect : .backend
        }
        if hasToken { return .direct }
        return hasBackend ? .backend : .unconfigured
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        retryWhenRefused: Bool = true,
        preferringBackend: Bool = false
    ) async throws -> T {
        func viaBackend() async throws -> T {
            guard let gateway else { throw DiscogsError.notConfigured }
            return try await Trace.stage("discogs.backend", path) {
                try await gateway.get(T.self, path: path, query: query)
            }
        }

        switch Self.route(
            preferringBackend: preferringBackend,
            hasToken: token != nil,
            hasBackend: gateway?.isEnabled == true
        ) {
        case .backendThenDirect:
            do {
                return try await viaBackend()
            } catch {
                // For a search the backend is the better route, not the only
                // one. A backend having a bad minute must not be why a
                // listener is told there is no such artist.
                return try await direct(path, query: query, retryWhenRefused: retryWhenRefused)
            }
        case .backend:
            return try await viaBackend()
        case .direct:
            return try await direct(path, query: query, retryWhenRefused: retryWhenRefused)
        case .unconfigured:
            throw DiscogsError.notConfigured
        }
    }

    /// How many times a refusal to serve is worth waiting out.
    ///
    /// Discogs allows sixty requests a minute and answers the sixty-first in
    /// a millisecond with a 429. Thirteen per cent of the requests in a real
    /// session's trace came back that way, and every one of them was thrown
    /// straight through to the page: a cold artist issues nine requests, waits
    /// for the ones that answer, and then shows nothing because one of them
    /// was refused. Being told to slow down is not the same as being told
    /// there is nothing there.
    ///
    /// Only the foreground path retries. The background portrait fill has its
    /// own answer to a 429 — stand down for thirty seconds — and that is the
    /// right one for work nobody is waiting on.
    private static let attemptsWhenRefused = 3

    private func direct<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        retryWhenRefused: Bool = true
    ) async throws -> T {
        let attempts = retryWhenRefused ? Self.attemptsWhenRefused : 1
        for attempt in 0..<attempts {
            do {
                return try await send(path, query: query)
            } catch DiscogsError.rateLimited {
                guard attempt < attempts - 1 else { break }
                // A second, then two. Longer than that and the page has been
                // blank so long that waiting is its own failure.
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw DiscogsError.rateLimited
    }

    private func send<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let token else { throw DiscogsError.notConfigured }
        var components = URLComponents(string: "https://api.discogs.com/\(path)")
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw DiscogsError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.discogs.v2.discogs+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        await budget.willIssue()
        do {
            (data, response) = try await Trace.stage("discogs.request", path) {
                try await transport.data(for: request)
            }
        } catch let error as URLError {
            if error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                throw DiscogsError.offline
            }
            throw DiscogsError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DiscogsError.malformedResponse }
        if http.statusCode == 429 {
            await budget.recordRefusal()
            throw DiscogsError.rateLimited
        }
        await budget.record(http)
        guard (200..<300).contains(http.statusCode) else { throw DiscogsError.badStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DiscogsError.malformedResponse
        }
    }
}
