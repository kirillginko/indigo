//
//  NoodsShowDetailView.swift
//  Indigo
//
//  One Noods show. Unlike Kiosk, Noods publishes tracklists — so this is a
//  page worth opening rather than just a thing to press play on.
//

import SwiftUI

struct NoodsShowDetailView: View {
    let showPath: String

    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate

    var body: some View {
        let detail = browse.showDetail(path: showPath)

        VStack(spacing: 0) {
            PageHeader(
                title: detail?.show.title ?? NoodsPath.slug(showPath)
                    .replacingOccurrences(of: "-", with: " ").capitalized,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(detail)
            ) {
                if let resident = detail?.show.residentPath {
                    Button("Resident") { appState.open(.noodsResident(path: resident)) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            Rule(color: Palette.outline)

            if let detail {
                content(detail)
            } else if let error = browse.showError(path: showPath) {
                EmptyStateView(headline: "Couldn't load this show", message: error) {
                    Button("Try Again") { Task { await browse.loadShowIfNeeded(path: showPath) } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                LoadingPane(label: "Loading show")
            }
        }
        .task(id: showPath) { await browse.loadShowIfNeeded(path: showPath) }
    }

    private func subtitle(_ detail: NoodsShowDetail?) -> String? {
        guard let detail else { return nil }
        var parts: [String] = []
        if let artist = detail.show.artist { parts.append(artist) }
        if let aired = detail.show.airedLabel { parts.append(aired) }
        if detail.isGuestMix { parts.append("Guest mix") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func content(_ detail: NoodsShowDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    ArtworkView(remoteURL: detail.show.artworkURL, side: 240)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 14) {
                        if !detail.show.genres.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(detail.show.genres.prefix(8), id: \.self) { TagChip(text: $0) }
                            }
                        }
                        if let summary = detail.summary, !summary.isEmpty {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        controls(detail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 30)

                tracklist(detail)

                if !detail.similar.isEmpty {
                    Rule(color: Palette.outline)
                    HStack {
                        Text("Similar shows").microLabel(1.8).foregroundStyle(Palette.ink)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    NoodsShowGrid(shows: detail.similar)
                }
            }
            .padding(.bottom, 26)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func controls(_ detail: NoodsShowDetail) -> some View {
        let show = detail.show
        VStack(alignment: .leading, spacing: 8) {
            if let item = show.mediaItem() {
                HStack(spacing: 10) {
                    Button {
                        NoodsPlayback.toggle(show, within: [show], using: player)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: NoodsPlayback.isPlaying(show, in: player)
                                  ? "pause.fill" : "play.fill")
                                .font(.system(size: 11))
                            Text(NoodsPlayback.isPlaying(show, in: player) ? "Pause" : "Play Show")
                                .microLabel(1.4, size: 11)
                        }
                        .foregroundStyle(Palette.inverseInk)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(Palette.inverse)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    let _ = crate.revision
                    CrateButton(isCrated: crate.contains(broadcast: item.id, providerID: item.sourceID)) {
                        crate.toggle(nowPlaying: item)
                    }
                }
                Text("Audio hosted by \(show.audio?.provider.displayName ?? "the broadcaster")")
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(Palette.inkFaint)
            } else {
                Text("Noods hasn't published audio for this show.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func tracklist(_ detail: NoodsShowDetail) -> some View {
        Rule(color: Palette.outline)
        HStack {
            MicroLabel(text: "Tracklist", color: Palette.ink)
            Spacer()
            Text(detail.tracklist.isEmpty
                 ? "Unavailable"
                 : "\(detail.tracklist.count) \(detail.tracklist.count == 1 ? "track" : "tracks")")
                .microLabel(1.2)
                .foregroundStyle(Palette.inkFaint)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 14)

        if detail.tracklist.isEmpty {
            Text("Noods only publishes tracklists for some shows.")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
                .background(Palette.wash)
        } else {
            Rule()
            ForEach(Array(detail.tracklist.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                    Text(entry)
                        .font(Typeface.body(12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    RadioTracklistCrateButton(item: RadioTracklistItem(
                        providerID: "noods", showID: detail.show.slug,
                        showTitle: detail.show.title, airedAt: detail.show.airedAt,
                        entryID: "\(index)", title: entry, artist: nil, offsetSeconds: nil
                    ))
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(minHeight: Metrics.rowHeight)
                Rule()
            }
        }
    }
}
