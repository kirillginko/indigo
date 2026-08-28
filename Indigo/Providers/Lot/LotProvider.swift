//
//  LotProvider.swift
//  Indigo
//
//  The Lot Radio broadcasts from a shipping container in a triangular lot on
//  the Greenpoint/Williamsburg border, and has since 2016. One house channel,
//  a Livepeer stream, and a published calendar this reads to work out what is
//  on air. Occasionally a second, temporary channel runs alongside it.
//

import Foundation
import Observation

@Observable
final class LotProvider: RadioProvider {
    nonisolated static let providerID = "lot"
    let displayName = "The Lot Radio"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The house playback id, so the Listen button works before the first
    /// poll lands and still works if the homepage ever stops answering.
    private static let fallbackStreamURL = URL(
        string: "https://livepeercdn.studio/hls/85c28sa2o8wppm58/index.m3u8"
    )!

    private(set) var channel: LotLiveChannel?
    /// Pop-up channels The Lot is running besides the house stream.
    private(set) var popUps: [LotLiveChannel] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Now / next are derived from the clock, and @Observable only notices
    /// stored state — so the poll stamps the moment the schedule was read and
    /// everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = LotAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Station

    var stations: [RadioStation] { [station] }

    var station: RadioStation {
        RadioStation(
            id: "lot.live",
            providerID: Self.providerID,
            name: "The Lot Radio",
            shortName: "Lot",
            strapline: "Brooklyn",
            streamURL: channel?.streamURL ?? Self.fallbackStreamURL
        )
    }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - Schedule

    var schedule: [LotScheduleEntry] { channel?.schedule ?? [] }

    var onAir: LotScheduleEntry? {
        schedule.first { $0.contains(referenceDate) }
    }

    var upNext: LotScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on, for the schedule list.
    var upcoming: [LotScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    /// What has already aired, newest first — the fortnight the calendar keeps
    /// behind it, which is where a listener goes looking for a set they missed.
    var recent: [LotScheduleEntry] {
        schedule.filter { $0.endsAt <= referenceDate }.reversed()
    }

    /// The booth camera's latest frame. It refreshes on its own schedule, so
    /// the URL is stamped to stop the image layer holding the first one.
    var posterURL: URL? { channel?.posterURL(at: referenceDate) }

    var isOnAir: Bool { channel?.isOnAir ?? false }

    var now: RadioShow? { onAir.map { $0.asRadioShow(artworkURL: posterURL) } }
    var next: RadioShow? { upNext.map { $0.asRadioShow() } }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir?.title ?? "Live",
            detail: station.strapline,
            remoteArtworkURL: channel?.posterURL,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    /// The station page and active Lot playback call this to poll faster.
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
                let interval = self.watchers > 0 ? 60.0 : 420.0
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
            let channels = try await api.fetchLive()
            channel = channels.first
            popUps = Array(channels.dropFirst())
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last good schedule; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }
}
