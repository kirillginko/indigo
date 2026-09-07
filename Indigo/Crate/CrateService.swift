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

    init(context: ModelContext) {
        self.context = context
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
        return recordingMembership.contains(recording.id)
    }

    func contains(broadcast showID: String, providerID: String) -> Bool {
        item(forBroadcast: showID, providerID: providerID) != nil
    }

    func item(for recording: Recording) -> CrateItem? {
        let id = recording.id
        var descriptor = FetchDescriptor<CrateItem>(
            predicate: #Predicate { $0.recording?.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func item(forBroadcast showID: String, providerID: String) -> CrateItem? {
        var descriptor = FetchDescriptor<CrateItem>(
            predicate: #Predicate { $0.showID == showID && $0.providerID == providerID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func item(forDig kind: CrateItemKind, identifier: String, providerID: String) -> CrateItem? {
        items().first { $0.kind == kind && $0.showID == identifier && $0.providerID == providerID }
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
    @ObservationIgnored private var recordingMembership: Set<UUID> = []
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
        var recordings: Set<UUID> = []
        for item in items() {
            if let showID = item.showID, let providerID = item.providerID {
                dig.insert(Self.digKey(item.kind, showID, providerID))
            }
            if let id = item.recording?.id { recordings.insert(id) }
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
        for item in items() {
            if let found = resolver.best(item) { sources[item.id] = found }
            if let recording = item.recording, let page = digDestination(recording) {
                pages[item.id] = page
            }
        }
        resolvedSources = sources
        digDestinations = pages
        resolvedRevision = revision
        resolvedDigRevision = digRevision
        hasResolvedRows = true
    }

    // MARK: - Writing

    /// Crating the same thing twice is a no-op rather than a duplicate — the
    /// button is a toggle everywhere it appears.
    @discardableResult
    func add(recording: Recording) -> CrateItem {
        if let existing = item(for: recording) { return existing }
        let item = CrateItem(recording: recording)
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
        guard let node = item.node else { return }
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
    ) -> CrateItem {
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
    ) -> CrateItem {
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

    func remove(_ item: CrateItem) {
        context.delete(item)
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
        let pending = items().compactMap { item -> (item: CrateItem, paths: [String])? in
            guard item.genreTags.isEmpty, let recording = item.recording else { return nil }
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
        save()
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
