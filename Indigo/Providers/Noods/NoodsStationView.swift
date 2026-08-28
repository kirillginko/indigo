//
//  NoodsStationView.swift
//  Indigo
//
//  Noods' live channel. Their own site reads its schedule through a RadioCult
//  key that belongs to them, so this page shows the stream and the archive
//  rather than inventing a schedule it can't stand behind.
//

import SwiftUI

struct NoodsStationView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoodsProvider.self) private var noods
    @Environment(NoodsBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private var isThisStationPlaying: Bool {
        player.isCurrent(noods.station.id) && player.isPlaying
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: noods.station.name, subtitle: noods.station.strapline) {
                playButton()
            }
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 28) {
                        ArtworkView(remoteURL: browse.latestPicks.first?.artworkURL, side: 280)
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                            .overlay(alignment: .topLeading) {
                                LiveBadge()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Palette.paper)
                                    .padding(10)
                            }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("On air")
                                .microLabel(1.6)
                                .foregroundStyle(Palette.live)
                            Text("Noods Radio")
                                .font(Typeface.display(30))
                                .tracking(-0.8)
                            Text("Bristol")
                                .microLabel(1.4)
                                .foregroundStyle(Palette.inkMuted)
                            Text("Independent radio from Bristol, broadcasting a rotating cast of residencies and guests since 2015.")
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            HStack(spacing: 10) {
                                playButton(large: true)
                                Button("Browse Shows") { appState.select(.noodsShows) }
                                    .buttonStyle(OutlineButtonStyle())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 30)

                    if !browse.latestPicks.isEmpty {
                        Rule(color: Palette.outline)
                        HStack {
                            Text("Latest shows").microLabel(1.8).foregroundStyle(Palette.ink)
                            Spacer()
                            Button("All") { appState.select(.noodsShows) }
                                .buttonStyle(.plain)
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 14)

                        NoodsShowGrid(shows: Array(browse.latestPicks.prefix(8)))
                    }
                }
                .padding(.bottom, 26)
            }
            .scrollIndicators(.visible)
        }
        .task { await browse.loadDiscoverIfNeeded() }
    }

    private func playButton(large: Bool = false) -> some View {
        Button {
            if player.isCurrent(noods.station.id) {
                player.toggle()
            } else {
                player.playRadio(noods.mediaItem())
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
