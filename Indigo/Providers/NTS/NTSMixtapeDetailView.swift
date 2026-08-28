//
//  NTSMixtapeDetailView.swift
//  Indigo
//
//  An infinite mixtape in full: what it is, and which residencies feed it.
//  The credits are the useful part — each one is a way back into browsing.
//

import SwiftUI

struct NTSMixtapeDetailView: View {
    let alias: String

    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private let creditColumns = [GridItem(.adaptive(minimum: 190), spacing: 0, alignment: .leading)]

    var body: some View {
        VStack(spacing: 0) {
            if let mixtape = browse.mixtape(alias: alias) {
                PageHeader(
                    title: mixtape.title,
                    breadcrumb: appState.breadcrumbTitle,
                    onBack: { appState.popDetail() },
                    subtitle: subtitle(mixtape)
                ) {
                    playButton(mixtape)
                }
                Rule(color: Palette.outline)
                content(mixtape)
            } else {
                PageHeader(
                    title: "Mixtape",
                    breadcrumb: appState.breadcrumbTitle,
                    onBack: { appState.popDetail() }
                )
                Rule(color: Palette.outline)
                if browse.mixtapes.isLoading {
                    LoadingPane(label: "Loading mixtape")
                } else {
                    EmptyStateView(headline: "Mixtape unavailable",
                                   message: "NTS isn't listing this channel any more.") {
                        Button("Back to Mixtapes") { appState.popDetail() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .task { await browse.loadMixtapesIfNeeded() }
    }

    private func content(_ mixtape: NTSMixtape) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    ArtworkView(remoteURL: mixtape.artworkURL, side: 260)
                        .overlay(Rectangle().strokeBorder(
                            isPlaying ? Palette.live : Palette.outline,
                            lineWidth: isPlaying ? 1.5 : Metrics.hairline
                        ))
                        .overlay(alignment: .topLeading) {
                            if isPlaying {
                                LiveBadge()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Palette.paper)
                                    .padding(10)
                            }
                        }

                    VStack(alignment: .leading, spacing: 16) {
                        if let subtitle = mixtape.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(Typeface.body(15, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let summary = mixtape.summary, !summary.isEmpty {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        playButton(mixtape, large: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 30)

                if !mixtape.credits.isEmpty {
                    Rule(color: Palette.outline)
                    HStack {
                        MicroLabel(text: "Featuring", color: Palette.ink)
                        Spacer()
                        Text("\(mixtape.credits.count) shows")
                            .microLabel(1.2)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()

                    LazyVGrid(columns: creditColumns, spacing: 0) {
                        ForEach(mixtape.credits) { credit in
                            CreditRow(credit: credit) {
                                guard let destination = credit.destination else { return }
                                appState.open(destination)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 6)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var isPlaying: Bool {
        guard let mixtape = browse.mixtape(alias: alias) else { return false }
        return player.isCurrent(browse.mediaItem(for: mixtape).id) && player.isPlaying
    }

    private func subtitle(_ mixtape: NTSMixtape) -> String {
        var parts = ["NTS Mixtape"]
        if !mixtape.credits.isEmpty { parts.append("\(mixtape.credits.count) shows") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func playButton(_ mixtape: NTSMixtape, large: Bool = false) -> some View {
        Button {
            let item = browse.mediaItem(for: mixtape)
            if player.isCurrent(item.id) {
                player.toggle()
            } else {
                player.playRadio(item)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isPlaying ? "Pause" : "Listen")
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

private struct CreditRow: View {
    let credit: NTSMixtapeShow
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(credit.name)
                    .font(Typeface.body(12))
                    .foregroundStyle(credit.destination == nil ? Palette.inkMuted : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if credit.destination != nil {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(isHovering ? Palette.ink : Palette.inkFaint.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovering && credit.destination != nil ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(credit.destination == nil)
        .onHover { isHovering = $0 }
    }
}
