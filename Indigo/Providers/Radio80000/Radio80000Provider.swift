//
//  Radio80000Provider.swift
//  Indigo
//
//  Radio 80000 broadcasts from Munich — a non-commercial community station,
//  on air since 2015, run by the people who make its programmes.
//
//  One channel, out of Airtime, which is also the only place the station
//  publishes a schedule. So this provider is Airtime twice over: what is on
//  the air this second, and the fortnight ahead.
//

import Foundation
import Observation

@Observable
final class Radio80000Provider: RadioProvider {
    nonisolated static let providerID = "radio80000"
    let displayName = "Radio 80000"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The station's own mark, for when there is no picture of what is on —
    /// which for the live channel is always: Airtime publishes no artwork.
    static let logoURL = URL(string: "https://www.radio80k.de/favicon.ico")

    /// The Icecast mount Airtime streams out of. It is fixed rather than
    /// discovered — Airtime's API describes the schedule, not the stream.
    private static let stream = URL(string: "https://radio80k.out.airtime.pro/radio80k_a")!

    private(set) var onAir: Radio80000OnAir = .idle
    private(set) var schedule: [Radio80000ScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?
    private(set) var timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    /// Now / next and the on-air progress are derived from the clock, and
    /// @Observable only notices stored state — so the poll stamps the moment
    /// it read and everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = Radio80000API()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var scheduleLoadedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Station

    var stations: [RadioStation] {
        [
            RadioStation(
                id: "radio80000.live",
                providerID: Self.providerID,
                name: "Radio 80000",
                shortName: "80K",
                strapline: "Munich",
                streamURL: Self.stream
            )
        ]
    }

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - What is on

    /// Airtime names the show on the air; the calendar is the fallback for the
    /// stretches when it names nothing.
    var now: RadioShow? {
        onAir.asRadioShow() ?? schedule.first { $0.contains(referenceDate) }?.asRadioShow()
    }

    var upNext: Radio80000ScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on.
    var upcoming: [Radio80000ScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir.showName ?? now?.title ?? "Live",
            detail: station.strapline,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

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
            // Keep showing the last known state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }

    /// The calendar changes by the week, not by the minute.
    private func refreshScheduleIfStale() async {
        if let loaded = scheduleLoadedAt, Date.now.timeIntervalSince(loaded) < 1800, !schedule.isEmpty {
            return
        }
        guard let entries = try? await api.fetchSchedule(zone: timeZone), !entries.isEmpty else {
            return
        }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
