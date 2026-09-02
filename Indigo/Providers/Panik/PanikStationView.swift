//
//  PanikStationView.swift
//  Indigo
//
//  Radio Panik's single channel. The station says what is on the air, and the
//  published week says when it ends and what follows — Panik gives a start per
//  slot and no end, so it is the calendar that makes the progress line and the
//  "up next" possible at all.
//

import SwiftUI

struct PanikStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(PanikProvider.self) private var station
    @Environment(PanikBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Radio Panik",
                subtitle: "Brussels, Belgium · 105.4 FM\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { station.beginWatching() }
        .onDisappear { station.endWatching() }
        // The on-air show has no picture of its own, but it is one of the
        // station's shows and the directory knows its face.
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
            EmptyStateView(headline: "Radio Panik unreachable", message: message) {
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
                markURL: PanikProvider.logoURL,
                mark: "Radio Panik"
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

                Text(station.onAir.title ?? station.currentSlot?.title ?? "Radio Panik")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                // In the continuous-music hours the station names the record
                // playing this minute, which is a better thing to show than
                // the name of the slot it is playing inside.
                if let playing = station.onAir.nowPlaying {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.accent)
                        Text(playing)
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let subtitle = station.onAir.subtitle {
                    Text(subtitle)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Brussels, Belgium")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                if let categories = onAirCategories {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(categories, id: \.self) { TagChip(text: $0) }
                    }
                }

                Text(onAirShow?.summary ?? blurb)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let show = onAirShow {
                    Button { appState.open(.panikShow(slug: show.slug)) } label: {
                        Text("About this show")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let next = station.upNext {
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

    private var blurb: String {
        "A free radio broadcasting from Saint-Josse in Brussels since 1983, made by the people who make its programmes."
    }

    /// The station names the show on air by slug, which is an identifier — so
    /// the directory is matched on that rather than on the title.
    private var onAirShow: PanikShow? {
        if let slug = station.onAir.showSlug ?? station.currentSlot?.showSlug,
           let show = browse.shows.first(where: { $0.slug == slug }) {
            return show
        }
        guard let title = station.onAir.title else { return nil }
        return browse.shows.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    private var onAirCategories: [String]? {
        let categories = station.currentSlot?.categories ?? onAirShow?.categories ?? []
        return categories.isEmpty ? nil : categories
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(station.onAir.isOnAir ? "On air now" : "Streaming")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = station.currentSlot?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let show = station.now,
               let fraction = show.elapsedFraction(at: station.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
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
                    PanikScheduleRow(entry: entry, exists: knows(entry)) { slug in
                        appState.open(.panikShow(slug: slug))
                    }
                    Rule()
                }
            }
        }
    }

    /// Only a slot whose show is in the directory has somewhere to go.
    private func knows(_ entry: PanikScheduleEntry) -> Bool {
        guard let slug = entry.showSlug else { return false }
        return browse.shows.contains { $0.slug == slug }
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

private struct PanikScheduleRow: View {
    let entry: PanikScheduleEntry
    let exists: Bool
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
                .frame(width: 100, alignment: .leading)

            Text(entry.title)
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.categories.first ?? "")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering && exists ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if exists, let slug = entry.showSlug { open(slug) } }
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
