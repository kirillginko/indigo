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
    ///
    /// This is expensive by design: reading a profile again means walking the
    /// graph and re-reading the catalogue. Only write to it when what a page
    /// *says* has changed.
    private(set) var revision = 0

    /// Bumped when a picture arrives and nothing else has changed.
    ///
    /// Kept apart from `revision` because a thumbnail turning up for one row
    /// is not a reason to rebuild an artist's graph. The background fill runs
    /// for as long as the app is open; on the shared counter it was asking
    /// every visible page to rebuild itself every second or two, which is
    /// what made scrolling catch.
    private(set) var artworkRevision = 0

    /// Portraits found by the background fill, by normalised name. Held in
    /// memory so a row can resolve one without a fetch of its own.
    private(set) var portraits: [String: URL] = [:]

    func portraitURL(for name: String) -> URL? {
        let _ = artworkRevision
        return portraits[RecordingKey.normalizeArtist(name)]
    }
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
    /// How long a burst of writes counts as one change.
    @ObservationIgnored private static let changeWindow = Duration.milliseconds(400)
    @ObservationIgnored private var pendingChange: Task<Void, Never>?
    @ObservationIgnored private var lastChangeAt: ContinuousClock.Instant?

    /// Tells the pages something changed — once for a burst of writes.
    ///
    /// Every announcement costs a full graph walk and a rebuild on each open
    /// DIG surface, because that is what `.task(id: dig.revision)` is for.
    /// Enriching one cold artist writes three times in as many seconds, and a
    /// real session's trace showed four walks of the same artist inside a
    /// single 3341ms enrichment that made exactly one network request. The
    /// page was rebuilding itself out of a row still being written, and the
    /// enrichment was queueing behind its own announcements on the main actor.
    ///
    /// The first write is announced at once, so a page that has been waiting
    /// still fills in immediately. Anything arriving in the moment after it is
    /// collapsed into a single announcement at the end of the burst.
    private func announceChange() {
        let now = ContinuousClock.now
        guard let last = lastChangeAt, now - last < Self.changeWindow else {
            pendingChange?.cancel()
            pendingChange = nil
            lastChangeAt = now
            revision &+= 1
            return
        }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: Self.changeWindow)
            guard !Task.isCancelled, let self else { return }
            self.pendingChange = nil
            self.lastChangeAt = .now
            self.revision &+= 1
        }
    }

    private func settle() {
        guard context.hasChanges else { return }
        saveContext()
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

    /// The Dig landing page, as it was last drawn.
    ///
    /// Same bargain as `DigCache`: what was there, shown instantly and
    /// corrected a moment later, rather than a page rebuilding itself in front
    /// of somebody who was reading it ten seconds ago.
    @ObservationIgnored var landing: DigLanding?

    @ObservationIgnored private var profiles = DigCache<ArtistProfile>()

    /// The current profile, worked out off the main thread.
    ///
    /// Only the answer comes back here; the reading and the walking happen on
    /// the worker's own context, so a page filling in does not stop a scroll.
    /// Walks already running, by the artist each is working out.
    ///
    /// Two callers want the same profile at the same moment — the task that
    /// follows navigation and the one that follows `revision`, 120ms behind
    /// it — and both miss the cache, because neither has finished to fill it.
    ///
    /// The ticket used to carry the revision as well, on the grounds that an
    /// answer from before a write is not the one somebody asking after it
    /// wants. That is true and it cost twice the work: a write landing in the
    /// 120ms between the two tasks gave them different tickets, so they both
    /// walked, and the trace shows what that looks like — Skit 985ms and
    /// 964ms, SNKLS 1065ms and 1097ms, Annika Henderson 967ms and 940ms, two
    /// full walks of one artist inside a tenth of a second of each other.
    ///
    /// So a second caller joins whatever walk is already under way, even one
    /// started a revision ago. Its answer can be one write behind, and that
    /// is safe rather than sloppy: the write that moved `revision` also
    /// re-fires `.task(id: dig.revision)` on every open page, so a fresher
    /// answer is already on its way. What is gained is that there is never
    /// more than one walk of an artist in flight at a time.
    @ObservationIgnored private var walking: [String: Task<ArtistProfile, Never>] = [:]

    /// How many walks have actually been started. Only a test reads it, and
    /// it exists because "one walk per artist" is a claim about work that is
    /// invisible from the outside — the two callers return the same value
    /// whether they shared a walk or each did their own, which is how this
    /// went unnoticed while a trace showed it plainly.
    @ObservationIgnored private(set) var walksStarted = 0

    /// Moves `revision` the way a write would, for the test that needs one to
    /// land between two callers.
    func bumpRevisionForTesting() { revision &+= 1 }

    func artistProfile(name: String, mbid: String?) async -> ArtistProfile {
        let key = Self.artistKey(name: name, mbid: mbid)
        let asked = revision
        if let fresh = profiles.fresh(key, revision: asked) { return fresh }

        if let running = walking[key] {
            Trace.step("graph.join", key) {}
            return await running.value
        }

        settle()
        walksStarted += 1
        // Traced by key rather than by name. Two walks of "Dean Blunt" a
        // tenth of a second apart are either one bug or none, and the trace
        // could not say which — the key is what the dedupe actually compares,
        // so it is what the line has to show.
        let running = Task { [worker] in
            await Trace.stage("graph.walk", key) {
                await worker.artistProfile(name: name, mbid: mbid, generation: asked)
            }
        }
        walking[key] = running
        let profile = await running.value
        walking[key] = nil
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

    func discogsLabelProfile(named name: String, discogsID: Int? = nil) -> DiscogsLabelProfile? {
        if let discogsID, let found = discogsLabelProfiles["discogs \(discogsID)"] { return found }
        return discogsLabelProfile(named: name)
    }

    private func discogsLabelProfile(named name: String) -> DiscogsLabelProfile? {
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
    /// Deliberately not held behind the foreground gate.
    ///
    /// The gate exists so the nine requests a cold artist needs are not
    /// queued behind a background fill. Sleeves are not among those nine —
    /// they are pictures arriving on a page that already works, exactly like
    /// the portraits are. Gating them made a connection row's face turn up
    /// long after everything else on the page, which is a worse trade than
    /// the one the gate was making in the first place.
    /// - Parameter whenThereIsRoom: wait for room in the minute before each
    ///   batch, and stop rather than spend the last of it. For the batch a page
    ///   asks for on its own; one the listener asked for by revealing more
    ///   releases goes ahead regardless.
    func fillMissingReleaseArtwork(
        forArtist name: String, mbid: String?, limit: Int = 24, whenThereIsRoom: Bool = false
    ) async {
        await digReleaseArtwork(forArtist: name, mbid: mbid, limit: limit, whenThereIsRoom: whenThereIsRoom)
    }

    private func digReleaseArtwork(
        forArtist name: String, mbid: String?, limit: Int, whenThereIsRoom: Bool
    ) async {
        // Records this app has not read in full.
        //
        // This used to ask for the ones with no picture at all, and that
        // stopped meaning anything the moment sleeves started coming from
        // `artists/{id}/releases`, which hands back a thumbnail for nearly
        // everything — so the fill found nothing to do and quietly stopped
        // fetching. What it fetches is a release's own record, which carries
        // the full-size cover *and* the labels that pressed it, and neither
        // arrives any other way. A small picture is not a reason to stop
        // asking who put the record out.
        let missing = await artistProfile(name: name, mbid: mbid).releases
            .filter { needsReading($0) }
        guard !missing.isEmpty else { return }

        // Fetched together, written one at a time.
        //
        // Each of these is a round trip, and done in sequence a dozen of them
        // is the difference between a page that fills in and a page you wait
        // for. The network half runs in parallel; the writes stay serial,
        // because they all land in one ModelContext.
        let client = discogsClient
        // Twelve at a time. The grid shows two dozen and all of them deserve
        // a sleeve, but firing four dozen requests in one breath is how a
        // service starts refusing them — and a batch that lands is a batch
        // the listener can see.
        //
        // This was six. Discogs meters requests per minute rather than how
        // many are in flight, so six-then-six spends exactly what twelve does;
        // what the second batch added was a second save, a second
        // announcement and a second walk of the graph behind the page. A
        // typical artist needs a dozen records read, which is now one.
        for batch in Array(missing.prefix(limit)).chunked(into: 12) {
            guard !Task.isCancelled else { return }
            if whenThereIsRoom, !(await waitForRoom()) { return }
            await fetchAndStore(batch, artist: name, client: client)
        }
    }

    /// Whether a record still has to be read in its own right.
    ///
    /// Two reasons, and the second is the one that was missing. A release with
    /// no full-size cover has plainly never been read — the artist endpoint
    /// carries only a thumbnail. But a release read *before* labels had
    /// identities has a cover and a label name and no way to say which label
    /// that name meant, and nothing would ever ask about it again: the fill
    /// skipped it for having a picture, and it is the only thing that asks.
    ///
    /// So a record naming labels it cannot identify is unread as far as this
    /// is concerned. `release(id:)` refuses to refetch anything still fresh,
    /// so this cannot turn into a loop over records that were only just read.
    private func needsReading(_ release: ArtistProfile.ReleaseLine) -> Bool {
        if release.imageURL == nil { return true }
        guard let identifier = release.discogsID,
              let stored = discogsEnricher.cachedRelease(id: identifier)
        else { return true }
        return !stored.labelNames.isEmpty && stored.labelDiscogsIDs.isEmpty
    }

    private func fetchAndStore(
        _ wanted: [ArtistProfile.ReleaseLine],
        artist name: String,
        client: DiscogsClient
    ) async {
        // Through the same source `DiscogsEnricher.release(id:)` uses, which
        // this path had been going around.
        //
        // It went around it because the enricher holds a ModelContext, and
        // every task in the group would have queued on the main actor to
        // reach it — so it took the bare client, and lost what the source
        // does besides the request. `CatalogReleaseSource` is a `Sendable`
        // struct with no context, so it can be asked from inside the group.
        //
        // What that buys is the fill, not speed. A build that can reach
        // Discogs itself is deliberately not sent to the shared cache first —
        // see `canReachProviderDirectly` — so this answers nil at once and asks
        // the backend to describe the record behind the page. These dozen
        // reads are the most expensive thing an artist page does, and until
        // now not one of them ever reached the catalogue for anybody else.
        // A build without a credential does read the shared copy here.
        let catalog = CatalogReleaseSource.shared

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
                    guard let identifier else { return nil }

                    if let shared = await catalog.release(id: identifier) {
                        return (identifier, shared)
                    }
                    // No second `populateInBackground` here: `release(id:)`
                    // has already asked for the fill in exactly the case that
                    // reaches this line, and asking again sent every record
                    // to the Edge Function twice.
                    guard let detail = try? await client.release(id: identifier) else { return nil }
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
        saveContext()
        announceChange()
    }

    /// Throws away what was worked out about a node, because the catalogue it
    /// was worked out from has just changed.
    func forgetGraph(for node: MusicNode) {
        GraphStore.forget(node, in: context)
        saveContext()
    }

    /// Puts a newly found portrait onto the edges that already point at that
    /// artist.
    ///
    /// A stored edge carries its destination's picture, so a portrait arriving
    /// later would otherwise not show until the source node was walked again.
    /// Rewriting one column on the rows that name them is a great deal cheaper
    /// than rebuilding anybody's graph.
    private func paint(_ name: String, with address: String) {
        StoredEdge.repaint(
            artistKey: RecordingKey.normalizeArtist(name), with: address, in: context
        )
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

    // MARK: - Who gets the request budget

    /// How many things the listener is actually waiting for.
    ///
    /// Discogs allows sixty requests a minute. The background portrait fill
    /// takes one every second and a half — forty of them — and a cold artist
    /// needs nine: a search to find them, three for their bundle, five for
    /// the neighbourhood. Over the budget those nine are throttled, which is
    /// how opening somebody came to take six seconds while the app was busy
    /// fetching thumbnails for rows nobody had looked at yet.
    ///
    /// The fill is explicitly work nobody is waiting on. So it stands aside
    /// for work somebody is.
    @ObservationIgnored private var foregroundDigs = 0
    @ObservationIgnored private var foregroundEndedAt: ContinuousClock.Instant?

    /// Until when the background fill must keep out of the way.
    ///
    /// A stream opening is the one request in the app that cannot be retried
    /// quietly: AVPlayer gets sixty seconds and then the station is simply
    /// unavailable. The fill is forty requests a minute of work nobody is
    /// waiting on, and it already stands aside for a page somebody is reading
    /// — a station somebody has just pressed deserves at least as much.
    @ObservationIgnored private var holdUntil: ContinuousClock.Instant?

    /// How long to stand aside. Long enough to cover a stream connecting and
    /// its first buffers, short enough that a listener who leaves music on
    /// still gets their pictures.
    /// A ceiling rather than a duration.
    ///
    /// This was twelve seconds from the moment play was pressed, on the
    /// grounds that a stream gets its first buffers inside that. Most do. The
    /// ones that do not are exactly the ones this protects: a trace of NTS
    /// shows a connect that took twenty-nine seconds and two reconnects, and
    /// the hold ran out fourteen seconds in — so the picture backlog came
    /// back and started spending the request budget while the station was
    /// still failing to open. The protection ended precisely when it was
    /// needed.
    ///
    /// So the hold now lasts as long as the stream is actually opening, and
    /// this is only the point at which a station is assumed never to be
    /// coming. It has to outlast `StreamAudioEngine.connectTimeout` and the
    /// reconnects behind it, or it reintroduces the same gap further along.
    @ObservationIgnored private static let playbackHold = Duration.seconds(45)

    /// Called when audio starts. The app wires this to the player; nothing
    /// here knows what a player is.
    func holdBackgroundWork() {
        holdUntil = ContinuousClock.now + Self.playbackHold
    }

    /// Called once the stream is playing, or has given up.
    ///
    /// The other half of `holdBackgroundWork`. Without it the ceiling above
    /// would be the whole story, and a listener who put a station on would
    /// wait three quarters of a minute for the faces on the page they are
    /// reading. A station that is playing is not competing for anything.
    func releaseBackgroundHold() {
        holdUntil = nil
    }

    /// Whether the fill is currently standing aside. Read by the loop below,
    /// and by the test that pins this behaviour.
    var isHoldingBackgroundWork: Bool { isHoldingForPlayback }

    private var isHoldingForPlayback: Bool {
        guard let holdUntil else { return false }
        return ContinuousClock.now < holdUntil
    }

    /// Whether a page is currently fetching something the listener asked for.
    ///
    /// Stays true for a moment after the last one finishes: a page load is a
    /// run of requests with small gaps in it, and a fill that restarted in
    /// every gap would be back in the way before the next stage began.
    var isDiggingInForeground: Bool {
        if foregroundDigs > 0 { return true }
        guard let foregroundEndedAt else { return false }
        return ContinuousClock.now - foregroundEndedAt < .milliseconds(750)
    }

    /// Whether anything the listener is currently looking at still wants a
    /// face. These jump the gate; the backlog behind them does not.
    private var hasPortraitsOnScreen: Bool { !portraitPriority.isEmpty }

    /// Marks work as the kind somebody is waiting for.
    private func inForeground<T>(_ body: () async -> T) async -> T {
        foregroundDigs += 1
        defer {
            foregroundDigs -= 1
            if foregroundDigs == 0 { foregroundEndedAt = .now }
        }
        return await body()
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
        // On the worker, not here.
        //
        // This is the whole portrait table, and this store is main-actor
        // isolated, so reading it inline was a full table materialised on the
        // thread that draws — four seconds after launch, every launch, once
        // the window had settled and the listener had started scrolling. The
        // same read is measured at over two hundred milliseconds inside the
        // fold, and nothing here measured it at all.
        let index = await worker.portraitIndex()
        portraits = index.found
        portraitsSettled = index.settled

        // How many background pictures have been stored without telling the
        // page about them.
        var quiet = 0

        while !Task.isCancelled {
            // Nobody is waiting on the backlog, and somebody is waiting on
            // the page.
            //
            // Forty requests a minute out of a budget of sixty, spent on rows
            // that have not been looked at, while a cold artist's nine queue
            // behind them and get throttled. The backlog waits its turn.
            //
            // The names the listener can actually see are a different matter.
            // There are eighteen of them, they are the faces on the rows
            // being read right now, and holding them until every last sleeve
            // and Bandcamp page has landed is how a connection row came to
            // fill in long after the page it is on.
            while isDiggingInForeground, !hasPortraitsOnScreen {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            // And out of the way of a stream that is opening — this one even
            // for the faces on screen, because a picture arriving a moment
            // later costs nothing and a station that times out is gone.
            while isHoldingForPlayback {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            // And out of the way of the minute's last requests, which belong
            // to whatever the listener does next rather than to the backlog.
            //
            // The yields above are about who is waiting; this one is about
            // what is left. They are not the same question — the fill can be
            // the only thing running, with nobody digging and nothing
            // playing, and still be the reason a search two seconds from now
            // is refused. See `DiscogsBudget.reserve`.
            while await !discogsClient.hasRoom(for: .background) {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }

            guard let next = await nextPortraitNeeded() else {
                if quiet > 0 { artworkRevision &+= 1 }
                return
            }
            // Consumed above, so the flag is set there instead.
            let wasOnScreen = lastWasOnScreen
            // The request and the row it becomes both happen on the worker.
            // What comes back is a value, and what is done about it is this
            // loop's business — see `DigWorker.PortraitOutcome`.
            let outcome = await worker.fillPortrait(named: next)
            guard !Task.isCancelled else { return }

            let address: URL
            switch outcome {
            case .cancelled:
                return
            case .refused:
                // Being told to slow down is the one answer this loop must
                // actually obey. Retrying at the usual pace keeps the app over
                // the limit, and it is the page's requests — not these — that
                // are refused alongside them. Nothing was written down, so
                // the name comes round again on the next rebuild.
                try? await Task.sleep(for: .seconds(30))
                continue
            case .unreachable:
                // A dropped connection is not an answer about this artist, so
                // nothing was written and the name is still owed.
                try? await Task.sleep(for: spacing)
                continue
            case .missing:
                // Nothing to show, but a real answer, and one the worker has
                // written down so the name is not asked after again.
                portraitsSettled.insert(RecordingKey.normalizeArtist(next))
                quiet += 1
                try? await Task.sleep(for: spacing)
                continue
            case .found(let found):
                address = found
            }

            // Stays here: these are rows the main context may already hold
            // and be drawing from, and rewriting one column on them is the
            // whole point — see `paint`.
            paint(next, with: address.absoluteString)
            saveContext()

            // Telling the page costs it a full rebuild of its graph, so this
            // is deliberately not done per picture. A name the listener is
            // looking at is worth that immediately; the rest arrive in
            // batches, which is invisible for filling in pictures and four
            // times less work.
            // Only the picture counter. Rows watching it redraw and pick the
            // new address out of `portraits`; nothing is rebuilt.
            let key = RecordingKey.normalizeArtist(next)
            portraits[key] = address
            portraitsSettled.insert(key)
            quiet += 1
            if wasOnScreen || quiet >= 5 {
                quiet = 0
                artworkRevision &+= 1
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
    /// Names already answered for, so one is not asked after twice.
    ///
    /// Seeded from the worker at the start of a run and added to as answers
    /// come back. A refusal or a dropped connection is not an answer and does
    /// not land here — those names come round again.
    @ObservationIgnored private var portraitsSettled: Set<String> = []
    @ObservationIgnored private var portraitQueue: [String] = []
    @ObservationIgnored private var portraitQueueBuiltAt = 0
    /// When the queue was last worked out, as opposed to which revision.
    ///
    /// Rebuilding it reads every artist and every portrait and walks every
    /// neighbour name on every artist — 648ms at the median, over three
    /// seconds at worst — and it happens on the same worker that answers the
    /// page. Keyed on the revision alone, it ran after almost every write,
    /// which during a dig is several times a minute: in the trace it was
    /// running through eleven seconds of time that page walks spent waiting
    /// their turn. The names it would add are not urgent — the ones on screen
    /// jump the queue regardless — so a minute old is new enough.
    @ObservationIgnored private var portraitQueueBuiltWhen: ContinuousClock.Instant?
    private static let portraitQueueLifetime = Duration.seconds(60)

    private func nextPortraitNeeded() async -> String? {
        // The on-screen list is consumed rather than re-searched: each name
        // is checked once and then gone, instead of every name being looked
        // up again on every tick.
        while let next = portraitPriority.first {
            portraitPriority.removeFirst()
            if isPortraitWanted(next) {
                lastWasOnScreen = true
                return next
            }
        }
        lastWasOnScreen = false
        let outOfDate = portraitQueueBuiltAt != revision
            && portraitQueueBuiltWhen.map { ContinuousClock.now - $0 >= Self.portraitQueueLifetime } ?? true
        if portraitQueue.isEmpty || outOfDate {
            portraitQueue = await worker.pendingPortraits()
            portraitQueueBuiltAt = revision
            portraitQueueBuiltWhen = .now
            // Whatever the backend has already found, taken in one request
            // before a single Discogs search is spent on the rest.
            await adoptCataloguePortraits(for: portraitQueue)
        }
        while let next = portraitQueue.first {
            portraitQueue.removeFirst()
            if isPortraitWanted(next) { return next }
        }
        return nil
    }

    /// Portraits the shared catalogue already has, in one request.
    ///
    /// This is the whole return on filling them server-side. The loop below
    /// this used to ask Discogs about every name on its own — forty requests a
    /// minute out of a budget of sixty that every listener draws on — and each
    /// of those requests was made again, identically, on every other machine
    /// running Indigo. Asked here, the work was done once by a cron job and
    /// this costs one Postgres read for the entire queue.
    ///
    /// What the catalogue does not know is left in the queue and looked up the
    /// old way, so a cold catalogue behaves exactly as before rather than
    /// leaving pages blank.
    ///
    /// Bounded because the queue can be thousands of names long on a large
    /// library, and the point is one small request rather than one enormous
    /// one. The rest are picked up on the next rebuild.
    private static let cataloguePortraitBatch = 200

    private func adoptCataloguePortraits(for names: [String]) async {
        guard SupabaseService.isConfigured, !names.isEmpty else { return }

        // The catalogue files names under `RecordingKey.normalize`; this store
        // keys them under `normalizeArtist`. The two disagree about joint
        // credits, so the question goes out in the catalogue's spelling and
        // the answer comes back to the display name it was asked about.
        var byCatalogueKey: [String: String] = [:]
        for name in names.prefix(Self.cataloguePortraitBatch) {
            let key = RecordingKey.normalize(name)
            guard !key.isEmpty, byCatalogueKey[key] == nil else { continue }
            byCatalogueKey[key] = name
        }
        guard !byCatalogueKey.isEmpty else { return }

        guard let found = try? await ArtworkRepository.shared.portraits(
            forArtistKeys: Array(byCatalogueKey.keys)
        ), !found.isEmpty else { return }

        var adopted: [(name: String, address: String)] = []
        var resolved: [String: URL] = [:]
        for (key, url) in found {
            guard let name = byCatalogueKey[key] else { continue }
            adopted.append((name, url.absoluteString))
            resolved[RecordingKey.normalizeArtist(name)] = url
        }
        guard !adopted.isEmpty else { return }

        await worker.adopt(adopted)
        for (key, url) in resolved { portraits[key] = url }
        // One announcement for the batch. See `artworkRevision`.
        artworkRevision &+= 1
    }

    /// Whether this name still owes a picture.
    ///
    /// Read from what the store already holds rather than from the store's
    /// own context, and not only to save a fetch a second: the rows are
    /// written on the worker's context now, so this context would not see
    /// them and every name would look unasked-for.
    private func isPortraitWanted(_ name: String) -> Bool {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return false }
        return portraits[key] == nil && !portraitsSettled.contains(key)
    }

    /// Reads an artist's Bandcamp, when their catalogue entry gives an
    /// address for it.
    ///
    /// Nothing here searches Bandcamp — their robots.txt forbids it — so an
    /// artist whose Discogs entry names no Bandcamp simply has none as far as
    /// Indigo is concerned.
    func enrichBandcamp(forArtist name: String, limit: Int = 8) async {
        guard let page = discogsEnricher.cachedArtist(named: name)?.bandcampURL else { return }
        // Deliberately not reporting progress. This asked the page to redraw
        // as soon as the first record was read and again when the rest were —
        // two rebuilds so one row could appear a second early, at the end of
        // a page that is already whole.
        let enricher = BandcampEnricher(context: context)
        guard let found = try? await enricher.enrich(artist: name, page: page, limit: limit),
              !found.isEmpty
        else { return }
        saveContext()
        forgetGraph(for: .artist(name))
        announceChange()
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
            saveContext()
            announceChange()
        }
    }

    /// Remembers that a recording refused to play, wherever it appears. Called
    /// when the player finds out the hard way, which is the layer certain to
    /// catch an uploader's embedding setting.
    func markUnplayable(_ url: URL) async {
        let address = url.absoluteString
        // Which releases list it is worked out on the worker; only the rows
        // that actually name it are touched here, by id. This used to walk
        // the whole release table on the main actor, and it runs at the one
        // moment a listener is waiting on the transport to do something.
        let listing = await worker.releasesListing(address)
        guard !listing.isEmpty else { return }
        let enricher = discogsEnricher
        var changed = false
        for identifier in listing {
            guard let record = enricher.cachedRelease(id: identifier) else { continue }
            for (index, stored) in record.videoURLStrings.enumerated() where stored == address {
                mark(record, index: index, playable: false)
                changed = true
            }
        }
        guard changed else { return }
        saveContext()
        announceChange()
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

    /// Every write to the app's own context, in one place that can be timed.
    ///
    /// This context is the main one — it has to be, so a crated recording is
    /// the same object the views already hold — which means every save here
    /// happens on the thread that draws. Whether that is where the time goes
    /// was not something the trace could answer, because none of these were
    /// measured.
    private func saveContext() {
        Trace.slowStep("store.save") { try? context.save() }
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
        case .digDiscogsLabel(let name, _):
            return .label(name)
        case .digRelease(let id, let title):
            return .release(title, discogsID: id)
        case .digCatalog(let number):
            return .catalogNumber(number)
        case .digScene(let city, let sound):
            return SceneEngine(context: context).scene(city: city, sound: sound)?.node
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
        announceChange()
    }

    /// One descent, cached against the revision.
    ///
    /// DEEP lives near the bottom of a long page, so a lazy list destroys and
    /// rebuilds it every time it scrolls out of view and back. Without this,
    /// flicking up and down re-walks the graph on each pass, which is exactly
    /// what made scrolling stutter.
    @ObservationIgnored private var descents = DigCache<DeepEngine.Descent>()

    func descent(
        from origin: MusicNode, at level: DeepLevel, showing: Set<String> = []
    ) async -> DeepEngine.Descent {
        let key = Self.descentKey(origin: origin, level: level, showing: showing)
        let asked = revision
        if let fresh = descents.fresh(key, revision: asked) { return fresh }
        settle()
        let found = await worker.descent(
            from: origin, at: level, generation: asked, showing: showing
        )
        descents.store(found, key: key, revision: asked)
        return found
    }

    func cachedDescent(
        from origin: MusicNode, at level: DeepLevel, showing: Set<String> = []
    ) -> DeepEngine.Descent? {
        descents.any(Self.descentKey(origin: origin, level: level, showing: showing))
    }

    /// What the page is already showing is part of the question, so it has to
    /// be part of the key. A descent answered before the release listed its
    /// credits is not the answer to the same page once it has.
    ///
    /// Folded commutatively rather than sorted and joined: this is asked on
    /// every redraw of a page whose exclusion list is every name on a sleeve,
    /// and building that string to hash it would be the kind of per-frame
    /// allocation the rest of this file exists to have removed.
    private static func descentKey(
        origin: MusicNode, level: DeepLevel, showing: Set<String>
    ) -> String {
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in showing {
            digest ^= UInt64(bitPattern: Int64(id.utf8.reduce(5381) { ($0 &* 33) ^ Int($1) }))
        }
        return "\(origin.id)|\(level.rawValue)|\(showing.count)|\(digest)"
    }

    /// What EXPLORE has to offer, kept between visits.
    ///
    /// Held on the store rather than in the view's own state, because a view's
    /// state is gone the moment somebody navigates away — so returning to the
    /// page emptied the block, waited a second on the worker, and filled it in
    /// again. Which reads as a page loading twice, and is the thing that made
    /// it feel slow when nothing about it was.
    private(set) var exploreOffers = ExploreOffers()
    /// Whether the answer on `exploreOffers` is one, rather than the empty
    /// value it starts as.
    ///
    /// The page needs to tell "nothing to suggest" from "not worked out yet",
    /// because the two look identical and should not: an empty block collapses
    /// and everything under it slides up, so the moment the real answer lands
    /// the whole page jumps.
    private(set) var hasExploreOffers = false
    private(set) var hasExploreDirection = false
    @ObservationIgnored private lazy var offersStore = ExploreOffersStore(context: context)

    /// Which of the places somebody could be heading into to show next.
    ///
    /// Kept in defaults rather than in the store: it is a note about what was
    /// last put on screen, not a fact about their music, and it should not be
    /// worth a schema migration. Advanced once per recomputation — which is
    /// about once a launch — so the page says something different each time
    /// without any of it being worked out twice.
    @ObservationIgnored static let directionTurnKey = "explore.direction.turn"

    private static func nextDirectionTurn() -> Int {
        let defaults = UserDefaults.standard
        let turn = defaults.integer(forKey: directionTurnKey)
        defaults.set(turn &+ 1, forKey: directionTurnKey)
        return turn
    }

    /// Reads back what was shown last time, so a launch opens on the page it
    /// closed on rather than on an empty one. Called once, from the app.
    func restoreExploreOffers() {
        guard !hasExploreOffers, let kept = offersStore.load() else { return }
        exploreOffers = kept.offers
        hasExploreOffers = true
        hasExploreDirection = kept.offers.movingToward != nil
        offersCrateRevision = kept.crateRevision
        offersBuiltAt = kept.builtAt
    }
    @ObservationIgnored private var offersCrateRevision = -1
    @ObservationIgnored private var offersBuiltAt = Date.distantPast
    @ObservationIgnored private var offersTask: Task<Void, Never>?

    /// How long an answer stands before it is worth asking again.
    ///
    /// Not tied to `revision`, which is what this used to key on. Enrichment
    /// bumps that several times a second while it works, so keying on it meant
    /// the block was rebuilt on every visit and the cards moved under the
    /// cursor a moment after the page opened. Almost none of those writes
    /// changes what should be suggested.
    @ObservationIgnored private static let offersLifetime: TimeInterval = 15 * 60

    /// Recomputes when the crate has changed, when there is nothing yet, or
    /// when the answer has simply been standing a while. Otherwise does
    /// nothing at all — a set of recommendations that rearranges itself while
    /// somebody is reading it is worse than one that is a quarter of an hour
    /// out of date.
    func refreshExploreOffers(crateRevision: Int) async {
        let isStale = Date().timeIntervalSince(offersBuiltAt) > Self.offersLifetime
        guard offersCrateRevision != crateRevision || exploreOffers.isEmpty || isStale
        else { return }
        offersTask?.cancel()
        let asked = revision
        let task = Task { [weak self] in
            guard let self else { return }
            self.settle()
            // The blocks somebody can act on, published as soon as they are
            // known. Working out a direction reads every place in the
            // catalogue, and the page was making its headline wait behind it.
            let found = await self.worker.exploreRecommendations(generation: asked)
            guard !Task.isCancelled else { return }
            self.offersCrateRevision = crateRevision
            self.offersBuiltAt = Date()
            self.exploreOffers = found
            self.hasExploreOffers = true

            // Then the slower half, folded into what is already on screen.
            let direction = await self.worker.exploreDirection(
                generation: asked, turn: Self.nextDirectionTurn()
            )
            guard !Task.isCancelled else { return }
            var withScene = self.exploreOffers
            withScene.movingToward = direction
            self.exploreOffers = withScene
            self.hasExploreDirection = true
            // Written down only once both halves are in, so a launch never
            // restores an answer that is missing its direction.
            self.offersStore.save(withScene, crateRevision: crateRevision)
        }
        offersTask = task
        await task.value
    }

    /// Everything next to something, of any kind — the step DIG takes.
    func connections(from node: MusicNode) async -> [MusicGraph.Connection] {
        let _ = revision
        settle()
        return await worker.connections(from: node, generation: revision)
    }

    // MARK: - Search

    /// Answers from the two networked catalogues, kept for the session.
    ///
    /// Keyed on the query rather than on a page, and deliberately not
    /// invalidated by `revision`: enrichment writing a row somewhere does not
    /// change what Discogs has under "ilian", and re-asking on every write
    /// would spend a listener's rate limit confirming it.
    @ObservationIgnored private var searches = DigCache<DigSearchResults>()

    /// What this machine already holds, matched against a typed query.
    ///
    /// Off the main thread, and no network: this is the half of a search that
    /// can be drawn immediately, and it is drawn before the other two are
    /// asked. See `DigSearchIndex`.
    func searchYours(_ query: String, limit: Int = 30) async -> [DigSearchResult] {
        guard DigSearchIndex.isSearchable(query) else { return [] }
        let _ = revision
        settle()
        return await worker.searchLocally(query, limit: limit, generation: revision)
    }

    /// Indigo's shared graph and Discogs, asked at the same time.
    ///
    /// Neither is allowed to sink the other: a backend that is not configured
    /// and a search for something nobody has ever filed are each one empty
    /// section on a page whose other sections still work. A refusal is not in
    /// that class and is carried back rather than swallowed — see
    /// `DigSearchResults.discogsRefused`.
    ///
    /// Marked as foreground work. Somebody is watching this, and the
    /// background portrait fill stands aside for as long as it runs; without
    /// that the fill spends the minute's requests on rows nobody has looked at
    /// and the search is refused in a millisecond. That was not a theory — a
    /// trace of a real session showed ninety-seven requests in one minute out
    /// of a budget of sixty, and the searches at the end of it coming back in
    /// three milliseconds each.
    func searchElsewhere(_ query: String, limit: Int = 8) async -> DigSearchResults {
        let key = RecordingKey.normalize(query)
        guard key.count >= DigSearchIndex.shortestQuery else { return .none }
        if let cached = searches.fresh(key, revision: 0) { return cached }

        let found = await inForeground {
            // Our own catalogue first, on its own.
            //
            // These four used to leave together, and asking in parallel saved
            // nothing: the wall time was whichever leg was slowest, and
            // Discogs was asked every time regardless of what we already had.
            // Asked first, a query the catalogue can answer never pays for the
            // other three at all — no request, and none of the half second the
            // backend hop costs. That is the whole return on filing what a
            // search finds; see `normalizeDiscogsSearch`.
            //
            // It also means Discogs traffic follows the number of *distinct
            // unanswered queries* rather than the number of listeners, which
            // is the only version of this that survives more people using it.
            let catalogue = await catalogueSearch(query, limit: limit)
            if DigSearchResult.answers(catalogue, query: query) {
                return DigSearchResults(yours: [], catalogue: catalogue, discogs: [])
            }

            async let artists = discogsSearch(query, kind: .artist, limit: limit)
            async let labels = discogsSearch(query, kind: .label, limit: limit)
            async let releases = discogsSearch(query, kind: .release, limit: limit)

            let byArtist = await artists
            let byLabel = await labels
            let byRelease = await releases

            // Artists and labels ahead of releases: somebody typing a name is
            // usually after a person or an imprint, and Discogs holds an order
            // of magnitude more pressings than either.
            return DigSearchResults(
                yours: [],
                catalogue: catalogue,
                discogs: byArtist.rows + byLabel.rows + byRelease.rows,
                discogsRefused: byArtist.refused || byLabel.refused || byRelease.refused
            )
        }

        // A refusal is not an answer, and caching one makes it permanent: the
        // same query would return the same nothing for the rest of the
        // session, however quiet Discogs had since become.
        if !found.discogsRefused { searches.store(found, key: key, revision: 0) }
        return found
    }

    private func catalogueSearch(_ query: String, limit: Int) async -> [DigSearchResult] {
        guard SupabaseService.isConfigured else { return [] }
        guard let results = try? await SearchRepository.shared.search(query, limit: limit)
        else { return [] }
        return DigSearchResult.rows(from: results)
    }

    /// One kind, and whether Discogs would answer at all.
    private func discogsSearch(
        _ query: String, kind: DiscogsSearchKind, limit: Int
    ) async -> (rows: [DigSearchResult], refused: Bool) {
        guard discogsClient.isConfigured else { return ([], false) }
        // Asked before spending anything. A request sent into an empty budget
        // comes back refused in a millisecond, and the page then has to guess
        // what that meant; knowing in advance is both quicker and clearer.
        //
        // `canSearch` rather than `hasRoom`: a search that goes to the backend
        // spends none of this app's budget. See `DiscogsClient.canSearch`.
        guard await discogsClient.canSearch() else { return ([], true) }
        do {
            let results = try await discogsClient.search(query, kind: kind, limit: limit)
            return (DigSearchResult.rows(fromDiscogs: results, kind: kind), false)
        } catch DiscogsError.rateLimited {
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    /// Where this listener has not been, worked out off the main thread.
    func digSuggestions(limit: Int = 6) async -> [DigHistory.Suggestion] {
        let _ = revision
        settle()
        return await worker.digSuggestions(limit: limit, generation: revision)
    }

    func scenes(forArtist name: String) async -> [MusicScene] {
        let _ = revision
        settle()
        // Traced because it was not, and an artist page was waiting on it for
        // over half a second before asking Discogs anything — visible in the
        // trace only as a gap with nothing in it.
        let asked = revision
        let worker = worker
        return await Trace.stage("dig.scenes", name) {
            await worker.scenes(forArtist: name, generation: asked)
        }
    }

    func scene(city: String, sound: String?) async -> MusicScene? {
        let _ = revision
        settle()
        return await worker.scene(city: city, sound: sound, generation: revision)
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
                saveContext()
                announceChange()
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
                saveContext()
                announceChange()
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
        if recording.recreditFromTitle() { saveContext() }

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
            if metadata.labelName == nil { metadata.labelName = release.imprint }
            if metadata.releaseDate == nil { metadata.releaseDate = release.year }
            if recording.albumTitle?.isEmpty ?? true { recording.albumTitle = release.title }
        }
        // Deliberately the release sleeve, never the radio-show image or the
        // artist portrait: this is a picture of the record, not of the hour it
        // was played in.
        if let cover, metadata.artworkURLString == nil {
            metadata.artworkURLString = cover.absoluteString
        }

        saveContext()
        announceChange()
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

        saveContext()
        announceChange()
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
        //
        // Measured because a tracklist asks this once a row, on the main
        // actor, and a row that misses walks the release table.
        let artwork = metadata.artworkURL ?? metadata.releaseTitle.flatMap { title in
            Trace.slowStep("row.artwork", title) {
                DigArtwork(context: context).release(title: title, artist: recording.artistName).full
            }
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
            saveContext()
            announceChange()
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
        // Only the tracks this can actually change. Asking for the library
        // and skipping most of it in the loop meant every cold artist read
        // every file the listener owns, on the main actor, and normalised a
        // credit for each one — which is the part of opening somebody new
        // that had nothing to do with the network.
        // `$0.genre.isEmpty` compiles and works in memory, and answers with
        // nothing at all against SQLite. See `StorePredicateTests`.
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.genre == "" })
        for track in (try? context.fetch(descriptor)) ?? []
        where DigEngine.artistKeys(for: track).contains(key) {
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
        let paths = recording.sources.filter { $0.kind == .localFile }.map(\.identifier)
        guard !paths.isEmpty else { return }
        let metadata = engine.metadata(for: recording.id)
        // By path, which is the unique attribute: the handful of rows this
        // recording actually sits on, rather than the whole library filtered
        // down to them afterwards.
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { paths.contains($0.path) })
        for track in (try? context.fetch(descriptor)) ?? [] {
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
        // A number for the whole of it, to hold the parts against.
        //
        // This target is built with `SWIFT_APPROACHABLE_CONCURRENCY`, so a
        // `nonisolated` async function runs on its caller's actor — and this
        // store is the main one. Everything below therefore happens on the
        // thread that draws, apart from the awaits themselves, and only the
        // pieces that were named are measured. If this total is far larger
        // than the pieces inside it, the difference is where to look next.
        await Trace.stage("dig.enrich", name) {
            await inForeground { await digArtist(name: name, mbid: mbid) }
        }
    }

    /// How long work a page can live without waits for room in the minute
    /// before giving up. Settable for the test that has to watch it give up.
    @ObservationIgnored var budgetPatience: Duration = .seconds(10)

    /// Room in the minute's budget for work a page can live without, or false
    /// once patience runs out or the page has gone.
    ///
    /// A new artist costs thirty or forty requests between the lookup, the
    /// neighbourhood, a batch of records and the portraits on its rows, and the
    /// minute holds sixty for every copy of the app. Opening a few in a row ran
    /// the session to sixty-seven a minute, and the artist after that had its
    /// own lookup refused three times over and came back with nothing at all.
    /// The lookup is what the page cannot do without, so it never waits. What
    /// follows it does, down to the same reserve the background fill keeps.
    private func waitForRoom() async -> Bool {
        let deadline = ContinuousClock.now + budgetPatience
        while await !discogsClient.hasRoom(for: .background) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !Task.isCancelled
    }

    /// An artist's Discogs entry in the two writes it arrives in, rather than
    /// the one it used to be held for.
    ///
    /// `artists/{id}` and `artists/{id}/releases` leave together, and the page
    /// waited for both — so it waited on the shelf: 442ms at the median in the
    /// trace against 199ms for the entry, and over a second in the slowest
    /// twentieth. The entry is written as soon as it lands, and the page lifts
    /// its head once there is a profile to read.
    ///
    /// Both announcements go through the usual window, so a quick shelf folds
    /// into one redraw and the reveal lands exactly when it did before.
    ///
    /// The shelf's was briefly announced at once, to cut the window out of the
    /// reveal, and that was wrong. A read arriving while a walk of the same
    /// artist is under way joins it rather than starting a second one — see
    /// `ProfileWalkTests` — and the walk under way at that moment had read its
    /// tables before the shelf was written. So the page revealed a profile of
    /// the artist as they were a moment earlier: the trace showed Ellessar's
    /// reveal joining a walk begun before the shelf landed.
    ///
    /// No save between the two. The page reads through `artistProfile`, which
    /// settles the context before it asks the worker anything, so saving here
    /// would be a second save on the main thread for the same rows.
    private func describeArtist(named name: String, head: DiscogsSearchResult) async throws -> DiscogsArtist? {
        if let fresh = discogsEnricher.freshArtist(named: name) { return fresh }
        guard let id = head.id else { return nil }
        let client = discogsClient
        async let detail = client.artistDetail(id: id)
        async let shelf = client.artistShelf(named: name, id: id)

        let described = try await detail
        discogsEnricher.artistDetail(named: name, head: head, detail: described)
        announceChange()

        let found = try await shelf
        return discogsEnricher.artist(named: name, bundle: DiscogsArtistBundle(
            detail: described,
            releases: found.releases,
            searchImageURL: head.coverImage,
            searchThumbnailURL: head.thumbnail,
            catalogue: found.catalogue
        ))
    }

    private func digArtist(name: String, mbid: String?) async {
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
                // Their name and their picture, one round trip in.
                //
                // The bundle is two round trips: a search to find them, then
                // their detail, discography and catalogue together. Nothing
                // was drawn until both had landed, so the portrait arrived
                // twice as late as it needed to. The search already carries
                // it — so it is written and the page told, and the rest fills
                // in around a page that is already the right shape.
                let head = try await discogsClient.artistHead(named: name)
                if let head {
                    discogsEnricher.artistIdentity(named: name, head: head)
                    saveContext()
                    announceChange()
                }

                if let head, let artist = try await describeArtist(named: name, head: head) {
                    saveContext()
                    // What the graph knew about this artist was worked out
                    // from the catalogue entry that has just been replaced.
                    forgetGraph(for: .artist(name))
                    backfillLocalGenres(artistName: name, genres: artist.styles + artist.genres)
                    announceChange()
                    isEnriching = false
                    let previews = artist.releaseThumbnailURLStrings.compactMap(URL.init(string:))
                    Task.detached(priority: .utility) {
                        await RemoteArtworkStore.shared.prefetch(Array(previews.prefix(12)))
                    }
                    // Recommendations arrive as a quiet second stage: the
                    // page and sleeves are already usable while this fills in.
                    // Five searches, and only with room left in the minute —
                    // see `waitForRoom()`.
                    do {
                        if await waitForRoom() {
                            try await discogsEnricher.recommendations(for: artist)
                            saveContext()
                            announceChange()
                        }
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
            saveContext()
            announceChange()
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
            saveContext()
            announceChange()
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
            saveContext()
            announceChange()
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
            saveContext()
            announceChange()
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
            saveContext()
            announceChange()
            return id
        } catch {
            return nil
        }
    }

    func enrichDiscogsLabel(named name: String, discogsID: Int? = nil) async {
        // Asked for by identity where a record named one. Two labels can
        // share a name, and a search on the name opens whichever Discogs
        // ranks first — which is how a page for Dean Blunt's World Music
        // showed a 1995 catalogue of country-dance compilations.
        if let discogsID {
            let key = "discogs \(discogsID)"
            guard discogsLabelProfiles[key] == nil else { return }
            isEnriching = true
            defer { isEnriching = false }
            if let catalogue = try? await discogsClient.labelCatalogue(id: discogsID),
               !catalogue.isEmpty {
                discogsLabelProfiles[key] = DiscogsLabelProfile(name: name, catalogue: catalogue)
                let previews = catalogue.compactMap {
                    DiscogsClient.usableImage($0.thumbnail).flatMap(URL.init(string:))
                }
                Task.detached(priority: .utility) {
                    await RemoteArtworkStore.shared.prefetch(Array(previews.prefix(16)))
                }
                return
            }
            // Falling back to the name is worse than asking by id and better
            // than an empty page, so it says nothing and lets the search try.
        }
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
            saveContext()
            announceChange()
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
