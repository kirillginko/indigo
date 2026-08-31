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
    private(set) var discogsLabelProfiles: [String: DiscogsLabelProfile] = [:
    ]

    @ObservationIgnored let context: ModelContext
    /// Walks the graph off the main thread. See `DigWorker`.
    @ObservationIgnored private let worker: DigWorker

    /// The worker reads its own context, so it sees what has been *saved*.
    ///
    /// Everything that writes here saves as it goes, but a caller that has
    /// just inserted and not yet saved would otherwise get an answer computed
    /// without their change in it — a subtle, occasional wrongness that would
    /// be miserable to track down. Saving nothing costs nothing.
    private func settle() {
        guard context.hasChanges else { return }
        try? context.save()
    }
    @ObservationIgnored private let client: MusicBrainzClient
    @ObservationIgnored private let discogsClient: DiscogsClient
    /// Keys already looked up this session, so revisiting a page doesn't
    /// re-hit a rate-limited public service.
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var backgroundWarmupStarted = false
    @ObservationIgnored private var portraitFillStarted = false

    init(
        context: ModelContext,
        client: MusicBrainzClient = MusicBrainzClient(),
        discogsClient: DiscogsClient = DiscogsClient()
    ) {
        self.context = context
        worker = DigWorker(modelContainer: context.container)
        self.client = client
        self.discogsClient = discogsClient
    }

    /// Deallocating a MainActor-isolated observable hops to the executor to
    /// run its deinit, and that hop aborts the process. The app never sees it
    /// — this store lives as long as the window does — but anything that
    /// creates one and lets it go, which is every test that touches DIG,
    /// takes the whole host down with it. There is nothing here that needs
    /// the main actor to be torn down.
    nonisolated deinit {}

    private var engine: DigEngine { DigEngine(context: context) }
    private var enricher: MusicBrainzEnricher { MusicBrainzEnricher(context: context, client: client) }
    private var discogsEnricher: DiscogsEnricher { DiscogsEnricher(context: context, client: discogsClient) }

    // MARK: - Profiles

    @ObservationIgnored private var profiles = DigCache<ArtistProfile>()

    /// The current profile, worked out off the main thread.
    ///
    /// Only the answer comes back here; the reading and the walking happen on
    /// the worker's own context, so a page filling in does not stop a scroll.
    func artistProfile(name: String, mbid: String?) async -> ArtistProfile {
        let key = Self.artistKey(name: name, mbid: mbid)
        let asked = revision
        if let fresh = profiles.fresh(key, revision: asked) { return fresh }
        settle()
        let profile = await worker.artistProfile(name: name, mbid: mbid, generation: asked)
        profiles.store(profile, key: key, revision: asked)
        return profile
    }

    /// The last answer for this artist, however old.
    ///
    /// Returned without recomputing so a page can draw its previous contents
    /// the instant it comes back, rather than flashing a loading bar while it
    /// rebuilds something the listener was looking at seconds ago. The fresh
    /// version replaces it a moment later.
    func cachedArtistProfile(name: String, mbid: String?) -> ArtistProfile? {
        profiles.any(Self.artistKey(name: name, mbid: mbid))
    }

    private static func artistKey(name: String, mbid: String?) -> String {
        "\(mbid ?? "-")|\(RecordingKey.normalizeArtist(name))"
    }

    @ObservationIgnored private var labels = DigCache<LabelProfile>()
    @ObservationIgnored private var releases = DigCache<DigReleaseProfile>()

    func labelProfile(mbid: String, fallbackName: String) async -> LabelProfile? {
        let asked = revision
        if let fresh = labels.fresh(mbid, revision: asked) { return fresh }
        settle()
        guard let profile = await worker.labelProfile(mbid: mbid, fallbackName: fallbackName, generation: asked) else {
            return nil
        }
        labels.store(profile, key: mbid, revision: asked)
        return profile
    }

    func cachedLabelProfile(mbid: String) -> LabelProfile? { labels.any(mbid) }

    func releaseProfile(id: Int) async -> DigReleaseProfile? {
        let key = String(id)
        let asked = revision
        if let fresh = releases.fresh(key, revision: asked) { return fresh }
        settle()
        guard let profile = await worker.releaseProfile(id: id, generation: asked) else { return nil }
        releases.store(profile, key: key, revision: asked)
        return profile
    }

    func cachedReleaseProfile(id: Int) -> DigReleaseProfile? { releases.any(String(id)) }

    func discogsLabelProfile(named name: String) -> DiscogsLabelProfile? {
        discogsLabelProfiles[RecordingKey.normalizeArtist(name)]
    }

    /// Where "DIG →" on a recording should land. Prefers the MusicBrainz
    /// artist we already resolved so the page opens with a real graph.
    func destination(for recording: Recording) -> DetailPage? {
        // Read so the button reappears the moment a repaired credit gives the
        // recording an artist to open.
        let _ = revision

        guard let artist = recording.artistName, !artist.isEmpty else { return nil }
        let mbid = engine.metadata(for: recording.id)?.artistMBID
        return .digArtist(mbid: mbid, name: artist)
    }

    /// Where the recording *itself* opens.
    ///
    /// Kept apart from `destination(for:)`, which answers "dig into this
    /// artist" and is what the DIG button means. Music that was heard
    /// somewhere has a page of its own — where it was played, and what was
    /// played beside it, which is the part no catalogue holds. Falls back to
    /// the artist for anything never heard on air.
    func recordingDestination(for recording: Recording) -> DetailPage? {
        let _ = revision
        if !recording.appearances.isEmpty {
            return .digRecording(id: recording.id, title: recording.displayTitle)
        }
        return destination(for: recording)
    }

    /// Fetches the sleeves the artist's catalogue row didn't carry.
    ///
    /// Discogs' artist listing frequently omits cover images that the release
    /// itself has, which is why a tile could stay blank until somebody opened
    /// it and came back. Bounded and progressive: each release that answers
    /// bumps the revision, so the grid fills in one tile at a time rather than
    /// all at once at the end.
    func fillMissingReleaseArtwork(forArtist name: String, mbid: String?, limit: Int = 24) async {
        let missing = await artistProfile(name: name, mbid: mbid).releases
            .filter { $0.imageURL == nil && $0.thumbnailURL == nil }
        guard !missing.isEmpty else { return }

        // Fetched together, written one at a time.
        //
        // Each of these is a round trip, and done in sequence a dozen of them
        // is the difference between a page that fills in and a page you wait
        // for. The network half runs in parallel; the writes stay serial,
        // because they all land in one ModelContext.
        let client = discogsClient
        // Six at a time. The grid shows two dozen and all of them deserve a
        // sleeve, but firing four dozen requests in one breath is how a
        // service starts refusing them — and a batch that lands is a batch
        // the listener can see.
        for batch in Array(missing.prefix(limit)).chunked(into: 6) {
            guard !Task.isCancelled else { return }
            await fetchAndStore(batch, artist: name, client: client)
        }
    }

    private func fetchAndStore(
        _ wanted: [ArtistProfile.ReleaseLine],
        artist name: String,
        client: DiscogsClient
    ) async {
        let fetched = await withTaskGroup(of: (Int, DiscogsReleaseDetail)?.self) { group in
            for release in wanted {
                let title = release.title
                let known = release.discogsID
                group.addTask { () async -> (Int, DiscogsReleaseDetail)? in
                    // A release with no Discogs ID has to be found before it
                    // can be read — which is exactly what opening the tile
                    // did, and why the blank ones were the ones this used to
                    // skip. Same work, done before somebody clicks for it.
                    var identifier = known
                    if identifier == nil {
                        identifier = try? await client.releaseID(title: title, artist: name)
                    }
                    guard let identifier,
                          let detail = try? await client.release(id: identifier)
                    else { return nil }
                    return (identifier, detail)
                }
            }
            var results: [(Int, DiscogsReleaseDetail)] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        guard !Task.isCancelled, !fetched.isEmpty else { return }
        for (identifier, detail) in fetched {
            discogsEnricher.store(detail, id: identifier)
        }
        // Once per batch. Each bump invalidates the cached profile, so bumping
        // per release rebuilt the whole graph two dozen times — and bumping
        // only at the very end meant the grid sat blank until every last
        // request had landed.
        try? context.save()
        revision &+= 1
    }

    /// Throws away what was worked out about a node, because the catalogue it
    /// was worked out from has just changed.
    func forgetGraph(for node: MusicNode) {
        GraphStore.forget(node, in: context)
        try? context.save()
    }

    /// Puts a newly found portrait onto the edges that already point at that
    /// artist.
    ///
    /// A stored edge carries its destination's picture, so a portrait arriving
    /// later would otherwise not show until the source node was walked again.
    /// Rewriting one column on the rows that name them is a great deal cheaper
    /// than rebuilding anybody's graph.
    private func paint(_ name: String, with address: String) {
        let key = RecordingKey.normalizeArtist(name)
        let artist = MusicNodeKind.artist.rawValue
        let rows = (try? context.fetch(FetchDescriptor<StoredEdge>(predicate: #Predicate {
            $0.toKey == key && $0.toKindRaw == artist && $0.toArtworkURLString == nil
        }))) ?? []
        guard !rows.isEmpty else { return }
        for row in rows { row.toArtworkURLString = address }
    }

    /// Fills in artist thumbnails slowly, in the background, forever.
    ///
    /// The rows that have no picture are the ones nobody has dug into, and
    /// there can be hundreds of them. Fetching on sight would empty the
    /// request budget in seconds; fetching never leaves the page full of
    /// holes. So it drips: one artist every few seconds, cached permanently,
    /// picking up where it left off next time the app opens.
    ///
    /// Deliberately unhurried. Nobody is waiting on this — the page is
    /// already usable, and a picture that arrives a minute later is still a
    /// picture.
    /// Names the page currently open would like pictures for, so the fill
    /// works on what the listener can see before it works on the rest.
    @ObservationIgnored private var portraitPriority: [String] = []

    func wantPortraits(for names: [String]) {
        portraitPriority = names.filter { ArtistName.isRealArtist($0) }
    }

    /// Must be owned by something that outlives a page.
    ///
    /// This used to be started from the artist page, which is destroyed on
    /// every navigation — so the task was cancelled the first time anybody
    /// went anywhere, and the "started" guard then stopped it ever running
    /// again. It filled in for about four seconds per launch, which is why
    /// rows stayed blank until each artist was opened by hand.
    func fillPortraitsInBackground(spacing: Duration = .milliseconds(1500)) async {
        guard !portraitFillStarted, discogsClient.isConfigured else { return }
        portraitFillStarted = true
        // Released on the way out, so a run that is cancelled can be picked up
        // again rather than the queue being closed for the session.
        defer { portraitFillStarted = false }

        // Let the page the listener is actually looking at finish first.
        try? await Task.sleep(for: .seconds(4))

        // How many background pictures have been stored without telling the
        // page about them.
        var quiet = 0

        while !Task.isCancelled {
            guard let next = nextPortraitNeeded() else {
                if quiet > 0 { revision &+= 1 }
                return
            }
            // Consumed above, so the flag is set there instead.
            let wasOnScreen = lastWasOnScreen
            let found: String?
            do {
                found = try await discogsClient.artistThumbnail(named: next)
            } catch is CancellationError {
                return
            } catch {
                // A dropped connection is not an answer about this artist.
                // Marking it failed would bar the name for a month over a
                // blink of the network, so the loop just waits and retries.
                try? await Task.sleep(for: spacing)
                continue
            }
            guard !Task.isCancelled else { return }

            let record = ArtistPortrait(
                nameKey: RecordingKey.normalizeArtist(next), name: next
            )
            // Nothing found is a real answer, and worth remembering so the
            // same name is not asked after on every launch.
            if let found {
                record.imageURLString = found
                paint(next, with: found)
            } else {
                record.lookupFailed = true
            }
            // Replaces any earlier attempt for the same name.
            if let existing = portrait(for: next) { context.delete(existing) }
            context.insert(record)
            try? context.save()

            // Telling the page costs it a full rebuild of its graph, so this
            // is deliberately not done per picture. A name the listener is
            // looking at is worth that immediately; the rest arrive in
            // batches, which is invisible for filling in pictures and four
            // times less work.
            quiet += 1
            if wasOnScreen || quiet >= 5 {
                quiet = 0
                revision &+= 1
            }

            try? await Task.sleep(for: spacing)
        }
    }

    func portrait(for name: String) -> ArtistPortrait? {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The next name worth a picture: somebody named as a connection, who has
    /// neither been dug into nor already looked up.
    /// Names still wanting a picture, worked out once and then worked
    /// through.
    ///
    /// This used to rescan every cached artist and every previous lookup on
    /// each tick — two full table scans a second and a half, forever, for a
    /// job that is filling in thumbnails.
    /// Whether the name just handed out came from the on-screen list, which
    /// decides whether the page is told about it at once.
    @ObservationIgnored private var lastWasOnScreen = false
    @ObservationIgnored private var portraitQueue: [String] = []
    @ObservationIgnored private var portraitQueueBuiltAt = 0

    private func nextPortraitNeeded() -> String? {
        // The on-screen list is consumed rather than re-searched: each name
        // is checked once and then gone, instead of every name being looked
        // up again on every tick.
        while let next = portraitPriority.first {
            portraitPriority.removeFirst()
            if portrait(for: next) == nil {
                lastWasOnScreen = true
                return next
            }
        }
        lastWasOnScreen = false
        if portraitQueue.isEmpty || portraitQueueBuiltAt != revision {
            portraitQueue = pendingPortraits()
            portraitQueueBuiltAt = revision
        }
        while let next = portraitQueue.first {
            portraitQueue.removeFirst()
            if portrait(for: next) == nil { return next }
        }
        return nil
    }

    private func pendingPortraits() -> [String] {
        let artists = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        let dug = Set(artists.filter { $0.imageURLString?.isEmpty == false }.map(\.nameKey))
        let looked = Dictionary(
            ((try? context.fetch(FetchDescriptor<ArtistPortrait>())) ?? []).map { ($0.nameKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var pending: [String] = []
        var seen = Set<String>()
        for artist in artists {
            let named = artist.labelNeighbourNames + artist.styleNeighbourNames
                + artist.collaboratorNames + artist.aliasNames
                + artist.memberNames + artist.groupNames
            for name in named {
                let key = RecordingKey.normalizeArtist(name)
                guard !key.isEmpty, !dug.contains(key), seen.insert(key).inserted else { continue }
                if let attempt = looked[key], !attempt.isWorthRetrying { continue }
                pending.append(name)
            }
        }
        return pending
    }

    /// Reads an artist's Bandcamp, when their catalogue entry gives an
    /// address for it.
    ///
    /// Nothing here searches Bandcamp — their robots.txt forbids it — so an
    /// artist whose Discogs entry names no Bandcamp simply has none as far as
    /// Indigo is concerned.
    func enrichBandcamp(forArtist name: String, limit: Int = 8) async {
        guard let page = discogsEnricher.cachedArtist(named: name)?.bandcampURL else { return }
        var enricher = BandcampEnricher(context: context)
        enricher.onProgress = { [weak self] in
            guard let self else { return }
            self.revision &+= 1
        }
        guard let found = try? await enricher.enrich(artist: name, page: page, limit: limit),
              !found.isEmpty
        else { return }
        try? context.save()
        forgetGraph(for: .artist(name))
        revision &+= 1
    }

    /// Asks whether each recording can actually be played, and remembers the
    /// answer.
    ///
    /// Run before a Listen list is shown, so a recording that will refuse is
    /// never offered rather than offered and then skipped. Bounded and
    /// parallel — these are small requests to a public endpoint, but they are
    /// still requests.
    func verifyListenable(releaseIDs: [Int], limit: Int = 24) async {
        let enricher = discogsEnricher
        let records = releaseIDs.compactMap { enricher.cachedRelease(id: $0) }
        var pending: [(record: DiscogsReleaseRecord, index: Int, url: URL)] = []
        for record in records {
            for (index, video) in record.allVideos.enumerated() where video.playable == 0 {
                pending.append((record, index, video.url))
            }
        }
        guard !pending.isEmpty else { return }

        for batch in Array(pending.prefix(limit)).chunked(into: 6) {
            guard !Task.isCancelled else { return }
            let verdicts = await withTaskGroup(of: (Int, Bool?).self) { group in
                for (offset, entry) in batch.enumerated() {
                    let url = entry.url
                    group.addTask { (offset, await YouTubeAvailability.isPlayable(url)) }
                }
                var found: [Int: Bool?] = [:]
                for await (offset, verdict) in group { found[offset] = verdict }
                return found
            }
            guard !Task.isCancelled else { return }
            for (offset, entry) in batch.enumerated() {
                // A dropped connection leaves the question unasked rather than
                // recording a verdict about the recording.
                guard let verdict = verdicts[offset] ?? nil else { continue }
                mark(entry.record, index: entry.index, playable: verdict)
            }
            try? context.save()
            revision &+= 1
        }
    }

    /// Remembers that a recording refused to play, wherever it appears. Called
    /// when the player finds out the hard way, which is the layer certain to
    /// catch an uploader's embedding setting.
    func markUnplayable(_ url: URL) {
        let address = url.absoluteString
        var changed = false
        for record in (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] {
            for (index, stored) in record.videoURLStrings.enumerated() where stored == address {
                mark(record, index: index, playable: false)
                changed = true
            }
        }
        guard changed else { return }
        try? context.save()
        revision &+= 1
    }

    private func mark(_ record: DiscogsReleaseRecord, index: Int, playable: Bool) {
        var verdicts = record.videoPlayable
        if verdicts.count < record.videoURLStrings.count {
            verdicts += Array(repeating: 0, count: record.videoURLStrings.count - verdicts.count)
        }
        guard verdicts.indices.contains(index) else { return }
        verdicts[index] = playable ? 1 : 2
        record.videoPlayable = verdicts
    }

    /// The graph node a detail page stands for, so a visit can be remembered
    /// against the same identity the graph uses. Returns nil for pages that
    /// are not part of the music graph.
    func node(for page: DetailPage) -> MusicNode? {
        switch page {
        case .digArtist(let mbid, let name):
            return .artist(name, mbid: mbid)
        case .digLabel(let mbid, let name):
            return .label(name, mbid: mbid)
        case .digDiscogsLabel(let name):
            return .label(name)
        case .digRelease(let id, let title):
            return .release(title, discogsID: id)
        case .digCatalog(let number):
            return .catalogNumber(number)
        case .digScene(let city):
            return SceneEngine(context: context).scene(city: city)?.node
        case .digRecording(let id, _):
            // Resolved through the recording itself so an identified track and
            // its unknown past are one node rather than two.
            var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first.map { MusicNode.recording($0) }
        default:
            return nil
        }
    }

    /// Remembers that a page was opened, and the step that led there.
    func remember(_ page: DetailPage, from origin: DetailPage?) {
        guard let node = node(for: page) else { return }
        DigHistory(context: context).record(node, from: origin.flatMap { self.node(for: $0) })
        revision &+= 1
    }

    /// One descent, cached against the revision.
    ///
    /// DEEP lives near the bottom of a long page, so a lazy list destroys and
    /// rebuilds it every time it scrolls out of view and back. Without this,
    /// flicking up and down re-walks the graph on each pass, which is exactly
    /// what made scrolling stutter.
    @ObservationIgnored private var descents = DigCache<DeepEngine.Descent>()

    func descent(from origin: MusicNode, at level: DeepLevel) async -> DeepEngine.Descent {
        let key = "\(origin.id)|\(level.rawValue)"
        let asked = revision
        if let fresh = descents.fresh(key, revision: asked) { return fresh }
        settle()
        let found = await worker.descent(from: origin, at: level, generation: asked)
        descents.store(found, key: key, revision: asked)
        return found
    }

    func cachedDescent(from origin: MusicNode, at level: DeepLevel) -> DeepEngine.Descent? {
        descents.any("\(origin.id)|\(level.rawValue)")
    }

    /// Everything next to something, of any kind — the step DIG takes.
    func connections(from node: MusicNode) async -> [MusicGraph.Connection] {
        let _ = revision
        settle()
        return await worker.connections(from: node, generation: revision)
    }

    func scenes(forArtist name: String) async -> [MusicScene] {
        let _ = revision
        settle()
        return await worker.scenes(forArtist: name, generation: revision)
    }

    func scene(city: String) async -> MusicScene? {
        let _ = revision
        settle()
        return await worker.scene(city: city, generation: revision)
    }

    func undergroundCuts(for node: MusicNode) async -> [DeepResult] {
        let _ = revision
        settle()
        return await worker.undergroundCuts(for: node, generation: revision)
    }

    func genres(for recording: Recording) -> [String] {
        let _ = revision
        if let name = recording.artistName,
           let discogs = discogsEnricher.cachedArtist(named: name), discogs.isFresh {
            let tags = discogs.styles + discogs.genres
            if !tags.isEmpty { return Array(tags.prefix(8)) }
        }
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

    /// A radio tracklist starts as a small provider claim: artist, title and
    /// where it was heard. Promote it through the same catalogue caches used
    /// by an explicit DIG so it gains a release, a label, a year and a sleeve.
    ///
    /// The result is written to the recording's own metadata row rather than
    /// to whatever happened to ask for it. A track heard in a broadcast has a
    /// cover whether or not anyone kept it, and the tracklist, the graph and
    /// the crate should all be able to draw the same one.
    @discardableResult
    func resolveRelease(for recording: Recording) async -> RecordingMetadata? {
        // Rows imported before the credit was read apart — and rows from any
        // station that only ever publishes one string — arrive with the whole
        // line as the title. Repair that first: without it there is no artist
        // to look up and no artist to dig into.
        if recording.recreditFromTitle() { try? context.save() }

        guard let initialArtist = recording.artistName, !initialArtist.isEmpty,
              let initialTitle = recording.title, !initialTitle.isEmpty else { return nil }

        // Already answered. Asking a rate-limited public service the same
        // question again is the one thing this must never do.
        if let existing = engine.metadata(for: recording.id),
           existing.artworkURL != nil, existing.releaseTitle != nil {
            return existing
        }

        isEnriching = true
        defer { isEnriching = false }

        // MusicBrainz identifies the exact recording and, importantly, its
        // release. Discogs then supplies the visual and relationship-rich side.
        _ = try? await enricher.enrich(recording)
        let artistName = recording.artistName ?? initialArtist
        let releaseTitle = recording.albumTitle

        var discogsArtist: DiscogsArtist?
        do {
            discogsArtist = try await discogsEnricher.artist(named: artistName)
            if let discogsArtist {
                try? await discogsEnricher.recommendations(for: discogsArtist)
            }
        } catch is CancellationError {
            return engine.metadata(for: recording.id)
        } catch {
            // MusicBrainz facts are still useful if Discogs is unavailable.
        }

        let coverURL = await resolveCover(
            for: recording, artistName: artistName,
            releaseTitle: releaseTitle, trackTitle: initialTitle,
            discogsArtist: discogsArtist
        )

        let metadata = engine.metadata(for: recording.id) ?? {
            let fresh = RecordingMetadata(recordingID: recording.id)
            context.insert(fresh)
            return fresh
        }()

        // Last of all, the artist's own Bandcamp — reached by the address
        // their catalogue entry gives, never by searching Bandcamp, which its
        // robots.txt forbids.
        //
        // This is not a fallback for tidiness. A great deal of underground
        // music is on Bandcamp and nowhere else: no MusicBrainz release, no
        // Discogs pressing. For that music the alternative is not a worse
        // answer, it is the app insisting the record does not exist.
        var cover = coverURL
        if cover == nil || metadata.releaseTitle == nil,
           let page = discogsEnricher.cachedArtist(named: artistName)?.bandcampURL,
           let release = await BandcampEnricher(context: context)
               .findRelease(containing: initialTitle, byArtist: artistName, page: page) {
            cover = cover ?? BandcampImage.sized(release.imageURL, BandcampImage.cover)
            if metadata.releaseTitle == nil { metadata.releaseTitle = release.title }
            if metadata.labelName == nil { metadata.labelName = release.labelName }
            if metadata.releaseDate == nil { metadata.releaseDate = release.year }
            if recording.albumTitle?.isEmpty ?? true { recording.albumTitle = release.title }
        }
        // Deliberately the release sleeve, never the radio-show image or the
        // artist portrait: this is a picture of the record, not of the hour it
        // was played in.
        if let cover, metadata.artworkURLString == nil {
            metadata.artworkURLString = cover.absoluteString
        }

        try? context.save()
        revision &+= 1
        return metadata
    }

    /// The sleeve of the record this track is actually on.
    ///
    /// Ordered by identity, not by convenience. Every one of these can return
    /// *a* picture; only some of them can return the right one. A search by
    /// name will happily hand back a reissue, a compilation, or an unrelated
    /// single that shares a title — so the sources that know which release
    /// they are talking about go first, and the ones that are guessing go
    /// last and under conditions.
    private func resolveCover(
        for recording: Recording,
        artistName: String,
        releaseTitle: String?,
        trackTitle: String,
        discogsArtist: DiscogsArtist?
    ) async -> URL? {
        // 1. Exact. MusicBrainz identified this release, so its sleeve can be
        //    asked for by identifier — no search, nothing to mismatch.
        //
        //    Fetched rather than merely constructed: plenty of releases have
        //    no cover archived, and a URL that 404s is worse than no URL,
        //    because it makes the row claim a sleeve it will never draw.
        if let releaseMBID = engine.metadata(for: recording.id)?.releaseMBID,
           !releaseMBID.isEmpty,
           let candidate = URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-500"),
           await RemoteArtworkStore.shared.image(for: candidate) != nil {
            return candidate
        }

        // 2. Near-exact. The right artist's own catalogue, matched on the
        //    album title rather than searched for.
        if let releaseTitle, !releaseTitle.isEmpty, let discogsArtist {
            let wanted = Self.catalogueKey(releaseTitle)
            if let index = discogsArtist.releaseTitles.firstIndex(where: {
                Self.catalogueKey($0) == wanted
            }) {
                let full = index < discogsArtist.releaseImageURLStrings.count
                    ? discogsArtist.releaseImageURLStrings[index] : ""
                let thumb = index < discogsArtist.releaseThumbnailURLStrings.count
                    ? discogsArtist.releaseThumbnailURLStrings[index] : ""
                if let resolved = URL(string: full.isEmpty ? thumb : full) { return resolved }
            }
        }

        // 3. A search, but at least for the right album by the right artist.
        if let releaseTitle, !releaseTitle.isEmpty,
           let image = await searchedCover(title: releaseTitle, artistName: artistName) {
            return image
        }

        // 4. Ask which release *contains* this track.
        //
        //    The route that actually matters for radio music, and the one
        //    that was missing. A tracklist gives you a song, and a song is
        //    almost never the name of a record — so looking for a release
        //    called "Rev8617" finds nothing, while asking which release has a
        //    track called "Rev8617" on it returns Compro, the album the
        //    listener heard a piece of. Which is the picture they wanted.
        let searchTitle = TrackCredit.searchTitle(trackTitle)
        if let releaseID = try? await discogsClient.releaseID(track: searchTitle, artist: artistName),
           let release = try? await discogsEnricher.release(id: releaseID),
           Self.credits(release, artistName),
           let image = release.imageURL {
            return image
        }

        return nil
    }

    /// A Discogs title search, kept honest by checking that what came back is
    /// credited to the artist we asked about. Discogs' search is forgiving; a
    /// sleeve is not worth attaching to the wrong record because a title
    /// happened to match.
    private func searchedCover(title: String, artistName: String) async -> URL? {
        guard let releaseID = try? await discogsClient.releaseID(title: title, artist: artistName),
              let release = try? await discogsEnricher.release(id: releaseID),
              Self.credits(release, artistName)
        else { return nil }
        return release.imageURL
    }

    /// Whether a release is actually credited to the artist we asked about.
    /// Discogs' search is forgiving; a sleeve is not worth attaching to the
    /// wrong record just because a title matched.
    private static func credits(_ release: DiscogsReleaseRecord, _ artistName: String) -> Bool {
        let wanted = RecordingKey.normalizeArtist(artistName)
        guard !wanted.isEmpty else { return false }
        return release.artistNames.contains { RecordingKey.normalizeArtist($0) == wanted }
    }

    /// The crate row shows what the recording turned out to be, so it mirrors
    /// the resolved sleeve and the artist's tags onto itself.
    func enrichCratedRecording(_ recording: Recording) async {
        let metadata = await resolveRelease(for: recording)

        let recordingID = recording.id
        var descriptor = FetchDescriptor<CrateItem>(
            predicate: #Predicate { $0.recording?.id == recordingID }
        )
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first else { return }

        // Overwrites rather than fills. A crate row imported by an earlier
        // build is carrying whatever the old, name-search-first ladder found,
        // which is exactly the wrong sleeve this is meant to correct. The
        // recording's own resolved cover is the better answer by construction.
        if let cover = metadata?.artworkURLString, item.artworkURLString != cover {
            item.artworkURLString = cover
        }
        if let name = recording.artistName,
           let discogs = discogsEnricher.cachedArtist(named: name) {
            let genres = discogs.styles + discogs.genres
            if !genres.isEmpty { item.setGenres(Array(genres.prefix(8))) }
        }

        try? context.save()
        revision &+= 1
    }

    /// Fills in the tracks of a broadcast that is actually on screen.
    ///
    /// An NTS episode is twenty-odd rows and MusicBrainz answers one request a
    /// second, so this is bounded and skips anything already answered: it is
    /// there to make the tracklist you are looking at fill in, not to crawl
    /// the archive. Rows nobody has looked at stay unresolved, which is the
    /// correct amount of work to do for them.
    func resolveBroadcastTracklist(
        providerID: String,
        showID: String,
        limit: Int = 8
    ) async {
        let pending = ((try? context.fetch(FetchDescriptor<Recording>())) ?? [])
            .filter { recording in
                guard recording.artistName?.isEmpty == false,
                      recording.title?.isEmpty == false,
                      recording.appearances.contains(where: {
                          $0.providerID == providerID && $0.showID == showID
                      })
                else { return false }
                guard let existing = engine.metadata(for: recording.id) else { return true }
                return existing.artworkURL == nil && !existing.lookupFailed
            }

        for recording in pending.prefix(limit) {
            guard !Task.isCancelled else { return }
            await resolveRelease(for: recording)
        }
    }

    /// What a tracklist row should show once the catalogue has answered.
    func releaseDetail(for recording: Recording) -> (line: String?, artwork: URL?) {
        let _ = revision
        guard let metadata = engine.metadata(for: recording.id) else { return (nil, nil) }
        // Falls through to the shared ladder, so a track whose album Indigo
        // pictures elsewhere is not blank here.
        let artwork = metadata.artworkURL ?? metadata.releaseTitle.flatMap {
            DigArtwork(context: context).release(title: $0, artist: recording.artistName).full
        }
        return (metadata.releaseLine, artwork)
    }

    /// Reads apart every crated radio credit that was kept as one string.
    ///
    /// Deliberately not rationed the way the catalogue lookups below are:
    /// this needs no network, and it is what puts the artist — and so the
    /// DIG button — back on rows imported before the credit was split. There
    /// is no reason to make somebody open the Crate four times for that.
    @discardableResult
    func repairRadioCredits() -> Int {
        let crated = ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? [])
            .compactMap(\.recording)
        var repaired = 0
        for recording in uniqueRecordings(crated) where recording.recreditFromTitle() {
            repaired += 1
        }
        if repaired > 0 {
            try? context.save()
            revision &+= 1
        }
        return repaired
    }

    /// Migrates radio tracks crated by earlier builds as the Crate opens.
    /// Bounded so a large collection never turns into an unprompted crawl.
    func enrichRadioCrateInBackground(limit: Int = 6) async {
        repairRadioCredits()

        let candidates = ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? [])
            .filter { item in
                guard item.kind == .recording, let recording = item.recording else { return false }
                guard !recording.appearances.isEmpty else { return false }
                // A row that already shows *a* cover still needs revisiting if
                // the recording itself has none: that picture came from the
                // older, name-search-first ladder and may not be the record
                // this track is on.
                let resolved = engine.metadata(for: recording.id)?.artworkURLString
                return resolved == nil || item.artworkURL == nil || item.genreTags.isEmpty
            }
            .compactMap(\.recording)
        for recording in candidates.prefix(limit) {
            guard !Task.isCancelled else { return }
            await enrichCratedRecording(recording)
        }
    }

    private static func catalogueKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
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
        let discogsKey = "discogs:artist:\(RecordingKey.normalizeArtist(name))"
        // A notice belongs to the page that produced it. Cleared before the
        // guard, or an error from one artist follows you onto the next.
        notice = nil

        // Discogs is the foreground path: it returns the complete artist
        // bundle concurrently and is not held behind MusicBrainz's global
        // one-request-per-second gate.
        if discogsClient.isConfigured, !attempted.contains(discogsKey) {
            attempted.insert(discogsKey)
            isEnriching = true
            do {
                if let artist = try await discogsEnricher.artist(named: name) {
                    try? context.save()
                    // What the graph knew about this artist was worked out
                    // from the catalogue entry that has just been replaced.
                    forgetGraph(for: .artist(name))
                    backfillLocalGenres(artistName: name, genres: artist.styles + artist.genres)
                    revision &+= 1
                    isEnriching = false
                    let previews = artist.releaseThumbnailURLStrings.compactMap(URL.init(string:))
                    Task.detached(priority: .utility) {
                        await RemoteArtworkStore.shared.prefetch(Array(previews.prefix(12)))
                    }
                    // Recommendations arrive as a quiet second stage: the
                    // page and sleeves are already usable while this fills in.
                    do {
                        try await discogsEnricher.recommendations(for: artist)
                        try? context.save()
                        revision &+= 1
                    } catch {
                        // Discovery enrichment is optional and never replaces
                        // a populated page with provider diagnostics.
                    }
                    return
                }
                attempted.remove(discogsKey)
            } catch is CancellationError {
                isEnriching = false
                return
            } catch {
                attempted.remove(discogsKey)
                // Catalogue enrichment is an implementation detail. The page
                // keeps its local/MusicBrainz data if the developer service is
                // unavailable; listeners never manage provider credentials.
            }
        }

        guard !attempted.contains(key) else {
            isEnriching = false
            return
        }
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
            // One representative recording is enough to discover a label.
            // More fan-out makes a single click monopolise the public queue.
            for recording in engine.recordings(byArtist: name).prefix(1) {
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
            if await artistProfile(name: name, mbid: mbid).isBare {
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

    func enrichRelease(id: Int) async {
        let key = "discogs:release:\(id)"
        notice = nil
        guard !attempted.contains(key) else { return }
        attempted.insert(key)
        isEnriching = true
        defer { isEnriching = false }
        do {
            try await discogsEnricher.release(id: id)
            try? context.save()
            revision &+= 1
        } catch is CancellationError {
        } catch {
            attempted.remove(key)
            notice = message(for: error)
        }
    }

    /// Resolves a text-only catalogue row only when the listener chooses it.
    /// This keeps browsing complete without bulk-searching every title or
    /// consuming the provider's request allowance in the background.
    func resolveRelease(title: String, artist: String) async -> Int? {
        isEnriching = true
        defer { isEnriching = false }
        do {
            guard let id = try await discogsClient.releaseID(title: title, artist: artist) else { return nil }
            try await discogsEnricher.release(id: id)
            try? context.save()
            revision &+= 1
            return id
        } catch {
            return nil
        }
    }

    func enrichDiscogsLabel(named name: String) async {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty, discogsLabelProfiles[key] == nil else { return }
        isEnriching = true
        defer { isEnriching = false }
        do {
            let results = try await discogsClient.labelCatalogue(named: name)
            discogsLabelProfiles[key] = DiscogsLabelProfile(name: name, results: results)
            let previews = results.compactMap { $0.thumbnail.flatMap(URL.init(string:)) }
            Task.detached(priority: .utility) {
                await RemoteArtworkStore.shared.prefetch(Array(previews.prefix(16)))
            }
        } catch {
            // The label page remains quiet and retryable on the next visit.
        }
    }

    func retryRelease(id: Int) async {
        attempted.remove("discogs:release:\(id)")
        await enrichRelease(id: id)
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
        attempted.remove("discogs:artist:\(RecordingKey.normalizeArtist(name))")
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
