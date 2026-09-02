//
//  IdaStationView.swift
//  Indigo
//
//  One of IDA's two channels. Tallinn and Helsinki run their own schedules at
//  once, so this page is written per-channel and says plainly what the other
//  one is doing — otherwise a listener on Helsinki has no way to notice that
//  the show they wanted is on in Tallinn.
//

import SwiftUI

struct IdaStationView: View {
    let stationID: String

    @Environment(AppState.self) private var appState
    @Environment(IdaProvider.self) private var ida
    @Environment(IdaBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private var channel: IdaChannel { ida.channel(for: stationID) ?? .tallinn }
    private var state: IdaChannelState { ida.state(for: channel) }
    private var station: RadioStation? { ida.station(id: stationID) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: channel.name,
                subtitle: "\(channel.location)\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { ida.beginWatching() }
        .onDisappear { ida.endWatching() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(stationID) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = ida.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    @ViewBuilder
    private var content: some View {
        if state.episode == nil, ida.schedule.isEmpty, ida.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if state.episode == nil, ida.schedule.isEmpty, case .failed(let message) = ida.loadState {
            EmptyStateView(headline: "IDA unreachable", message: message) {
                Button("Try Again") { Task { await ida.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = ida.loadState {
                    NoticeStrip(text: "Showing the last known state. \(message)")
                        .padding(.bottom, 14)
                }
                hero
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 26)
                otherChannel
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
                remoteURL: state.episode?.imageURL,
                side: 300,
                markURL: IdaProvider.logoURL,
                mark: "IDA Radio"
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

                Text(state.episode?.title ?? channel.name)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let artist = state.episode?.showArtist {
                    Text(artist)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(channel.location)
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                if let genres = onAirGenres {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(genres, id: \.self) { TagChip(text: $0) }
                    }
                }

                Text(blurb)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // The live slot becomes an archived episode under the same
                // slug once IDA uploads the recording, so it already has a
                // page worth opening.
                if let episode = state.episode {
                    HStack(spacing: 14) {
                        Button { appState.open(.idaEpisode(slug: episode.slug)) } label: {
                            Text("Open this episode")
                                .microLabel(1.2, size: 9.5)
                                .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)

                        if let showSlug = episode.showSlug {
                            Button { appState.open(.idaShow(slug: showSlug)) } label: {
                                Text("About the show")
                                    .microLabel(1.2, size: 9.5)
                                    .foregroundStyle(Palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let next = upNextLabel {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel(text: "Up next")
                        Text(next)
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

    private var onAirGenres: [String]? {
        let genres = state.episode?.genres ?? []
        return genres.isEmpty ? nil : Array(genres.prefix(6))
    }

    private var blurb: String {
        switch channel {
        case .tallinn:
            "IDA broadcasts from Telliskivi in Tallinn — a community station run by the people who make its programmes, on air since 2019."
        case .helsinki:
            "IDA's second studio, broadcasting from Helsinki since 2023 on a schedule of its own."
        }
    }

    private var upNextLabel: String? {
        // The calendar is the better answer when it has loaded, because it
        // carries the time as well as the name; `live` only names the show.
        if let entry = ida.upcoming(on: channel).first(where: { $0.startsAt > ida.referenceDate }) {
            return "\(entry.slot) · \(entry.episode.title)"
        }
        guard let title = state.nextTitle else { return nil }
        guard let start = state.nextStartsAt else { return title }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) · \(title)"
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(state.isOnAir ? "On air now" : "Streaming")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let show = ida.now(for: channel), let slot = show.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let show = ida.now(for: channel),
               let fraction = show.elapsedFraction(at: ida.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    // MARK: - The other channel

    /// IDA runs two schedules at once. A listener on one of them should not
    /// have to go looking to find out what the other is playing.
    @ViewBuilder
    private var otherChannel: some View {
        let other = channel == .tallinn ? IdaChannel.helsinki : IdaChannel.tallinn
        let otherState = ida.state(for: other)
        VStack(alignment: .leading, spacing: 0) {
            Rule(color: Palette.outline)
            Button {
                appState.select(.idaStation(other.stationID))
            } label: {
                HStack(spacing: 12) {
                    Text("Also on air")
                        .microLabel(1.4)
                        .foregroundStyle(Palette.inkFaint)
                        .frame(width: 90, alignment: .leading)

                    Text(other.city)
                        .font(Typeface.body(12.5, weight: .semibold))
                        .frame(width: 80, alignment: .leading)

                    Text(otherState.episode?.title ?? "Off air")
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if player.isCurrent(other.stationID), player.isPlaying {
                        Text("playing")
                            .microLabel(0.9)
                            .foregroundStyle(Palette.live)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(
            ida.upcoming(on: channel)
                .filter { $0.startsAt > ida.referenceDate }
                .prefix(50)
        )
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Coming up on \(channel.city)", color: Palette.ink)
                    Spacer()
                    Text("Your time").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(upcoming) { entry in
                    IdaScheduleRow(entry: entry) {
                        appState.open(.idaEpisode(slug: entry.episode.slug))
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
            } else if let item = ida.mediaItem(for: stationID) {
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

private struct IdaScheduleRow: View {
    let entry: IdaScheduleEntry
    let open: () -> Void

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

            Text(entry.episode.title)
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.episode.isRepeat {
                Text("repeat")
                    .microLabel(0.9)
                    .foregroundStyle(Palette.inkFaint)
            }

            Text(entry.episode.showArtist ?? "")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
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
