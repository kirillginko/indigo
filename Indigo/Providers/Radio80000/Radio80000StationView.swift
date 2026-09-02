//
//  Radio80000StationView.swift
//  Indigo
//
//  Radio 80000's single channel. Airtime knows both the show on the air and
//  the file playing inside it, and publishes a fortnight of calendar — so this
//  page can say what is on, what is under it, and what follows for two weeks.
//

import SwiftUI

struct Radio80000StationView: View {
    @Environment(AppState.self) private var appState
    @Environment(Radio80000Provider.self) private var station
    @Environment(Radio80000BrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Radio 80000",
                subtitle: "Munich, Germany\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { station.beginWatching() }
        .onDisappear { station.endWatching() }
        // The live show has no artwork of its own — Airtime carries none — but
        // it is usually one of the station's own shows, and the directory
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
            EmptyStateView(headline: "Radio 80000 unreachable", message: message) {
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
                markURL: Radio80000Provider.logoURL,
                mark: "Radio 80000"
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

                Text(station.onAir.showName ?? station.now?.title ?? "Radio 80000")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                // Airtime names the file going out, which is usually the
                // pre-recorded broadcast rather than a track — so it sits
                // under the show rather than standing in for it.
                if let playing = playingLine {
                    Text(playing)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Munich, Germany")
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
                    Button { appState.open(.radio80000Show(slug: show.slug)) } label: {
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

    /// Airtime names the show; the directory is what knows its face. Matching
    /// is on the name because that is all Airtime gives — it carries no id
    /// that means anything to WordPress.
    private var onAirShow: Radio80000Show? {
        guard let name = station.onAir.showName ?? station.now?.title else { return nil }
        return browse.shows.first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private var onAirSummary: String? {
        station.onAir.showSummary ?? onAirShow?.summary
    }

    private var playingLine: String? {
        let title = station.onAir.trackTitle
        let artist = station.onAir.trackArtist
        guard let title, !title.isEmpty else { return nil }
        // Skip it when it is only the filename of the show already named above.
        if let name = station.onAir.showName,
           title.localizedCaseInsensitiveContains(name) { return nil }
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) — \(title)"
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(station.onAir.isOnAir ? "On air now" : "Streaming")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = station.now?.slot {
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
                    Radio80000ScheduleRow(entry: entry, show: show(named: entry.title)) { slug in
                        appState.open(.radio80000Show(slug: slug))
                    }
                    Rule()
                }
            }
        }
    }

    private func show(named title: String) -> Radio80000Show? {
        browse.shows.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
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

private struct Radio80000ScheduleRow: View {
    let entry: Radio80000ScheduleEntry
    /// The show behind the slot, when the directory has one under that name.
    let show: Radio80000Show?
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

            Text(entry.title)
                .font(Typeface.body(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(show?.genres.first ?? "")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering && show != nil ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if let show { open(show.slug) } }
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
