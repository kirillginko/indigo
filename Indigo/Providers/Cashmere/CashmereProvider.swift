//
//  CashmereProvider.swift
//  Indigo
//
//  Cashmere Radio broadcasts from a former grocer's shop in Berlin-Lichtenberg
//  and has since 2015 — a community station running on Airtime, with its
//  archive kept on Mixcloud.
//
//  The station manages its channels as entries of their own, so the stream
//  addresses are read rather than pinned here: Cashmere spins up extra
//  channels for festivals and takes them down again afterwards.
//

import Foundation
import Observation

@Observable
final class CashmereProvider: RadioProvider {
    nonisolated static let providerID = "cashmere"
    let displayName = "Cashmere Radio"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The house channel, known up front so the Listen button works before the
    /// first poll and still works if the endpoint goes quiet. `_a` is the
    /// unused Airtime default on this server and answers with silent ogg; `_b`
    /// is what the station actually broadcasts on.
    private static let houseStream = URL(
        string: "https://cashmereradio.out.airtime.pro/cashmereradio_b"
    )!
    /// The slug the station files its main channel under.
    private static let houseSlug = "cashmere-standard-stream"

    /// The station's own mark, for when the archive has no picture of the
    /// show that is on.
    static let logoURL = URL(
        string: "https://backstage.cashmereradio.com/wp-content/themes/cashmereradio/icons/ms-icon-310x310.png"
    )

    private(set) var onAir: CashmereOnAir?
    /// Every channel the station is currently running, house one first.
    private(set) var extraStreams: [CashmereStream] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?
    private(set) var timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    /// Progress is derived from the clock, and @Observable only notices stored
    /// state — so the poll stamps the moment it read and everything keys off
    /// that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = CashmereAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var streamsLoaded = false

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Station

    /// Where the house channel currently lives. Read from the station once its
    /// own list of channels arrives, so a moved mount is followed rather than
    /// stranded.
    private(set) var houseStreamURL: URL = CashmereProvider.houseStream

    var stations: [RadioStation] {
        [
            RadioStation(
                id: "cashmere.live",
                providerID: Self.providerID,
                name: "Cashmere Radio",
                shortName: "Cashmere",
                strapline: "Berlin",
                streamURL: houseStreamURL
            )
        ]
    }

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    var upNext: CashmereSlot? { onAir?.upNext.first }
    var upcoming: [CashmereSlot] { onAir?.upNext ?? [] }
    var now: RadioShow? { onAir?.asRadioShow() }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir?.showName ?? "Live",
            detail: station.strapline,
            playbackURL: station.streamURL
        )
    }

    /// A side channel — a festival stage, say — which is a station in its own
    /// right for as long as it is up.
    func mediaItem(for stream: CashmereStream) -> MediaItem {
        MediaItem(
            id: "cashmere.stream.\(stream.slug)",
            sourceID: Self.providerID,
            kind: .radioStation,
            title: stream.title,
            subtitle: "Live",
            detail: "Cashmere Radio",
            playbackURL: stream.url
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
            await loadStreamsIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last known state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }

    /// The channel list changes by the season, not by the minute.
    private func loadStreamsIfNeeded() async {
        guard !streamsLoaded else { return }
        guard let streams = try? await api.fetchStreams(), !streams.isEmpty else { return }
        let house = streams.first { $0.slug == Self.houseSlug }
            ?? streams.first { $0.url == Self.houseStream }
        if let house { houseStreamURL = house.url }
        // The house channel already has a row of its own.
        extraStreams = streams.filter { $0.url != houseStreamURL }
        streamsLoaded = true
    }
}
