//
//  DublabProvider.swift
//  Indigo
//
//  dublab has broadcast from Los Angeles since 1999 — a listener-funded
//  non-profit with one channel, an Icecast stream out of Airtime, and a
//  programme calendar it publishes alongside it.
//

import Foundation
import Observation

@Observable
final class DublabProvider: RadioProvider {
    nonisolated static let providerID = "dublab"
    let displayName = "dublab"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let stations: [RadioStation] = [
        RadioStation(
            id: "dublab.live",
            providerID: DublabProvider.providerID,
            name: "dublab",
            shortName: "dublab",
            strapline: "Los Angeles",
            streamURL: URL(string: "https://dublab.out.airtime.pro/dublab_a")!
        )
    ]

    var station: RadioStation { stations[0] }

    /// The station's own mark, for when the archive has no picture of the
    /// show that is on.
    static let logoURL = URL(string: "https://www.dublab.com/assets/icons/apple-touch-icon-180x180.png")

    private(set) var onAir: DublabOnAir?
    private(set) var schedule: [DublabScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?
    /// The station's own wall clock. Every time it publishes is local to this
    /// and carries no offset, so nothing can be parsed without it.
    private(set) var timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

    /// Now / next are derived from the clock, and @Observable only notices
    /// stored state — so the poll stamps the moment the schedule was read and
    /// everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = DublabAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var scheduleLoadedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lookup

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    /// What Airtime says is on now, falling back to the published calendar
    /// when the stream is running unattended.
    var upNext: DublabScheduleEntry? {
        onAir?.upNext.first ?? schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on, for the schedule list.
    var upcoming: [DublabScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    var now: RadioShow? { onAir?.asRadioShow() }
    var next: RadioShow? { nil }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir?.showName ?? onAir?.trackTitle ?? "Live",
            detail: station.strapline,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    /// The station page and active dublab playback call this to poll faster.
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
            let live = try await api.fetchLive()
            onAir = live.onAir
            timeZone = live.timeZone
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
            await refreshScheduleIfStale()
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last good state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }

    /// The calendar changes by the week, not by the minute, so it is read once
    /// an hour rather than on every poll of what is on air.
    private func refreshScheduleIfStale() async {
        if let loaded = scheduleLoadedAt, Date.now.timeIntervalSince(loaded) < 3600, !schedule.isEmpty {
            return
        }
        guard let entries = try? await api.fetchSchedule(zone: timeZone), !entries.isEmpty else { return }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
