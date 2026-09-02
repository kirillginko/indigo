//
//  RovrStationView.swift
//  Indigo
//
//  One ROVR channel — either the scheduled radio or one of the four mood
//  channels, which behave differently enough to be worth saying so on the
//  page: the radio has a schedule and the moods run continuously.
//
//  The radio page also says which timezone stream it is on, because that is
//  the station's whole idea and a listener who does not know it is hearing a
//  schedule that seems oddly well-timed for no reason.
//

import SwiftUI

struct RovrStationView: View {
    let stationID: String

    @Environment(AppState.self) private var appState
    @Environment(RovrProvider.self) private var station
    @Environment(RovrBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private var channel: RovrChannel { station.channel(id: stationID) ?? station.radio }
    private var isRadio: Bool { channel.kind == .radio }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: channel.name, subtitle: subtitle) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { station.beginWatching() }
        .onDisappear { station.endWatching() }
    }

    private var subtitle: String {
        let base = isRadio
            ? "Radio reinvented · \(station.offsetLabel)"
            : "Continuous · \(channel.name)"
        guard let updated = station.lastUpdated else { return base }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(base) · Updated \(formatter.string(from: updated))"
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(stationID) && player.isPlaying
    }

    @ViewBuilder
    private var content: some View {
        if isRadio, !station.onAir.isOnAir, station.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if isRadio, !station.onAir.isOnAir, case .failed(let message) = station.loadState {
            EmptyStateView(headline: "ROVR unreachable", message: message) {
                Button("Try Again") { Task { await station.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = station.loadState {
                    NoticeStrip(text: "Showing the last known state. \(message)")
                        .padding(.bottom, 14)
                }
                hero
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 26)
                otherChannels
                if isRadio { schedule }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: isRadio ? station.onAir.imageURL : channel.imageURL,
                side: 300,
                markURL: RovrProvider.logoURL,
                mark: "ROVR"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .overlay(alignment: .topLeading) {
                LiveBadge()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Palette.paper)
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 16) {
                onAirLine

                Text(headline)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if isRadio, let curator = station.onAir.curatorName {
                    Text(curator)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(blurb)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if isRadio {
                    HStack(spacing: 14) {
                        if let id = station.onAir.broadcastID {
                            Button { appState.open(.rovrBroadcast(id: id)) } label: {
                                Text("Open this broadcast")
                                    .microLabel(1.2, size: 9.5)
                                    .foregroundStyle(Palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        if let id = station.onAir.showID {
                            Button { appState.open(.rovrShow(id: id)) } label: {
                                Text("About the show")
                                    .microLabel(1.2, size: 9.5)
                                    .foregroundStyle(Palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let next = station.upNext, let title = next.title {
                        VStack(alignment: .leading, spacing: 4) {
                            MicroLabel(text: "Up next")
                            Text(slotLabel(next).map { "\($0) · \(title)" } ?? title)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 0)
                playButton(large: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        isRadio ? (station.onAir.title ?? "ROVR") : channel.name
    }

    private var blurb: String {
        guard isRadio else {
            return "One of ROVR's mood channels — continuous, unscheduled, and running on its own all day."
        }
        if let summary = station.onAir.summary { return summary }
        return "ROVR broadcasts the same programme on a stream for every hour of the world, so a show made for the evening reaches you in yours. You're hearing \(station.offsetLabel)."
    }

    private func slotLabel(_ slot: RovrOnAir) -> String? {
        guard let start = slot.startsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let end = slot.endsAt else { return formatter.string(from: start) }
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(isRadio ? (station.onAir.isOnAir ? "On air now" : "Streaming") : "Always on")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if isRadio, let slot = slotLabel(station.onAir) {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if isRadio, let show = station.now,
               let fraction = show.elapsedFraction(at: station.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    // MARK: - The other channels

    /// ROVR's moods are a real part of what it publishes, not a submenu — so
    /// whichever channel you are on names the others.
    @ViewBuilder
    private var otherChannels: some View {
        let others = station.channels.filter { $0.id != channel.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Also on ROVR", color: Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(others) { other in
                    RovrChannelRow(
                        channel: other,
                        isPlaying: player.isCurrent(other.id) && player.isPlaying
                    ) {
                        appState.select(.rovrStation(other.id))
                    }
                    Rule()
                }
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let coming = station.upcoming.filter { ($0.startsAt ?? .distantPast) > station.referenceDate }
        if !coming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Coming up", color: Palette.ink)
                    Spacer()
                    Text(station.offsetLabel).microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(Array(coming.enumerated()), id: \.offset) { _, slot in
                    RovrScheduleRow(slot: slot, label: slotLabel(slot)) { id in
                        appState.open(.rovrBroadcast(id: id))
                    }
                    Rule()
                }
            }
        }
    }

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(stationID) {
                player.toggle()
            } else if let item = station.mediaItem(for: stationID) {
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

private struct RovrChannelRow: View {
    let channel: RovrChannel
    let isPlaying: Bool
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text(channel.kind == .radio ? "Radio" : "Mood")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: 70, alignment: .leading)

                Text(channel.name)
                    .font(Typeface.body(12.5, weight: .semibold))
                    .frame(width: 120, alignment: .leading)

                Text(channel.strapline)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isPlaying {
                    Text("playing").microLabel(0.9).foregroundStyle(Palette.live)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.inkFaint)
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)
            .background(isHovering ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RovrScheduleRow: View {
    let slot: RovrOnAir
    let label: String?
    let open: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(dayLabel)
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 62, alignment: .leading)

            Text(label ?? "")
                .font(Typeface.mono(10.5))
                .foregroundStyle(Palette.inkMuted)
                .monospacedDigit()
                .frame(width: 100, alignment: .leading)

            Text(slot.title ?? "")
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(slot.curatorName ?? "")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering && slot.broadcastID != nil ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if let id = slot.broadcastID { open(id) } }
    }

    private var dayLabel: String {
        guard let start = slot.startsAt else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "Today" }
        if calendar.isDateInTomorrow(start) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: start)
    }
}
