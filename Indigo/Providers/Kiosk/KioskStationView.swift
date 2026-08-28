//
//  KioskStationView.swift
//  Indigo
//
//  Kiosk's single channel. The calendar is the only thing Kiosk publishes about
//  what's on air, so the page leans on the schedule rather than show metadata.
//

import SwiftUI

struct KioskStationView: View {
    @Environment(KioskProvider.self) private var kiosk
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: kiosk.station.name,
                subtitle: "\(kiosk.station.strapline)\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { kiosk.beginWatching() }
        .onDisappear { kiosk.endWatching() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(kiosk.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = kiosk.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if kiosk.schedule.isEmpty, kiosk.loadState == .loading {
            LoadingPane(label: "Loading schedule")
        } else if kiosk.schedule.isEmpty, case .failed(let message) = kiosk.loadState {
            EmptyStateView(headline: "Kiosk unreachable", message: message) {
                Button("Try Again") { Task { await kiosk.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = kiosk.loadState {
                    NoticeStrip(text: "Showing the last known schedule. \(message)")
                        .padding(.bottom, 14)
                }

                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: kiosk.now?.artworkURL, side: 300)
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

                        Text(kiosk.onAir?.title ?? "Kiosk Radio")
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Parc Royal, Brussels")
                            .microLabel(1.4)
                            .foregroundStyle(Palette.inkMuted)

                        Text("A community web radio broadcasting round the clock from a wooden kiosk in Brussels' Parc Royal, drifting between genres since 2017.")
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                        playButton(large: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 30)

                schedule
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(kiosk.onAir == nil ? "Streaming" : "On air now")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = kiosk.onAir?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = kiosk.now?.elapsedFraction(at: kiosk.referenceDate) {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = Array(kiosk.upcoming.dropFirst(kiosk.onAir == nil ? 0 : 1).prefix(24))

        if !upcoming.isEmpty {
            Rule(color: Palette.outline)
            HStack {
                MicroLabel(text: "Coming up", color: Palette.ink)
                Spacer()
                Text("Brussels time")
                    .microLabel(1.2)
                    .foregroundStyle(Palette.inkFaint)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
            Rule()

            ForEach(upcoming) { entry in
                ScheduleRow(entry: entry)
                Rule()
            }
        }
    }

    // MARK: - Play

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(kiosk.station.id) {
                player.toggle()
            } else {
                player.playRadio(kiosk.mediaItem())
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

private struct ScheduleRow: View {
    let entry: KioskScheduleEntry

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
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
