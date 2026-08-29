//
//  CashmereStationView.swift
//  Indigo
//
//  Cashmere's house channel. It runs on Airtime, which knows both the show on
//  the air and the file playing inside it, so the page can say both — and the
//  station's side channels, when it has any up, are listed underneath.
//

import SwiftUI

struct CashmereStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(CashmereBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Cashmere Radio",
                subtitle: "Lichtenberg, Berlin\(lastUpdatedSuffix)"
            ) {
                playButton()
            }
            Rule(color: Palette.outline)
            content
        }
        .onAppear { cashmere.beginWatching() }
        .onDisappear { cashmere.endWatching() }
        .task { await browse.loadShowsIfNeeded() }
    }

    private var isThisStationPlaying: Bool {
        player.isCurrent(cashmere.station.id) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = cashmere.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    @ViewBuilder
    private var content: some View {
        if cashmere.onAir == nil, cashmere.loadState == .loading {
            LoadingPane(label: "Tuning in")
        } else if cashmere.onAir == nil, case .failed(let message) = cashmere.loadState {
            EmptyStateView(headline: "Cashmere unreachable", message: message) {
                Button("Try Again") { Task { await cashmere.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            loaded
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = cashmere.loadState {
                    NoticeStrip(text: "Showing the last known state. \(message)")
                        .padding(.bottom, 14)
                }

                hero
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 30)

                if !cashmere.extraStreams.isEmpty { sideChannels }
                schedule
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            // Airtime carries no artwork, but the show on air is usually one
            // Cashmere archives — so its latest episode's picture is the
            // truest image the station has of what you are hearing.
            ArtworkView(
                remoteURL: onAirArtwork,
                side: 300,
                markURL: CashmereProvider.logoURL,
                mark: "Cashmere Radio"
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

                Text(cashmere.onAir?.showName ?? "Cashmere Radio")
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let track = cashmere.onAir?.trackTitle, track != cashmere.onAir?.showName {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel(text: "Playing")
                        Text(track)
                            .font(Typeface.body(12.5, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let artist = cashmere.onAir?.trackArtist {
                            Text(artist)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Lichtenberg, Berlin")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkMuted)

                Text("A community radio station broadcasting from a former grocer's shop in Berlin-Lichtenberg since 2015, run by an open collective of residents and guests.")
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let show = onAirShow {
                    Button {
                        appState.open(.cashmereShow(slug: show.slug))
                    } label: {
                        Text("Open \(show.name)")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let next = cashmere.upNext {
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

    /// Airtime names the show; the archive is what knows its face.
    private var onAirShow: CashmereShow? {
        if let slug = cashmere.onAir?.showSlug, let show = browse.show(slug: slug) { return show }
        guard let name = cashmere.onAir?.showName else { return nil }
        return browse.shows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var onAirArtwork: URL? {
        guard let show = onAirShow else { return nil }
        return browse.episodes(ofShow: show.slug).first?.artworkURL
    }

    private var onAirLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(cashmere.onAir?.showName == nil ? "Streaming" : "On air now")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.live)
                if let slot = cashmere.onAir?.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = cashmere.onAir?.elapsedFraction {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    // MARK: - Side channels

    private var sideChannels: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Also streaming", trailing: nil)
            ForEach(cashmere.extraStreams) { stream in
                let item = cashmere.mediaItem(for: stream)
                HStack(spacing: 14) {
                    Text(stream.title)
                        .font(Typeface.body(12.5))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(player.isCurrent(item.id) && player.isPlaying ? "Pause" : "Listen") {
                        if player.isCurrent(item.id) { player.toggle() } else { player.playRadio(item) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 8)
                Rule()
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var schedule: some View {
        let upcoming = cashmere.upcoming
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Coming up", trailing: "Berlin time")
                ForEach(upcoming) { slot in
                    HStack(spacing: 14) {
                        Text(slot.slot)
                            .font(Typeface.mono(10.5))
                            .foregroundStyle(Palette.inkMuted)
                            .monospacedDigit()
                            .frame(width: 96, alignment: .leading)
                        Text(slot.title)
                            .font(Typeface.body(12.5))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .frame(height: Metrics.rowHeight)
                    Rule()
                }
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            HStack {
                MicroLabel(text: title, color: Palette.ink)
                Spacer()
                if let trailing {
                    Text(trailing).microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
            Rule()
        }
    }

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(cashmere.station.id) {
                player.toggle()
            } else {
                player.playRadio(cashmere.mediaItem())
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
