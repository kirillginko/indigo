//
//  KioskProvider.swift
//  Indigo
//
//  Kiosk Radio broadcasts 24/7 from a wooden kiosk in Brussels' Parc Royal.
//  One channel, one Icecast stream, and a published calendar this reads to
//  work out what is on air.
//

import Foundation
import Observation

@Observable
final class KioskProvider: RadioProvider {
    nonisolated static let providerID = "kiosk"
    let displayName = "Kiosk Radio"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let stations: [RadioStation] = [
        RadioStation(
            id: "kiosk.live",
            providerID: KioskProvider.providerID,
            name: "Kiosk Radio",
            shortName: "Kiosk",
            strapline: "Brussels",
            streamURL: URL(string: "https://kioskradiobxl.out.airtime.pro/kioskradiobxl_b")!
        )
    ]

    var station: RadioStation { stations[0] }

    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?
    private(set) var schedule: [KioskScheduleEntry] = []
    /// Artwork for a residency, keyed by show name. Kiosk's calendar carries
    /// no images, so these are looked up once per show and kept.
    private(set) var showArtwork: [String: URL] = [:]

    /// Now / next are derived from the clock, and @Observable only notices
    /// stored state — so the poll stamps the moment the schedule was read and
    /// everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = KioskAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    /// Show names already looked up, successfully or not, so a residency with
    /// no photo isn't re-queried every poll.
    @ObservationIgnored private var resolvedArtworkNames: Set<String> = []

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lookup

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    var onAir: KioskScheduleEntry? {
        schedule.first { $0.contains(referenceDate) }
    }

    var upNext: KioskScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on, for the schedule list.
    var upcoming: [KioskScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    func artwork(for entry: KioskScheduleEntry) -> URL? {
        showArtwork[entry.showName.lowercased()]
    }

    var now: RadioShow? {
        onAir.map { $0.asRadioShow(artworkURL: artwork(for: $0)) }
    }

    var next: RadioShow? {
        upNext.map { $0.asRadioShow(artworkURL: artwork(for: $0)) }
    }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir?.title ?? "Live",
            detail: station.strapline,
            remoteArtworkURL: onAir.flatMap { artwork(for: $0) },
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    /// The station page and active Kiosk playback call this to poll faster.
    func beginWatching() {
        watchers += 1
        startPolling()
        Task { await refresh() }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.watchers > 0 ? 45.0 : 300.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    func refresh() async {
        if case .loaded = loadState {} else if lastUpdated == nil {
            loadState = .loading
        }

        do {
            let entries = try await api.fetchSchedule()
            schedule = entries.compactMap { $0.asScheduleEntry() }.sorted { $0.startsAt < $1.startsAt }
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
            await resolveArtworkForOnAirShow()
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last good schedule; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }

    /// Kiosk's calendar is text only. The shows index does carry photos, so the
    /// current residency is looked up by name — and only accepted on an exact
    /// match, because the wrong DJ's photo is worse than none.
    private func resolveArtworkForOnAirShow() async {
        guard let entry = onAir else { return }
        let name = entry.showName
        let key = name.lowercased()
        guard !key.isEmpty, !resolvedArtworkNames.contains(key) else { return }
        resolvedArtworkNames.insert(key)

        guard let response = try? await api.search(name) else {
            resolvedArtworkNames.remove(key)
            return
        }
        let match = (response.showCollection?.items ?? []).first {
            HTMLText.decode($0.name ?? "")
                .trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(name) == .orderedSame
        }
        // Not every calendar title has a matching residency record. The
        // latest matching episode still carries valid artwork.
        let artwork = match?.photo?.url
            ?? response.episodeCollection?.items.first?.image?.url
        if let url = artwork.flatMap({ URL(string: $0) }) {
            showArtwork[key] = url
        }
    }
}
