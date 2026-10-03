//
//  CrateService.swift
//  Indigo
//
//  Crating has to be instant and unconditional — one press, no modal, no
//  playlist picker, no account. This owns that promise, and nothing else.
//

import Foundation
import Observation
import SwiftData

@Observable
final class CrateService {
    /// Bumped on every change so views observing the service re-read their
    /// @Query results and the button flips to CRATED without a round trip.
    private(set) var revision = 0
    var notice: String?

    /// Shares the app's main context deliberately: a crated recording has to
    /// be the same object the views already hold, not a copy fetched into a
    /// private context that SwiftData would refuse to relate across.
    @ObservationIgnored let context: ModelContext

    /// False while the listener's store could not be opened. Every write below
    /// refuses and says why, so nothing is "crated" into a session that will
    /// not keep it.
    @ObservationIgnored private let writable: Bool

    init(context: ModelContext, writable: Bool = Persistence.userDataWritable) {
        self.context = context
        self.writable = writable
    }

    /// True, after saying so, when the crate cannot be written to.
    private func refusesWrites() -> Bool {
        // A newer build's generation can arrive after this was made.
        guard !writable || Persistence.newerGeneration != nil else { return false }
        notice = writable ? SyncGeneration.notice : Persistence.userDataUnavailableNotice
        return true
    }

    /// Deallocating a main-actor-isolated observable hops to the executor to
    /// run its deinit, and that hop aborts the process. The app never sees it
    /// — this service lives as long as the window — but anything that creates
    /// one and lets it go takes the whole test host down with it. Nothing
    /// here needs the main actor to be torn down.
    nonisolated deinit {}

    // MARK: - Reading

