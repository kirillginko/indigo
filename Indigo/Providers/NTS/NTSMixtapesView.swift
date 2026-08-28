//
//  NTSMixtapesView.swift
//  Indigo
//
//  NTS's infinite mixtapes — genre channels that stream around the clock. They
//  are live streams like NTS 1 and 2, so the existing player handles them.
//

import SwiftUI

struct NTSMixtapesView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let mixtapes = browse.mixtapes

        VStack(spacing: 0) {
            PageHeader(
                title: "Mixtapes",
                subtitle: mixtapes.items.isEmpty
                    ? "Always-on NTS channels"
                    : "\(mixtapes.items.count) always-on channels"
            )
            Rule(color: Palette.outline)

            if mixtapes.items.isEmpty, mixtapes.isLoading {
                LoadingPane(label: "Loading mixtapes")
            } else if mixtapes.items.isEmpty, let error = mixtapes.error {
                EmptyStateView(headline: "NTS unreachable", message: error) {
                    Button("Try Again") { Task { await browse.loadMixtapesIfNeeded() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(mixtapes.items) { mixtape in
                            MixtapeTile(
                                mixtape: mixtape,
                                isPlaying: isPlaying(mixtape),
                                open: { appState.open(.ntsMixtape(alias: mixtape.alias)) },
                                play: { toggle(mixtape) }
                            )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
        .task { await browse.loadMixtapesIfNeeded() }
    }

    private func isPlaying(_ mixtape: NTSMixtape) -> Bool {
        player.isCurrent(browse.mediaItem(for: mixtape).id) && player.isPlaying
    }

    private func toggle(_ mixtape: NTSMixtape) {
        let item = browse.mediaItem(for: mixtape)
        if player.isCurrent(item.id) {
            player.toggle()
        } else {
            player.playRadio(item)
        }
    }
}

private struct MixtapeTile: View {
    let mixtape: NTSMixtape
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(remoteURL: mixtape.artworkURL)
                .overlay(Rectangle().strokeBorder(
                    isPlaying ? Palette.live : Palette.rule,
                    lineWidth: isPlaying ? 1.5 : Metrics.hairline
                ))
                .overlay(alignment: .topLeading) {
                    if isPlaying {
                        LiveBadge()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Palette.paper)
                            .padding(8)
                    }
                }
                // A nested Button wins the click, so the tile opens the detail
                // page and this still plays without them fighting.
                .overlay(alignment: .bottomTrailing) {
                    if isHovering || isPlaying {
                        Button(action: play) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inverseInk)
                                .frame(width: 28, height: 28)
                                .background(Palette.inverse)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Pause \(mixtape.title)" : "Play \(mixtape.title)")
                        .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(mixtape.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = mixtape.subtitle {
                    Text(subtitle)
                        .font(Typeface.body(11))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mixtape.title)
    }
}
