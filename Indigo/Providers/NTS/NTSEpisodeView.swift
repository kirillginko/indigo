//
//  NTSEpisodeView.swift
//  Indigo
//
//  One episode and its tracklist. NTS hosts archive audio on SoundCloud and
//  Mixcloud rather than serving a stream, so this page links out for listening
//  instead of showing a play button that couldn't work.
//

import SwiftUI

struct NTSEpisodeView: View {
    let showAlias: String
    let episodeAlias: String

    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse
    @Environment(DigStore.self) private var dig
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate

    var body: some View {
        let detail = browse.detail(show: showAlias, episode: episodeAlias)
        let error = browse.detailError(show: showAlias, episode: episodeAlias)

        VStack(spacing: 0) {
            PageHeader(
                title: detail?.summary.name ?? displayAlias,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(detail?.summary)
            ) {
                if let detail, !detail.summary.showAlias.isEmpty {
                    Button("All Episodes") {
                        appState.open(.ntsShow(alias: detail.summary.showAlias))
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            Rule(color: Palette.outline)

            if let detail {
                content(detail)
            } else if let error {
                EmptyStateView(headline: "Couldn't load this episode", message: error) {
                    Button("Try Again") {
                        Task { await browse.loadDetail(show: showAlias, episode: episodeAlias) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            } else {
                LoadingPane(label: "Loading tracklist")
            }
        }
        .task(id: episodeAlias) {
            await browse.loadDetailIfNeeded(show: showAlias, episode: episodeAlias)
        }
    }

    // MARK: Content

    private func content(_ detail: NTSEpisodeDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    ArtworkView(remoteURL: detail.summary.artworkURL, side: 240)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 14) {
                        if !tags(detail).isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(tags(detail), id: \.self) { TagChip(text: $0) }
                            }
                        }

                        if let summary = detail.summary.summary, !summary.isEmpty {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        listenControls(detail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 30)

                tracklist(detail)
                    // Fill in what the rows are actually of, now that
                    // somebody is looking at them.
                    .task(id: detail.summary.id) {
                        await dig.resolveBroadcastTracklist(
                            providerID: "nts", showID: detail.summary.id
                        )
                    }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func tracklist(_ detail: NTSEpisodeDetail) -> some View {
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
            VStack(alignment: .leading, spacing: 6) {
                Text("No tracklist for this episode.")
                    .font(Typeface.body(12.5))
                    .foregroundStyle(Palette.inkMuted)
                Text(detail.summary.isPublished
                     ? "NTS only publishes tracklists for some shows."
                     : "Tracklists appear after a show has aired.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 22)
            .background(Palette.wash)
        } else {
            Rule()
            // NTS times only some tracks. Mixing "2:34" and "4" in one column
            // reads as nonsense, so the column commits to one or the other.
            let timed = detail.tracklist.contains { $0.offsetLabel != nil }
            // Resolved once for the episode rather than once per row. A row
            // that looks its own release up re-runs the fetch every time it
            // redraws, and a tracklist redraws on every hover.
            let rows = resolvedRows(detail)
            ForEach(Array(detail.tracklist.enumerated()), id: \.element.id) { index, entry in
                TracklistRow(
                    index: index + 1,
                    entry: entry,
                    detail: detail,
                    showsTimestamps: timed,
                    release: rows[entry.id] ?? (nil, nil, nil)
                )
                Rule()
            }
        }
    }

    /// What each row turned out to be, keyed by tracklist entry.
    ///
    /// Carries the recording as well as the sleeve now: the id is what makes
    /// the title openable, and it exists for a row whether or not a catalogue
    /// has produced artwork for it.
    private func resolvedRows(
        _ detail: NTSEpisodeDetail
    ) -> [String: (recordingID: UUID?, line: String?, artwork: URL?)] {
        let _ = dig.revision
        let engine = RadioNeighborhoodEngine(context: dig.context)
        var found: [String: (recordingID: UUID?, line: String?, artwork: URL?)] = [:]
        for entry in detail.tracklist {
            guard let recording = engine.recording(for: entry, in: detail) else { continue }
            let release = dig.releaseDetail(for: recording)
            found[entry.id] = (recording.id, release.line, release.artwork)
        }
        return found
    }

    // MARK: Listening

    @ViewBuilder
    private func listenControls(_ detail: NTSEpisodeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = detail.mediaItem(), let source = detail.playbackSource {
                Button {
                    if player.isCurrent(item.id) {
                        player.toggle()
                    } else {
                        player.playEpisode(item)
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: isPlayingThisEpisode(item) ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(isPlayingThisEpisode(item) ? "Pause" : "Play Episode")
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
                HStack(spacing: 10) {
                    CrateButton(isCrated: crate.contains(broadcast: item.id, providerID: item.sourceID)) {
                        crate.toggle(nowPlaying: item)
                    }
                    Text("Audio hosted by \(source.provider?.displayName ?? source.displayName)")
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                }
            } else if detail.summary.isPublished {
                Text("NTS hasn't published audio for this episode.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
            } else {
                Text("Not broadcast yet.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
            }
        }
    }

    private func isPlayingThisEpisode(_ item: MediaItem) -> Bool {
        player.isCurrent(item.id) && player.isPlaying
    }

    // MARK: Helpers

    private func tags(_ detail: NTSEpisodeDetail) -> [String] {
        Array((detail.summary.genres + detail.summary.moods).prefix(6))
    }

    private var displayAlias: String {
        episodeAlias.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func subtitle(_ summary: NTSEpisodeSummary?) -> String? {
        guard let summary else { return nil }
        var parts: [String] = []
        if let broadcast = summary.broadcastLabel { parts.append(broadcast) }
        if let location = summary.location { parts.append(location) }
        if !summary.isPublished { parts.append("Not yet aired") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct TracklistRow: View {
    let index: Int
    let entry: NTSTracklistEntry
    let detail: NTSEpisodeDetail
    let showsTimestamps: Bool
    /// Resolved by the episode, not by the row — see `resolvedRows`.
    let release: (recordingID: UUID?, line: String?, artwork: URL?)

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @State private var isHovering = false
    @State private var isHoveringTitle = false

    private var marker: String {
        guard showsTimestamps else { return "\(index)" }
        return entry.offsetLabel ?? "—"
    }

    var body: some View {
        let _ = crate.revision
        HStack(spacing: 12) {
            Text(marker)
                .font(Typeface.mono(10))
                .foregroundStyle(entry.offsetLabel == nil && showsTimestamps
                                 ? Palette.inkFaint.opacity(0.5)
                                 : Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)

            ArtworkView(remoteURL: release.artwork, side: 30, glyphScale: 0.3)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 2) {
                // The spec's line: every track is somewhere you can go. The
                // page it opens is where this piece of music was heard and
                // what was heard beside it, which is the question a tracklist
                // makes you want to ask.
                //
                // A row only becomes a link once local ingestion has given it
                // a recording. That happens when the episode loads, so it is
                // a moment rather than a wait — but until then the title is
                // text, because a link to nothing is worse than no link.
                if let recordingID = release.recordingID {
                    Button {
                        appState.open(.digRecording(id: recordingID, title: entry.title))
                    } label: {
                        Text(entry.title)
                            .font(Typeface.body(12.5, weight: .medium))
                            .foregroundStyle(isHoveringTitle ? Palette.accent : Palette.ink)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                } else {
                    Text(entry.title)
                        .font(Typeface.body(12.5))
                        .lineLimit(1)
                }
                // Nothing at all until the catalogue has answered. An empty
                // line reserved for a release reads as a missing release.
                if let line = release.line {
                    Text(line)
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The way in. Every name here is an artist Indigo now keeps —
            // ingesting a tracklist creates one for a name no catalogue has —
            // and until this was navigable those were pages nothing could
            // reach. A selector naming a record is the beginning of a dig, so
            // it has to be the beginning of one on screen too.
            TracklistArtist(name: entry.artist)

            CrateGlyphButton(isCrated: crate.isCrated(tracklistEntry: entry, in: detail)) {
                if let recording = crate.toggle(tracklistEntry: entry, in: detail) {
                    Task { await dig.enrichCratedRecording(recording) }
                }
            }
            .help(crate.isCrated(tracklistEntry: entry, in: detail)
                  ? "Remove \(entry.title) from crate"
                  : "Add \(entry.title) to crate")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.rowHeight)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .textSelection(.enabled)
    }
}

/// The credit on a tracklist row, as a way into DIG.
///
/// "Unknown Artist" is what the ingester writes when a selector did not say,
/// and it is not a page — it stays plain text rather than becoming a link to
/// everything nobody identified.
private struct TracklistArtist: View {
    let name: String

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        if ArtistName.isRealArtist(name) {
            Button { appState.open(.digArtist(mbid: nil, name: name)) } label: {
                Text(name)
                    .font(Typeface.body(12))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: 260, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        } else {
            Text(name)
                .font(Typeface.body(12))
                .foregroundStyle(Palette.inkFaint)
                .lineLimit(1)
                .frame(width: 260, alignment: .leading)
        }
    }
}
