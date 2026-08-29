//
//  DublabStationView.swift
//  Indigo
//
//  dublab's single channel. Airtime knows exactly what is on the air and what
//  file is playing inside it, so this page can say both — the programme, and
//  the broadcast within it — rather than guessing from a calendar.
//

import SwiftUI

struct DublabStationView: View {
    @Environment(DublabProvider.self) private var dublab
    @Environment(DublabBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "dublab",
                subtitle: "Los Angeles\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { dublab.beginWatching() }
        .onDisappear { dublab.endWatching() }
        .task { await browse.loadArchiveIfNeeded() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(dublab.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = dublab.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if dublab.onAir == nil, dublab.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if dublab.onAir == nil, case .failed(let message) = dublab.loadState {
            EmptyStateView(headline: "dublab unreachable", message: message) {
                Button("Try Again") { Task { await dublab.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = dublab.loadState {
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
            ArtworkView(
                remoteURL: onAirArtwork,
                side: 300,
                markURL: DublabProvider.logoURL,
                mark: "dublab"
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

                Text(dublab.onAir?.showName ?? "dublab")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                // Airtime names the file playing inside the show, which is
                // usually the broadcast itself — a truer answer to "what is
                // this?" than the programme title alone.
                if let track = dublab.onAir?.trackTitle, track != dublab.onAir?.showName {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel(text: "Playing")
                        Text(track)
                            .font(Typeface.body(12.5, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let artist = dublab.onAir?.trackArtist, !artist.isEmpty {
                            Text(artist)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Los Angeles")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                Text("A listener-supported, non-profit radio station broadcasting from Los Angeles since 1999, dedicated to the growth of positive music, art and culture.")
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let next = dublab.upNext {
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

    /// Airtime publishes no artwork, but the show on air is usually one dublab
    /// archives — so the most recent broadcast filed under the same programme
    /// is the truest picture of what you are hearing.
    private var onAirArtwork: URL? {
        guard let name = dublab.onAir?.showName, !name.isEmpty else { return nil }
        let match = browse.broadcasts.first {
            $0.showName?.caseInsensitiveCompare(name) == .orderedSame
        }
        return match?.artworkURL
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(dublab.onAir?.showName == nil ? "Streaming" : "On air now")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = dublab.onAir?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = dublab.onAir?.elapsedFraction {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(dublab.upcoming.prefix(40))
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    MicroLabel(text: "Coming up", color: Palette.ink)
                    Spacer()
                    Text("Los Angeles time")
                        .microLabel(1.2)
                        .foregroundStyle(Palette.inkFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()

                ForEach(upcoming) { entry in
                    DublabScheduleRow(
                        entry: entry,
                        isExpanded: expanded.contains(entry.id),
                        toggle: { toggle(entry) }
                    )
                    Rule()
                }
            }
        }
    }

    private func toggle(_ entry: DublabScheduleEntry) {
        if expanded.contains(entry.id) {
            expanded.remove(entry.id)
        } else {
            expanded.insert(entry.id)
        }
    }

    // MARK: - Play

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(dublab.station.id) {
                player.toggle()
            } else {
                player.playRadio(dublab.mediaItem())
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

/// A calendar slot. dublab writes a note for most of its programmes, so the
/// row opens onto it rather than truncating it away.
private struct DublabScheduleRow: View {
    let entry: DublabScheduleEntry
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                if entry.summary != nil {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)

            if isExpanded, let summary = entry.summary {
                Text(summary)
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.leading, 166)
                    .padding(.bottom, 14)
            }
        }
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if entry.summary != nil { toggle() } }
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
