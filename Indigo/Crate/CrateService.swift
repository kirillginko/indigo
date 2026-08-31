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
        item(for: recording) != nil
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

    func contains(dig kind: CrateItemKind, identifier: String, providerID: String) -> Bool {
        item(forDig: kind, identifier: identifier, providerID: providerID) != nil
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
        save()
        return item
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
    func backfillLocalGenres() {
        var changed = false
        for item in items() where item.genreTags.isEmpty {
            guard let recording = item.recording else { continue }
            let genres = localGenres(for: recording)
            guard !genres.isEmpty else { continue }
            item.setGenres(genres)
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
        let paths = Set(recording.sources.filter { $0.kind == .localFile }.map(\.identifier))
        guard !paths.isEmpty else { return [] }
        return GenreTags.available(in: ((try? context.fetch(FetchDescriptor<Track>())) ?? [])
            .filter { paths.contains($0.path) }
            .map(\.genre))
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
