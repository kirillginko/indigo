//
//  RecordingDigView.swift
//  Indigo
//
//  One piece of music: where it was heard, and what was heard beside it.
//
//  This is the page the spec lays out for an unknown recording, and it is the
//  right page for a named one too. A catalogue can tell you what a track is.
//  Only a listening history can tell you that it turned up in four of the same
//  shows as something else — which is the connection worth following, and the
//  one nothing else in the app was surfacing.
//

import SwiftUI
import SwiftData

struct RecordingDigView: View {
    let recordingID: UUID
    let fallbackTitle: String

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    @State private var neighbourhood: MusicGraph?

    var body: some View {
        let _ = dig.revision
        let _ = crate.revision

        Group {
            if let recording = fetch() {
                content(recording)
            } else {
                EmptyStateView(
                    headline: fallbackTitle,
                    message: "Indigo no longer has this recording."
                ) { EmptyView() }
            }
        }
        .task(id: recordingID) {
            guard let recording = fetch() else { return }
            // The co-appearance walk reads the whole appearance log, so it is
            // done once here rather than during a redraw.
            neighbourhood = RadioNeighborhoodEngine(context: dig.context).graph(around: recording)
            await dig.resolveRelease(for: recording)
        }
    }

    @ViewBuilder
    private func content(_ recording: Recording) -> some View {
        let release = dig.releaseDetail(for: recording)
        let node = MusicNode.recording(recording, artwork: release.artwork)
        let connections = neighbourhood?.connections(from: node) ?? []

        VStack(spacing: 0) {
            PageHeader(
                title: recording.displayTitle,
                subtitle: [recording.displayArtist, release.line].compactMap { $0 }.joined(separator: " · ")
            ) {
                HStack(spacing: 10) {
                    if let artist = recording.displayArtist {
                        DigButton { appState.open(.digArtist(mbid: nil, name: artist)) }
                    }
                    CrateButton(isCrated: crate.contains(recording: recording)) {
                        crate.toggle(recording: recording)
                    }
                }
            }
            Rule(color: Palette.outline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 18) {
                        ArtworkView(remoteURL: release.artwork, side: 128, glyphScale: 0.22,
                                    placeholder: .whiteLabel,
                                    markURL: StationMark.logoURL(for: recording.firstAppearance?.providerID))
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        VStack(alignment: .leading, spacing: 10) {
                            DigTallies(entries: tallies(recording, connections: connections))
                            if let status = statusLine(recording) {
                                Text(status)
                                    .font(Typeface.mono(9.5))
                                    .foregroundStyle(Palette.inkFaint)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    appearances(recording)

                    playedAlongside(connections)

                    DeepSectionView(origin: node, isReady: neighbourhood != nil) { appState.open($0) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: Where it was heard

    /// The spec's KNOWN APPEARANCES: every time this turned up on air, and a
    /// way back to the hour it turned up in.
    @ViewBuilder
    private func appearances(_ recording: Recording) -> some View {
        let heard = recording.appearances.sorted { $0.heardAt > $1.heardAt }
        if heard.isEmpty, neighbourhood == nil {
            // Veiled rather than swept. The rest of this page is local and
            // already there, so this is the one part still arriving — but it
            // should arrive the way everything else in Indigo does.
            DigSection(title: "Known appearances") {
                DigSkeleton(hasImage: false, sections: 0)
                    .padding(.vertical, 10)
                    .loadingVeil(true)
            }
        } else if heard.isEmpty {
            DigSection(title: "Known appearances") {
                Text("Not heard on air yet.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.vertical, 6)
            }
        } else {
            DigSection(title: "Known appearances", trailing: "\(heard.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(heard) { appearance in
                        DigLine(
                            text: appearance.sourceLine,
                            detail: [appearance.dateLabel, appearance.offsetLabel]
                                .compactMap { $0 }.joined(separator: "  "),
                            action: destination(for: appearance).map { page in
                                { appState.open(page) }
                            }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func destination(for appearance: MediaAppearance) -> DetailPage? {
        guard let showID = appearance.showID else { return nil }
        return BroadcastSource.destination(showID: showID, providerID: appearance.providerID)
    }

    // MARK: What was heard beside it

    /// The part no catalogue holds. Two records that keep turning up in the
    /// same hours are connected by whoever kept putting them there, and that
    /// is a better recommendation than any similarity score.
    @ViewBuilder
    private func playedAlongside(_ connections: [MusicGraph.Connection]) -> some View {
        let peers = connections
            .filter { $0.to.kind == .recording || $0.to.kind == .unknownRecording }
        if !peers.isEmpty {
            DigSection(title: "Played alongside", trailing: "\(peers.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(peers) { peer in
                        AlongsideRow(connection: peer) {
                            guard let identifier = peer.to.recordingID else { return }
                            appState.open(.digRecording(id: identifier, title: peer.to.title))
                        }
                        Rule()
                    }
                }
            }
        }
    }

    // MARK: Furniture

    private func tallies(
        _ recording: Recording,
        connections: [MusicGraph.Connection]
    ) -> [(label: String, value: String)] {
        let shows = Set(recording.appearances.compactMap(\.showID)).count
        let peers = connections.filter { $0.to.kind == .recording || $0.to.kind == .unknownRecording }
        return [
            ("Shows", "\(shows)"),
            ("Appearances", "\(recording.appearances.count)"),
            ("Played alongside", "\(peers.count)")
        ]
    }

    private func statusLine(_ recording: Recording) -> String? {
        guard let first = recording.firstAppearance else { return nil }
        return "First heard \(first.dateLabel.capitalized) · \(first.sourceLine)"
    }

    private func fetch() -> Recording? {
        let identifier = recordingID
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == identifier })
        descriptor.fetchLimit = 1
        return (try? dig.context.fetch(descriptor))?.first
    }
}

/// One record heard beside this one, and how often — "played in 4 of the same
/// shows" is the whole reason the row is here.
private struct AlongsideRow: View {
    let connection: MusicGraph.Connection
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Text(connection.to.kind.label)
                    .font(Typeface.mono(8.5))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: 76, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.to.title)
                        .font(Typeface.body(12.5, weight: .medium))
                        .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                        .lineLimit(1)
                    if let subtitle = connection.to.subtitle {
                        Text(subtitle)
                            .font(Typeface.body(11))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(1)
                    }
                    if let why = connection.why {
                        Text(why.summary())
                            .font(Typeface.mono(9.5))
                            .foregroundStyle(Palette.inkFaint)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ConfidenceMark(band: connection.confidenceBand)
                    .padding(.top, 3)

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
                    .padding(.top, 2)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
