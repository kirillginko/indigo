//
//  AlharaStationView.swift
//  Indigo
//
//  One of alHara's three channels. The station publishes what is on the air
//  and nothing else — no schedule, no archive, no artwork — so this page says
//  that much well and doesn't invent the rest.
//

import SwiftUI

struct AlharaStationView: View {
    let stationID: String

    @Environment(AlharaProvider.self) private var alhara
    @Environment(PlaybackCoordinator.self) private var player

    private var station: RadioStation? { alhara.station(id: stationID) }
    private var state: AlharaChannelState { alhara.state(for: stationID) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: station?.name ?? "Radio alHara",
                subtitle: "Bethlehem, Palestine\(lastUpdatedSuffix)"
            ) {
                if station != nil { playButton() }
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { alhara.beginWatching() }
        .onDisappear { alhara.endWatching() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(stationID) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = alhara.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if alhara.channels.isEmpty, alhara.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if alhara.channels.isEmpty, case .failed(let message) = alhara.loadState {
            EmptyStateView(headline: "Radio alHara unreachable", message: message) {
                Button("Try Again") { Task { await alhara.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = alhara.loadState {
                    NoticeStrip(text: "Showing the last known state. \(message)")
                        .padding(.bottom, 14)
                }

                hero
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 30)

                otherChannels
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            // alHara publishes no artwork of any kind — not for the show, not
            // for the channel — so its own mark stands in, and its name behind
            // that if even the mark cannot be reached.
            ArtworkView(
                side: 300,
                markURL: AlharaProvider.logoURL,
                mark: station?.name ?? "Radio alHara"
            )
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                .overlay(alignment: .topLeading) {
                    if state.isOnAir {
                        LiveBadge()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Palette.paper)
                            .padding(10)
                    }
                }

            VStack(alignment: .leading, spacing: 16) {
                onAirLine

                Text(state.title ?? station?.name ?? "Radio alHara")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let artist = state.artist {
                    Text(artist)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(state.city ?? station?.strapline ?? "Bethlehem")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                if state.isRerun, let original = state.originalAirLabel {
                    Text("Repeat of a broadcast from \(original)")
                        .microLabel(1.1, size: 9.5)
                        .foregroundStyle(Palette.inkFaint)
                }

                Text(blurb)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if state.videoURL != nil {
                    Text("A video feed is running alongside this channel; Indigo plays the sound.")
                        .microLabel(1.1, size: 9.5)
                        .foregroundStyle(Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                playButton(large: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(state.mode.label)
                    .microLabel(1.6)
                    .foregroundStyle(state.isOnAir ? Palette.live : Palette.inkFaint)
                if let started = state.startedLabel {
                    Text("from \(started)")
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = state.elapsedFraction(at: alhara.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    private var blurb: String {
        switch stationID {
        case "alhara.ra2":
            "alHara's second channel, given over to live events and to relaying other stations."
        case "alhara.ra3":
            "alHara's third channel, which travels with the station's exhibitions and installations."
        default:
            "A community radio station broadcasting from Bethlehem, Palestine since 2020, run by a shifting cast of friends and built around a permanently open door."
        }
    }

    // MARK: - The other channels

    @ViewBuilder
    private var otherChannels: some View {
        // Listed even while they are only carrying the main channel, so the
        // listener can see they exist and what they are doing.
        let others = alhara.publishedStations.filter { $0.id != stationID }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Other channels", color: Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(others) { other in
                    AlharaChannelRow(
                        station: other,
                        state: alhara.state(for: other.id),
                        isSimulcast: alhara.isSimulcast(other.id),
                        isPlaying: player.isCurrent(other.id) && player.isPlaying,
                        listen: {
                            if player.isCurrent(other.id) {
                                player.toggle()
                            } else if let item = alhara.mediaItem(for: other.id) {
                                player.playRadio(item)
                            }
                        }
                    )
                    Rule()
                }
            }
        }
    }

    // MARK: - Play

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(stationID) {
                player.toggle()
            } else if let item = alhara.mediaItem(for: stationID) {
                player.playRadio(item)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isThisStationPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isThisStationPlaying ? "Pause" : "Listen Live")
                    .microLabel(1.4, size: large ? 11 : 10)
            }
            .foregroundStyle(Palette.inverseInk)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 13 : 9)
            .background(Palette.inverse)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AlharaChannelRow: View {
    let station: RadioStation
    let state: AlharaChannelState
    let isSimulcast: Bool
    let isPlaying: Bool
    let listen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(station.shortName)
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 44, alignment: .leading)

            Text(state.title ?? station.name)
                .font(Typeface.body(12.5))
                .foregroundStyle(isSimulcast ? Palette.inkMuted : Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(isSimulcast ? "Carrying the main channel" : state.mode.label)
                .microLabel(1.2, size: 9)
                .foregroundStyle(state.isOnAir ? Palette.live : Palette.inkFaint)
                .lineLimit(1)
                .frame(width: 168, alignment: .trailing)

            Button(isPlaying ? "Pause" : "Listen", action: listen)
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
