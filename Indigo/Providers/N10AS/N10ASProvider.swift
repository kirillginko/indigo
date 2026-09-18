//
//  N10ASProvider.swift
//  Indigo
//
//  n10.as — "antennas", which is the joke: the station has none. It broadcasts
//  online only, from a studio above Bar Système in Montréal, volunteer-run
//  since 2016.
//
//  One channel, out of RadioCult, which is also where the calendar is. So this
//  provider is RadioCult twice over: what is on the air this second, and the
//  week ahead.
//

import Foundation
import Observation

@Observable
final class N10ASProvider: RadioProvider {
    nonisolated static let providerID = "n10as"
    let displayName = "n10.as"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The station's own mark, for when there is no picture of what is on —
    /// which for the live channel is always: RadioCult publishes no artwork
    /// on a slot. This is the station's Mixcloud portrait rather than its
    /// favicon, which is a 64px .ico and the only image the site serves.
    static let logoURL = URL(
        string: "https://thumbnailer.mixcloud.com/unsafe/600x600/profile/5/8/8/4/7d60-4b34-4234-9b4a-67c91dc6f612"
    )

    /// The Icecast mount RadioCult streams out of. It answers range requests
    /// with a made-up 1 GiB length, the same as IDA's — which AVPlayer reads
    /// as a seven-hour seekable file and buffers proportionally. That is
    /// already bounded for every station by `preferredForwardBufferDuration`
    /// in `StreamAudioEngine`; there is nothing station-specific to do here.
    private static let stream = URL(string: "https://n10as.radiocult.fm/stream")!

    private(set) var onAir: N10ASOnAir = .idle
    private(set) var schedule: [N10ASScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Now / next and the on-air progress are derived from the clock, and
    /// @Observable only notices stored state — so the poll stamps the moment
    /// it read and everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = N10ASAPI()
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
                id: "n10as.live",
                providerID: Self.providerID,
                name: "n10.as",
                shortName: "N10",
                strapline: "Montréal",
                streamURL: Self.stream
            )
        ]
    }

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - What is on

    /// RadioCult names the slot on the air; the calendar is the fallback for
    /// the stretches when it names nothing.
    var now: RadioShow? {
        onAir.asRadioShow() ?? schedule.first { $0.contains(referenceDate) }?.asRadioShow()
    }

    var upNext: N10ASScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on.
    var upcoming: [N10ASScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir.cleanName ?? now?.title ?? "Live",
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
            onAir = try await api.fetchOnAir()
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
        guard let entries = try? await api.fetchSchedule(), !entries.isEmpty else { return }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