    func items() -> [CrateItem] {
        let descriptor = FetchDescriptor<CrateItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    var count: Int {
        (try? context.fetchCount(FetchDescriptor<CrateItem>())) ?? 0
    }

    func contains(recording: Recording) -> Bool {
        refreshMembershipIfNeeded()
        return recordingMembership.contains(
            CrateSnapshot.identity(matchKey: recording.matchKey, unknownCode: recording.unknownCode))
    }

    func contains(broadcast showID: String, providerID: String) -> Bool {
        item(forBroadcast: showID, providerID: providerID) != nil
    }

    /// The row for a recording: by its match key, or by its code when nobody
    /// named it. The same key on every device, which a local `Recording.id`
    /// was not.
    func item(for recording: Recording) -> CrateItem? {
        item(matchKey: recording.matchKey, unknownCode: recording.unknownCode)
    }

    func item(matchKey: String, unknownCode: String?) -> CrateItem? {
        let identity = RecordingIdentity(matchKey: matchKey, unknownCode: unknownCode)
        guard !identity.isEmpty else { return nil }
        // The row a merge would keep, so the answer is the same before and
        // after one runs.
        return UserDataDedupe.survivor(
            ofCrate: UserDataDedupe(context: context).rows(forCrateKey: .recording(identity)))
    }

    /// Only a broadcast row. A recording row carries the broadcast it was heard
    /// in under the same `providerID` and `showID`, and crating that show must
    /// not find the track and call the show kept.
    func item(forBroadcast showID: String, providerID: String) -> CrateItem? {
        UserDataDedupe.survivor(ofCrate: UserDataDedupe(context: context).rows(
            forCrateKey: .broadcast(providerID: providerID, showID: showID)))
    }

    func item(forDig kind: CrateItemKind, identifier: String, providerID: String) -> CrateItem? {
        UserDataDedupe.survivor(ofCrate: UserDataDedupe(context: context).rows(
            forCrateKey: .dig(kind: kind.rawValue, providerID: providerID, entityID: identifier)))
    }

    // MARK: - Membership, held in memory

    /// Whether something is in the crate, without going to the store.
    ///
    /// Views ask this from `body` — the CRATE button on every dig page, and
    /// once per row in a Listen list — and `body` runs on every redraw, which
    /// during a scroll is every frame. Answering it by fetching the whole
    /// crate table, sorted, measured at 10.5ms against a frame budget of
    /// 16.7. One button could not fit in a frame, so the scroll caught.
    ///
    /// The crate is small and changes only when somebody presses the button,
    /// so it is folded into two sets and kept until `revision` moves.
    @ObservationIgnored private var membershipAt = -1
    @ObservationIgnored private var digMembership: Set<String> = []
    @ObservationIgnored private var recordingMembership: Set<String> = []
    @ObservationIgnored private var listeningMembership: [URL: Bool] = [:]

    private static func digKey(
        _ kind: CrateItemKind, _ identifier: String, _ providerID: String
    ) -> String {
        "\(kind.rawValue)|\(providerID)|\(identifier)"
    }

    /// Reading `revision` here is deliberate: it is what makes a view asking
    /// about membership re-read when the crate changes.
    func refreshMembershipIfNeeded() {
        guard membershipAt != revision else { return }
        var dig: Set<String> = []
        var recordings: Set<String> = []
        for item in items() {
            if item.kind == .recording {
                if item.hasRecordingSnapshot { recordings.insert(item.recordingIdentity) }
                continue
            }
            if let showID = item.showID, let providerID = item.providerID {
                dig.insert(Self.digKey(item.kind, showID, providerID))
            }
        }
        digMembership = dig
        recordingMembership = recordings
        listeningMembership = [:]
        membershipAt = revision
    }

    func contains(dig kind: CrateItemKind, identifier: String, providerID: String) -> Bool {
        refreshMembershipIfNeeded()
        return digMembership.contains(Self.digKey(kind, identifier, providerID))
    }

    /// Remembered per address, because a Listen list asks about a dozen of
    /// them on every redraw and each one was two fetches.
    func rememberListening(_ url: URL, isCrated: Bool) {
        listeningMembership[url] = isCrated
    }

    func knownListening(_ url: URL) -> Bool? {
        refreshMembershipIfNeeded()
        return listeningMembership[url]
    }

    // MARK: - Row cache

    /// Where each row can be played from, and where its DIG button goes.
    ///
    /// Both read the store, so they are worked out when the crate changes
    /// rather than while it is being drawn — and they live here rather than in
    /// the view, because a view's state is discarded the moment somebody
    /// navigates away. Held there, every return to the crate drew the whole
    /// list unresolved and then resolved it a moment later, which is the
    /// reshuffle you could see on the way in.
    private(set) var resolvedSources: [UUID: AudioSource] = [:]
    private(set) var digDestinations: [UUID: DetailPage] = [:]
    /// False only before the first pass has ever run. A row is playable until
    /// proven otherwise, so that a list drawn before the answers arrive does
    /// not tell somebody their music cannot be played.
    private(set) var hasResolvedRows = false
    @ObservationIgnored private var resolvedRevision = -1
    @ObservationIgnored private var resolvedDigRevision = -1

    /// Recomputes the row cache when something it depends on has moved.
    ///
    /// `digDestination` is passed in rather than reached for: the crate has no
    /// business knowing what DIG is, and this is the one thing on a row that
    /// DIG decides.
    func refreshRowCache(
        digRevision: Int, digDestination: (Recording) -> DetailPage?
    ) {
        guard !hasResolvedRows
                || resolvedRevision != revision
                || resolvedDigRevision != digRevision
        else { return }
        var sources: [UUID: AudioSource] = [:]
        var pages: [UUID: DetailPage] = [:]
        let resolver = SourceResolver(context: context)
        let rows = items()
        // Looked up, never made. The crate is the listener's data and displays
        // from what each row kept; the recordings are a cache beside it, which
        // can be empty -- on a new device, or after it is thrown away -- and
        // viewing the crate does not fill it. A row with no recording here has
        // no DIG page on the row until something opens it, which makes one.
        let found = CrateRecordings(context: context).recordings(for: rows)
        for item in rows {
            if let source = resolver.best(item) { sources[item.id] = source }
            if let recording = found[item.id], let page = digDestination(recording) {
                pages[item.id] = page
            }
        }
        resolvedSources = sources
        digDestinations = pages
        resolvedRevision = revision
        resolvedDigRevision = digRevision
        hasResolvedRows = true
    }

    // MARK: - Playing

    /// Plays a crate row with the rest of the crate queued around it, so next
    /// and previous move through what was kept — from the crate page and
    /// from the mini player alike.
    ///
    /// `media` is what the row resolved to at the press. The rest come from
    /// the row cache, in the order the crate lists them; a row with nothing
    /// to play yet is simply not in the queue.
    func play(_ item: CrateItem, as media: MediaItem, on player: PlaybackCoordinator) {
        if player.isCurrent(media.id) {
            player.toggle()
            return
        }
        var queue: [MediaItem] = []
        var index = 0
        for row in items() {
            if row.id == item.id {
                index = queue.count
                queue.append(media)
            } else if case .play(let other) = resolvedSources[row.id]?.action {
                queue.append(other)
            }
        }
        if queue.isEmpty { queue = [media] }
        player.play(queue, startingAt: index)
    }

    // MARK: - Writing

    /// Crating the same thing twice is a no-op rather than a duplicate — the
    /// button is a toggle everywhere it appears.
    @discardableResult
    func add(recording: Recording) -> CrateItem? {
        if refusesWrites() { return nil }
        if let existing = item(for: recording) { return existing }
        let item = CrateItem(snapshot: CrateSnapshot.capture(recording, context: context))
        item.setGenres(localGenres(for: recording))
        context.insert(item)
        note(item)
        save()
        return item
    }

    /// Writes a save into the listening log.
    ///
    /// Keeping something is the strongest thing a listener says without
    /// typing, and it is the one signal that would otherwise be invisible to
    /// the log: crating a record takes a second, so it never accumulates
    /// enough playing time to count as listening. Only additions are noted —
    /// taking a row back out of the crate is a correction, not a verdict, and
    /// reading it as one would punish people for tidying up.
    private func note(_ item: CrateItem) {
        guard let node = item.node(resolving: CrateRecordings(context: context).recording(for: item))
        else { return }
        ListeningLog(context: context).record(
            node, action: .saved, tags: item.genreTags,
            source: item.providerID.map { ListeningSource(providerID: $0, showTitle: item.showTitle) }
        )
    }

    /// Writes down a broadcast's real id once something has worked it out.
    ///
    /// Radio 80000's live feed names what is on and gives no identifier, so a
    /// show kept off the air can only be found again by searching the show
    /// catalogue for its name — two requests before the page can open. Doing
    /// that on every press is a slow row forever; doing it once and keeping
    /// the answer is a slow row once.
    ///
    /// Refuses to write an id another row already holds. The two would be the
    /// same broadcast kept twice, and quietly turning one into a duplicate of
    /// the other is worse than leaving it to be looked up again.
    @discardableResult
    func remember(showID: String, for item: CrateItem) -> Bool {
        if refusesWrites() { return false }
        guard let providerID = item.providerID, item.showID != showID else { return false }
        guard self.item(forBroadcast: showID, providerID: providerID) == nil else { return false }
        item.showID = showID
        save()
        return true
    }

    @discardableResult
    func add(
        broadcast showID: String,
        providerID: String,
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        playbackURL: URL?,
        embedProvider: EmbedProvider?,
        isLiveStream: Bool = false,
        genres: [String] = []
    ) -> CrateItem? {
        if refusesWrites() { return nil }
        if let existing = item(forBroadcast: showID, providerID: providerID) { return existing }
        let item = CrateItem(
            providerID: providerID,
            showID: showID,
            showTitle: title,
            showSubtitle: subtitle,
            artworkURL: artworkURL,
            playbackURL: playbackURL,
            embedProvider: embedProvider,
            isLiveStream: isLiveStream,
            genres: genres
        )
        context.insert(item)
        note(item)
        save()
        return item
    }

    @discardableResult
    func add(
        dig kind: CrateItemKind,
        identifier: String,
        providerID: String,
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        genres: [String] = []
    ) -> CrateItem? {
        if refusesWrites() { return nil }
        if let existing = item(forDig: kind, identifier: identifier, providerID: providerID) { return existing }
        let item = CrateItem(
            digKind: kind, providerID: providerID, entityID: identifier,
            title: title, subtitle: subtitle, artworkURL: artworkURL, genres: genres
        )
        context.insert(item)
        note(item)
        save()
        return item
    }

    func toggle(
        dig kind: CrateItemKind,
        identifier: String,
        providerID: String,
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        genres: [String] = []
    ) {
        if let existing = item(forDig: kind, identifier: identifier, providerID: providerID) {
            remove(existing)
        } else {
            add(
                dig: kind, identifier: identifier, providerID: providerID,
                title: title, subtitle: subtitle, artworkURL: artworkURL, genres: genres
            )
        }
    }

    /// Takes the thing out of the crate: every row for it. Two devices that
    /// each kept the same record made two rows, and removing one would leave the
    /// other saying it is still kept.
    func remove(_ item: CrateItem) {
        if refusesWrites() { return }
        if let key = UserDataDedupe.key(of: item) {
            for row in UserDataDedupe(context: context).rows(forCrateKey: key) { context.delete(row) }
        }
        if !item.isDeleted { context.delete(item) }
        save()
    }

    func toggle(recording: Recording) {
        if let existing = item(for: recording) {
            remove(existing)
        } else {
            add(recording: recording)
        }
    }

    // MARK: - Grouping

    /// Newest first, bucketed by the day it was crated.
    struct Day: Identifiable {
        let date: Date
        let items: [CrateItem]
        var id: Date { date }

        var label: String {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let formatter = DateFormatter()
            formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .year)
                ? "EEEE d MMMM"
                : "d MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    func days() -> [Day] {
        let grouped = Dictionary(grouping: items(), by: \.addedDay)
        return grouped
            .map { Day(date: $0.key, items: $0.value.sorted { $0.addedAt > $1.addedAt }) }
            .sorted { $0.date > $1.date }
    }

    /// Genre persistence was added after the crate shipped. Recover tags for
    /// existing local entries from their indexed files instead of requiring
    /// listeners to remove and re-crate their library.
    ///
    /// One query for the whole backfill, because the For You page runs this
    /// from a `.task` — which is the main actor, a moment after the page
    /// appears. It used to ask for every `Track` in the library once per
    /// crated entry and filter the answer in memory: with twelve thousand
    /// tracks and a hundred and twenty entries that measured two minutes of
    /// stopped main thread, and on any real library it is the hitch that
    /// pauses the shader a few seconds in.
    func backfillLocalGenres() {
        let all = items()
        let found = CrateRecordings(context: context).recordings(for: all)
        let pending = all.compactMap { item -> (item: CrateItem, paths: [String])? in
            guard item.genreTags.isEmpty, let recording = found[item.id] else { return nil }
            let paths = localPaths(of: recording)
            return paths.isEmpty ? nil : (item, paths)
        }
        guard !pending.isEmpty else { return }

        let genreByPath = genres(atPaths: Array(Set(pending.flatMap(\.paths))))
        var changed = false
        for entry in pending {
            let genres = GenreTags.available(in: entry.paths.compactMap { genreByPath[$0] })
            guard !genres.isEmpty else { continue }
            entry.item.setGenres(genres)
            changed = true
        }
        if changed { save() }
    }

    func updateGenres(_ genres: [String], for item: CrateItem) {
        let clean = GenreTags.available(in: genres)
        guard !clean.isEmpty, clean != item.genreTags else { return }
        item.setGenres(clean)
        save()
    }

    /// Only where the row has no usable picture of its own — a found one
    /// never replaces what the listener kept.
    func fillArtwork(_ url: URL, for item: CrateItem) {
        guard item.artworkURL == nil else { return }
        item.artworkURLString = url.absoluteString
        save()
    }

    func updateArchivedBroadcast(_ item: CrateItem, from media: MediaItem) {
        guard item.kind == .broadcast, !media.isLive else { return }
        var changed = false
        if item.playbackURLString != media.playbackURL.absoluteString {
            item.playbackURLString = media.playbackURL.absoluteString
            changed = true
        }
        if item.embedProviderRaw != media.embedProvider?.rawValue {
            item.embedProviderRaw = media.embedProvider?.rawValue
            changed = true
        }
        if item.artworkURLString == nil, let artwork = media.remoteArtworkURL?.absoluteString {
            item.artworkURLString = artwork
            changed = true
        }
        if !media.genres.isEmpty, item.genreTags != GenreTags.available(in: media.genres) {
            item.setGenres(media.genres)
            changed = true
        }
        if item.isLiveStream {
            item.isLiveStream = false
            changed = true
        }
        if changed { save() }
    }

    /// Points a kept live broadcast at the recording, once The Lot has one.
    ///
    /// Keeping a show while it is on air stores the station: `lot.live`, with
    /// the on-air title, and the live HLS address as its playback. None of
    /// that survives the show ending. The title names something no longer
    /// broadcasting, the address plays whatever is on now, and the row opens
    /// the shows directory because `lot.live` is not an episode handle.
    ///
    /// The same repair `migrateLegacyNTSBroadcast` does, on the same terms —
    /// including dropping the live address even when there is no archive audio
    /// yet. Playing nothing is better than playing a different show under the
    /// name of the one that was kept.
    func migrateLotLiveBroadcast(_ item: CrateItem, ref: LotEpisodeRef, media: MediaItem?) {
        guard item.kind == .broadcast, item.providerID == LotProvider.providerID else { return }
        item.showID = "lot.episode.\(ref.encoded)"
        item.isLiveStream = false
        item.playbackURLString = nil
        item.embedProviderRaw = nil
        if let media {
            item.playbackURLString = media.playbackURL.absoluteString
            item.embedProviderRaw = media.embedProvider?.rawValue
            if let artwork = media.remoteArtworkURL?.absoluteString {
                item.artworkURLString = artwork
            }
            if !media.genres.isEmpty { item.setGenres(media.genres) }
            // The billing the listener kept is what they will recognise, so
            // the title is left as it is. Only the subtitle moves: it was
            // holding the station's name to mark this as a live snapshot, and
            // now that the row points at a broadcast it can say when.
            if let subtitle = media.subtitle, !subtitle.isEmpty {
                item.showSubtitle = subtitle
            }
        }
        mergeDuplicates(of: item)
        save()
    }

    func migrateLegacyNTSBroadcast(_ item: CrateItem, ref: NTSEpisodeRef, media: MediaItem?) {
        guard item.kind == .broadcast, item.providerID == NTSProvider.providerID else { return }
        item.showID = "nts.episode.\(ref.show)/\(ref.episode)"
        item.isLiveStream = false
        // Remove the old station stream even if NTS has not published archive
        // audio yet. Playing nothing is better than playing a different show.
        item.playbackURLString = nil
        item.embedProviderRaw = nil
        if let media {
            item.playbackURLString = media.playbackURL.absoluteString
            item.embedProviderRaw = media.embedProvider?.rawValue
            item.artworkURLString = media.remoteArtworkURL?.absoluteString ?? item.artworkURLString
            item.setGenres(media.genres)
        }
        mergeDuplicates(of: item)
        save()
    }

    /// A repair that rewrites a row's `showID` can land it on one that is
    /// already there. They are one kept thing, so they are merged now, not left
    /// for the next pass to find.
    private func mergeDuplicates(of item: CrateItem) {
        guard let key = UserDataDedupe.key(of: item) else { return }
        UserDataDedupe(context: context).crate(key: key)
    }

    private func localGenres(for recording: Recording) -> [String] {
        let paths = localPaths(of: recording)
        guard !paths.isEmpty else { return [] }
        let genreByPath = genres(atPaths: paths)
        return GenreTags.available(in: paths.compactMap { genreByPath[$0] })
    }

    /// Where this recording sits in the indexed library, if it does.
    private func localPaths(of recording: Recording) -> [String] {
        recording.sources.filter { $0.kind == .localFile }.map(\.identifier)
    }

    /// What the library calls these files, asked for by path.
    ///
    /// `path` is the unique attribute on `Track`, so the store answers this
    /// from its index and materialises only the rows asked about — where
    /// fetching the library and filtering it in memory materialises all of
    /// it, on whichever actor the caller happens to be.
    private func genres(atPaths paths: [String]) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { paths.contains($0.path) })
        let found = (try? context.fetch(descriptor)) ?? []
        return Dictionary(found.map { ($0.path, $0.genre) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Persistence

    func save() {
        do {
            try context.save()
            revision &+= 1
        } catch {
            // The crate is the one thing in the app that isn't a rebuildable
            // cache, so a failed write is worth telling the listener about.
            notice = "Couldn't save to your crate. \(error.localizedDescription)"
        }
    }
}
