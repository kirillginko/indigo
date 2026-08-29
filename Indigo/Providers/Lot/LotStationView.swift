//
//  LotStationView.swift
//  Indigo
//
//  The Lot's house channel. The station publishes a calendar rather than show
//  metadata, so this page is built out of the calendar: what is on now, the
//  note written for it, and the fortnight either side.
//

import SwiftUI

struct LotStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(LotProvider.self) private var lot
    @Environment(LotBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var expanded: Set<String> = []
    @State private var showsPast = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: lot.station.name,
                subtitle: "Greenpoint, Brooklyn\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { lot.beginWatching() }
        .onDisappear { lot.endWatching() }
        .task { await browse.loadShowsIfNeeded() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(lot.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = lot.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if lot.channel == nil, lot.loadState == .loading {
            LoadingPane(label: "Loading schedule")
        } else if lot.channel == nil, case .failed(let message) = lot.loadState {
            EmptyStateView(headline: "The Lot unreachable", message: message) {
                Button("Try Again") { Task { await lot.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = lot.loadState {
                    NoticeStrip(text: "Showing the last known schedule. \(message)")
                        .padding(.bottom, 14)
                }

                hero
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 30)

                if !lot.popUps.isEmpty { popUps }
                schedule
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            // The Lot points a camera at the booth, so the closest thing the
            // station has to artwork is a frame of whoever is playing.
            ArtworkView(remoteURL: lot.posterURL, side: 300)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                .overlay(alignment: .topLeading) {
                    if lot.isOnAir {
                        LiveBadge()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Palette.paper)
                            .padding(10)
                    }
                }

            VStack(alignment: .leading, spacing: 16) {
                onAirLine

                Text(lot.onAir?.title ?? "The Lot Radio")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Greenpoint, Brooklyn")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                if let summary = lot.onAir?.summary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    MediaLinkChips(links: lot.onAir?.links ?? [])
                } else {
                    Text("An independent radio station broadcasting from a shipping container in a triangular lot on the Greenpoint waterfront, on air seven days a week since 2016.")
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let residency = residency(for: lot.onAir) {
                    Button {
                        appState.open(.lotShow(slug: residency.slug))
                    } label: {
                        Text("Open \(residency.name)")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let next = lot.upNext {
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

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(statusLabel)
                    .microLabel(1.6)
                    .foregroundStyle(lot.isOnAir ? Palette.live : Palette.inkFaint)
                if let slot = lot.onAir?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = lot.now?.elapsedFraction(at: lot.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    private var statusLabel: String {
        if lot.onAir != nil { return lot.isOnAir ? "On air now" : "Scheduled now" }
        return lot.isOnAir ? "Streaming" : "Off air"
    }

    /// The calendar names the residency in its summary; the shows directory is
    /// what knows where that residency lives.
    private func residency(for entry: LotScheduleEntry?) -> LotShow? {
        guard let entry else { return nil }
        let name = entry.showName
        guard !name.isEmpty else { return nil }
        return browse.shows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Pop-up channels

    private var popUps: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Also streaming", trailing: nil)
            ForEach(lot.popUps, id: \.id) { channel in
                HStack(spacing: 14) {
                    Text(channel.title)
                        .font(Typeface.body(12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(channel.isOnAir ? "Live" : "Off air")
                        .microLabel(1.2, size: 9)
                        .foregroundStyle(channel.isOnAir ? Palette.live : Palette.inkFaint)
                    Button("Listen") { player.playRadio(mediaItem(for: channel)) }
                        .buttonStyle(OutlineButtonStyle())
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 8)
                Rule()
            }
        }
    }

    private func mediaItem(for channel: LotLiveChannel) -> MediaItem {
        MediaItem(
            id: "lot.live.\(channel.id)",
            sourceID: LotProvider.providerID,
            kind: .radioStation,
            title: channel.title,
            subtitle: channel.schedule.first { $0.contains(lot.referenceDate) }?.title ?? "Live",
            detail: "The Lot Radio",
            remoteArtworkURL: channel.posterURL,
            playbackURL: channel.streamURL
        )
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(lot.upcoming.dropFirst(lot.onAir == nil ? 0 : 1).prefix(60))
        let past = Array(lot.recent.prefix(40))

        if !upcoming.isEmpty {
            sectionHeader("Coming up", trailing: "New York time")
            ForEach(upcoming) { entry in
                LotScheduleRow(
                    entry: entry,
                    isExpanded: expanded.contains(entry.id),
                    toggle: { toggle(entry) }
                )
                Rule()
            }
        }

        if !past.isEmpty {
            sectionHeader(
                "Already aired",
                trailing: nil,
                action: (showsPast ? "Hide" : "Show \(past.count)", { showsPast.toggle() })
            )
            if showsPast {
                ForEach(past) { entry in
                    LotScheduleRow(
                        entry: entry,
                        isExpanded: expanded.contains(entry.id),
                        toggle: { toggle(entry) }
                    )
                    Rule()
                }
            }
        }
    }

    private func toggle(_ entry: LotScheduleEntry) {
        if expanded.contains(entry.id) {
            expanded.remove(entry.id)
        } else {
            expanded.insert(entry.id)
        }
    }

    private func sectionHeader(
        _ title: String,
        trailing: String?,
        action: (String, () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            HStack {
                MicroLabel(text: title, color: Palette.ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .microLabel(1.2)
                        .foregroundStyle(Palette.inkFaint)
                }
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.plain)
                        .microLabel(1.0)
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
            Rule()
        }
    }

    // MARK: - Play

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(lot.station.id) {
                player.toggle()
            } else {
                player.playRadio(lot.mediaItem())
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

/// A calendar slot. The note the station writes for a booking is often the
/// only description that broadcast will ever have, so the row opens onto it
/// rather than truncating it away.
private struct LotScheduleRow: View {
    let entry: LotScheduleEntry
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

                if hasNote {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)

            if isExpanded, hasNote {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = entry.summary {
                        Text(summary)
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    MediaLinkChips(links: entry.links)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.leading, 166)
                .padding(.bottom, 14)
            }
        }
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if hasNote { toggle() } }
    }

    /// A booking with neither a note nor a link has nothing to open onto.
    private var hasNote: Bool { entry.summary != nil || !entry.links.isEmpty }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.startsAt) { return "Today" }
        if calendar.isDateInTomorrow(entry.startsAt) { return "Tomorrow" }
        if calendar.isDateInYesterday(entry.startsAt) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: entry.startsAt)
    }
}
