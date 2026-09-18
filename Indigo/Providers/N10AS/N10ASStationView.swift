//
//  N10ASStationView.swift
//  Indigo
//
//  n10.as's single channel. RadioCult names the slot on the air and publishes
//  a week of calendar, and says of each slot whether somebody is in the room
//  or a recording is going out — which for this station is most of it, so the
//  page says which rather than letting a re-run read as a live broadcast.
//

import SwiftUI

struct N10ASStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(N10ASProvider.self) private var station
    @Environment(N10ASBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "n10.as",
                subtitle: "Montréal, Canada\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { station.beginWatching() }
        .onDisappear { station.endWatching() }
        // The live slot has no artwork of its own — RadioCult carries none —
        // but it is usually one of the station's own shows, and the directory
        // knows its face.
        .task { await browse.loadShowsIfNeeded() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(station.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = station.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    @ViewBuilder
    private var content: some View {
        if !station.onAir.isOnAir, station.schedule.isEmpty, station.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if !station.onAir.isOnAir, station.schedule.isEmpty,
                  case .failed(let message) = station.loadState {
            EmptyStateView(headline: "n10.as unreachable", message: message) {
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
                    .padding(.bottom, 30)
                schedule
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: onAirShow?.imageURL,
                side: 300,
                markURL: N10ASProvider.logoURL,
                mark: "n10.as"
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

                Text(station.onAir.cleanName ?? station.now?.title ?? "n10.as")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Montréal, Canada")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                if let summary = onAirSummary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let show = onAirShow {
                    Button { appState.open(.n10asShow(slug: show.slug)) } label: {
                        Text("About this show")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let next = station.upNext {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel(text: "Up next")
                        Text("\(next.slot) · \(next.cleanTitle)")
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
                playButton(large: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// RadioCult names the slot; the directory is what knows its face. Matched
    /// on the name because that is all RadioCult gives — the slot carries no
    /// id that means anything to the station's own API.
    private var onAirShow: N10ASShow? {
        guard let name = station.onAir.cleanName ?? station.now?.title else { return nil }
        let wanted = N10ASTitle.matchKey(name)
        guard !wanted.isEmpty else { return nil }
        return browse.shows.first { N10ASTitle.matchKey($0.title) == wanted }
    }

    private var onAirSummary: String? {
        station.onAir.showSummary ?? onAirShow?.summary
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(onAirLabel)
                    .microLabel(1.6)
                    .foregroundStyle(station.onAir.isLiveSlot ? Palette.live : Palette.inkMuted)
                if let slot = station.now?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let show = station.now,
               let fraction = show.elapsedFraction(at: station.referenceDate) {
                ProgressTrack(
                    fraction: fraction,
                    tint: station.onAir.isLiveSlot ? Palette.live : Palette.ink
                )
                .frame(width: 180)
            }
        }
    }

    /// Most of n10.as's week is the station replaying its own archive, and
    /// RadioCult says which is which. Calling a re-run "on air now" would be
    /// true of the stream and wrong about the room.
    private var onAirLabel: String {
        guard station.onAir.isOnAir else { return "Streaming" }
        return station.onAir.isLiveSlot ? "On air now" : "Playing out"
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(
            station.upcoming.filter { $0.startsAt > station.referenceDate }.prefix(60)
        )
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Coming up", color: Palette.ink)
                    Spacer()
                    Text("Your time").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(upcoming) { entry in
                    N10ASScheduleRow(entry: entry, show: show(for: entry)) { slug in
                        appState.open(.n10asShow(slug: slug))
                    }
                    Rule()
                }
            }
        }
    }

    private func show(for entry: N10ASScheduleEntry) -> N10ASShow? {
        let wanted = N10ASTitle.matchKey(entry.cleanTitle)
        guard !wanted.isEmpty else { return nil }
        return browse.shows.first { N10ASTitle.matchKey($0.title) == wanted }
    }

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(station.station.id) {
                player.toggle()
            } else {
                player.playRadio(station.mediaItem())
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

private struct N10ASScheduleRow: View {
    let entry: N10ASScheduleEntry
    /// The show behind the slot, when the directory still lists it.
    let show: N10ASShow?
    let open: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(dayLabel)
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 62, alignment: .leading)

            Text(entry.slot)
                .font(Typeface.mono(10.5))
                .foregroundStyle(Palette.inkMuted)
                .monospacedDigit()
                .frame(width: 90, alignment: .leading)

            Text(entry.cleanTitle)
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(kindLabel)
                .microLabel(0.9)
                .foregroundStyle(entry.isLive ? Palette.live : Palette.inkFaint)
                .frame(width: 70, alignment: .leading)

            Text(show?.genres.first ?? "")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering && show != nil ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if let show { open(show.slug) } }
    }

    private var kindLabel: String {
        if entry.isLive { return "Live" }
        return entry.isRerun ? "Re-run" : "Playout"
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.startsAt) { return "Today" }
        if calendar.isDateInTomorrow(entry.startsAt) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: entry.startsAt)
    }
}
