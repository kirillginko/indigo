//
//  RovrProvider.swift
//  Indigo
//
//  ROVR calls itself radio reinvented, and the thing it means by that is
//  worth stating plainly, because it decides how this provider works: the
//  station has no home timezone. The same programme goes out on twenty-one
//  streams at once, one an hour of UTC offset, so a show scheduled for the
//  evening is the evening wherever it is heard.
//
//  So the listener's own offset picks the stream, and the schedule is asked
//  for in their own wall clock. Running alongside it are four mood channels,
//  which are continuous and have no schedule at all.
//

import Foundation
import Observation

@Observable
final class RovrProvider: RadioProvider {
    nonisolated static let providerID = "rovr"
    let displayName = "ROVR"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The station's own mark, for when there is no picture of what is on.
    static let logoURL = URL(string: "https://www.rovr.live/favicon.ico")

    /// UTC's own stream. A listener has to be able to press play before the
    /// first poll resolves their offset, and this is the honest default —
    /// it is also what the station falls back to past ±12.
    private static let fallbackStream =
        URL(string: "https://hls-prod.rovr.live/prod/stream_plus00/llhls.m3u8")!

    private(set) var onAir: RovrOnAir = .idle
    private(set) var upcoming: [RovrOnAir] = []
    private(set) var moods: [RovrChannel] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// The stream resolved for this listener's offset, once it is known.
    private(set) var radioStreamURL: URL = RovrProvider.fallbackStream
    private(set) var resolvedOffset: Int?

    /// The on-air progress is derived from the clock, and @Observable only
    /// notices stored state — so the poll stamps the moment it read and
    /// everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = RovrAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var streamResolvedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Channels

    /// Hours this listener is from UTC, which is the whole of what ROVR needs
    /// to know about where they are.
    var localOffset: Int {
        TimeZone.current.secondsFromGMT() / 3600
    }

    /// The scheduled radio. Its id never changes, however the listener's
    /// offset moves — the crate and the player store it, and a broadcast
    /// crated in Berlin should still be the same station in Lisbon.
    var radio: RovrChannel {
        RovrChannel(
            id: RovrChannel.radioID,
            name: "ROVR",
            shortName: "ROVR",
            strapline: offsetLabel,
            streamURL: radioStreamURL,
            kind: .radio,
            imageURL: nil,
            offset: resolvedOffset
        )
    }

    /// "UTC+2" — the shift the listener is hearing the schedule on.
    var offsetLabel: String {
        let offset = resolvedOffset ?? localOffset
        if offset == 0 { return "UTC" }
        return offset > 0 ? "UTC+\(offset)" : "UTC\(offset)"
    }

    var stations: [RadioStation] {
        ([radio] + moods).map { channel in
            RadioStation(
                id: channel.id,
                providerID: Self.providerID,
                name: channel.name,
                shortName: channel.shortName,
                strapline: channel.strapline,
                streamURL: channel.streamURL
            )
        }
    }

    var channels: [RovrChannel] { [radio] + moods }

    func channel(id: String) -> RovrChannel? {
        channels.first { $0.id == id }
    }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - What is on

    /// Only the scheduled radio has a schedule; the mood channels run
    /// continuously and say nothing about themselves.
    var now: RadioShow? { onAir.asRadioShow() }

    var upNext: RovrOnAir? {
        upcoming.first { ($0.startsAt ?? .distantPast) > referenceDate }
    }

    /// The provider-independent item the player consumes.
    func mediaItem(for stationID: String) -> MediaItem? {
        guard let channel = channel(id: stationID) else { return nil }
        return MediaItem(
            id: channel.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: channel.name,
            subtitle: channel.kind == .radio ? (onAir.title ?? "Live") : "Continuous",
            detail: channel.strapline,
            remoteArtworkURL: channel.imageURL,
            playbackURL: channel.streamURL
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

        await resolveStreamsIfStale()

        do {
            onAir = try await api.fetchOnAir()
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last known state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }

        await refreshUpcoming()
    }

    /// The stream addresses and the mood roster change by the season, not by
    /// the minute — but the listener's offset can change under us when they
    /// travel or the clocks go back, so this is re-asked rather than done once.
    private func resolveStreamsIfStale() async {
        let offset = localOffset
        if let resolved = streamResolvedAt,
           Date.now.timeIntervalSince(resolved) < 3600,
           resolvedOffset == offset {
            return
        }

        if let stream = try? await api.fetchRadioStream(offset: offset),
           let address = stream.hlsUrl,
           let url = URL(string: address) {
            radioStreamURL = url
            resolvedOffset = offset
        }

        if let published = try? await api.fetchMoodStreams(), !published.isEmpty {
            moods = published.compactMap { stream in
                guard let name = stream.name?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty,
                      let address = stream.hlsUrl,
                      let url = URL(string: address)
                else { return nil }
                let title = stream.mood?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                    ?? name.uppercased()
                return RovrChannel(
                    id: RovrChannel.moodID(name),
                    name: title,
                    shortName: String(title.prefix(4)),
                    strapline: "Mood",
                    streamURL: url,
                    kind: .mood,
                    imageURL: stream.mood?.squareImage.flatMap { URL(string: $0) },
                    offset: nil
                )
            }
        }
        streamResolvedAt = .now
    }

    /// ROVR answers the schedule for a moment rather than a range, so what
    /// follows costs a request a slot. Only worth paying while somebody is
    /// looking at the page.
    private func refreshUpcoming() async {
        guard watchers > 0 else { return }
        let found = await api.fetchUpcoming(from: .now, limit: 5)
        guard !found.isEmpty else { return }
        upcoming = found
    }
}
