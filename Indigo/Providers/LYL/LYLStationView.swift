//
//  LYLStationView.swift
//  Indigo
//
//  LYL's single channel. The station publishes both what is going out right
//  now and a calendar a week deep, so the page can say what is on, what the
//  calendar expected, and what follows.
//

import SwiftUI

struct LYLStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(LYLProvider.self) private var lyl
    @Environment(LYLBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "LYL Radio",
                subtitle: "Lyon · Paris · Marseille\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { lyl.beginWatching() }
        .onDisappear { lyl.endWatching() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(lyl.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = lyl.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    @ViewBuilder
    private var content: some View {
        if lyl.onAirTitle == nil, lyl.schedule.isEmpty, lyl.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if lyl.onAirTitle == nil, lyl.schedule.isEmpty, case .failed(let message) = lyl.loadState {
            EmptyStateView(headline: "LYL unreachable", message: message) {
                Button("Try Again") { Task { await lyl.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = lyl.loadState {
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

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            // LYL publishes no picture of the live show, but the slot on the
            // calendar usually becomes an archived episode — and that has one.
            ArtworkView(
                remoteURL: onAirArtwork,
                side: 300,
                markURL: LYLProvider.logoURL,
                mark: "LYL Radio"
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

                Text(lyl.onAirTitle ?? lyl.onAir?.title ?? "LYL Radio")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let artists = lyl.onAir?.artists {
                    Text(artists)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Lyon · Paris · Marseille")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                Text("An independent web radio broadcasting from studios in Lyon, Paris, Marseille and Brussels, and from a network of contributors beyond them.")
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // Once the slot is archived it becomes a page of its own.
                if let slug = lyl.onAir?.episodeSlug {
                    Button { appState.open(.lylEpisode(slug: slug)) } label: {
                        Text("Open this episode")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let next = lyl.upNext {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel(text: "Up next")
                        Text("\(next.slot) · \(next.title)")
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

    private var onAirArtwork: URL? {
        guard let slug = lyl.onAir?.episodeSlug else { return nil }
        return browse.episode(slug: slug)?.imageURL
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(lyl.onAir == nil && lyl.onAirTitle == nil ? "Streaming" : "On air now")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = lyl.onAir?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let show = lyl.now, let fraction = show.elapsedFraction(at: lyl.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(lyl.upcoming.dropFirst(lyl.onAir == nil ? 0 : 1).prefix(50))
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Coming up", color: Palette.ink)
                    Spacer()
                    Text("Paris time").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(upcoming) { entry in
                    LYLScheduleRow(entry: entry) {
                        if let slug = entry.episodeSlug { appState.open(.lylEpisode(slug: slug)) }
                    }
                    Rule()
                }
            }
        }
    }

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(lyl.station.id) {
                player.toggle()
            } else {
                player.playRadio(lyl.mediaItem())
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

private struct LYLScheduleRow: View {
    let entry: LYLScheduleEntry
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

            Text(entry.title)
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let artists = entry.artists {
                Text(artists)
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering && entry.episodeSlug != nil ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if entry.episodeSlug != nil { open() } }
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
