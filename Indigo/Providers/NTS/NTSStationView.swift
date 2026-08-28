//
//  NTSStationView.swift
//  Indigo
//
//  The station page. Everything on it comes from NTSProvider; the play button
//  hands a plain MediaItem to the coordinator.
//

import SwiftUI

struct NTSStationView: View {
    let stationID: String

    @Environment(AppState.self) private var appState
    @Environment(NTSProvider.self) private var nts
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            if let station {
                PageHeader(
                    title: station.name,
                    subtitle: "\(nts.displayName) · \(station.strapline)\(lastUpdatedSuffix)"
                ) {
                    playButton(station: station)
                }
                Rule(color: Palette.outline)
                body(for: station)
            } else {
                EmptyStateView(headline: "Unknown station", message: "That station is no longer available.") {
                    EmptyView()
                }
            }
        }
        .onAppear { nts.beginWatching() }
        .onDisappear { nts.endWatching() }
    }

    private var station: RadioStation? { nts.station(id: stationID) }
    private var state: RadioStationState? { nts.state(for: stationID) }
    private var show: RadioShow? { state?.now }

    private var isThisStationPlaying: Bool {
        player.isCurrent(stationID) && player.isPlaying
    }

    private var lastUpdatedSuffix: String {
        guard let updated = nts.lastUpdated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · Updated \(formatter.string(from: updated))"
    }

    // MARK: - Body states

    @ViewBuilder
    private func body(for station: RadioStation) -> some View {
        if show == nil, case .loading = nts.loadState {
            loading
        } else if show == nil, case .failed(let message) = nts.loadState {
            EmptyStateView(headline: "NTS unreachable", message: message) {
                Button("Try Again") { Task { await nts.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if let show {
            loaded(station: station, show: show)
        } else {
            EmptyStateView(headline: "Off air", message: "NTS isn't reporting a show on this channel right now.") {
                Button("Refresh") { Task { await nts.refresh() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 28) {
                Rectangle().fill(Palette.placeholder).frame(width: 300, height: 300)
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(Palette.placeholder).frame(width: 90, height: 12)
                    Rectangle().fill(Palette.placeholder).frame(height: 30)
                    Rectangle().fill(Palette.placeholder).frame(width: 220, height: 12)
                    Rectangle().fill(Palette.placeholder).frame(height: 60)
                }
            }
            MicroLabel(text: "Loading schedule")
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(0.7)
    }

    private func loaded(station: RadioStation, show: RadioShow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = nts.loadState {
                    NoticeStrip(text: "Showing the last known schedule. \(message)")
                        .padding(.bottom, 14)
                }

                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: show.artworkURL, side: 300)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        .overlay(alignment: .topLeading) {
                            LiveBadge()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Palette.paper)
                                .padding(10)
                        }

                    VStack(alignment: .leading, spacing: 16) {
                        onAirLine(show: show)

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let location = show.location {
                            Text(location)
                                .microLabel(1.4)
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if !tags.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(tags, id: \.self) { TagChip(text: $0) }
                            }
                        }

                        if let summary = show.summary, !summary.isEmpty {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                        HStack(spacing: 10) {
                            playButton(station: station, large: true)
                            if let ref = show.detailID.flatMap(NTSEpisodeRef.decode) {
                                Button("Tracklist") {
                                    appState.open(.ntsEpisode(show: ref.show, episode: ref.episode))
                                }
                                .buttonStyle(OutlineButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 30)

                if let next = state?.next {
                    Rule(color: Palette.outline)
                    upNext(next)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 22)
        }
        .scrollIndicators(.visible)
    }

    private func onAirLine(show: RadioShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("On air now").microLabel(1.6).foregroundStyle(Palette.live)
                if let slot = show.slot {
                    Text(slot)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                }
            }
            if let fraction = show.elapsedFraction() {
                ProgressTrack(fraction: fraction, tint: Palette.live)
                    .frame(width: 180)
            }
        }
    }

    private func upNext(_ next: RadioShow) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ArtworkView(remoteURL: next.artworkURL, side: 54)
                .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
            VStack(alignment: .leading, spacing: 4) {
                Text("Up next").microLabel(1.6).foregroundStyle(Palette.inkFaint)
                Text(next.title)
                    .font(Typeface.body(13, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let slot = next.slot {
                Text(slot)
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 18)
    }

    private var tags: [String] {
        guard let show else { return [] }
        return Array((show.genres + show.moods).prefix(6))
    }

    // MARK: - Play

    @ViewBuilder
    private func playButton(station: RadioStation, large: Bool = false) -> some View {
        Button {
            if player.isCurrent(station.id) {
                player.toggle()
            } else {
                player.playRadio(nts.mediaItem(for: station))
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

// MARK: - Wrapping tag layout

struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
