//
//  SourceResolver.swift
//  Indigo
//
//  The UI requests a recording. It does not choose its playback provider.
//
//      PLAY RECORDING
//          ↓
//      Local file?        YES ─→ PLAY LOCAL
//          ↓ NO
//      Known broadcast?   YES ─→ OPEN / SEEK SHOW
//          ↓ NO
//      Kept a link?       YES ─→ PLAY IN ITS OWN PLAYER
//          ↓ NO
//      No playable source
//

import Foundation
import SwiftData

nonisolated struct SourceResolver {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Every way this recording can currently be heard, best first.
    func resolve(_ recording: Recording) -> [AudioSource] {
        let local = LocalFileSource(context: context).sources(for: recording)
        let broadcast = BroadcastSource(context: context).sources(for: recording)
        let links = StreamingLinkSource(context: context).sources(for: recording)
        return (local + broadcast + links).sorted { $0.rank < $1.rank }
    }

    /// What pressing play should do.
    func best(_ recording: Recording) -> AudioSource? {
        resolve(recording).first
    }

    /// A crate card can have artwork even before recording metadata is enriched.
    /// Keep it as a fallback without replacing a source's own sleeve/local art.
    func best(_ item: CrateItem) -> AudioSource? {
        if let broadcast = item.broadcastMediaItem() {
            return AudioSource(kind: .broadcastAppearance, action: .play(broadcast),
                               label: BroadcastSource.label(for: item.providerID ?? ""),
                               detail: nil, rank: 0)
        }
        guard item.kind == .recording else { return nil }
        // This device's own recording knows its local file, which is always
        // the best way to hear it.
        if let recording = CrateRecordings(context: context).recording(for: item),
           let source = best(recording) {
            guard case .play(var media) = source.action,
                  media.remoteArtworkURL == nil, media.artworkKey == nil,
                  let artwork = item.artworkURL else { return source }
            media.remoteArtworkURL = artwork
            return AudioSource(kind: source.kind, action: .play(media), label: source.label,
                               detail: source.detail, rank: source.rank)
        }
        // A row kept on another device has no recording here yet, and does not
        // need one to play: the row itself kept where it was heard and a link.
        return fromSnapshot(item)
    }

    /// What a row can play from what it kept itself.
    private func fromSnapshot(_ item: CrateItem) -> AudioSource? {
        guard item.hasRecordingSnapshot else { return nil }
        var found: [AudioSource] = []
        if let provider = item.providerID, provider != "local", let showID = item.showID,
           let page = BroadcastSource.destination(showID: showID, providerID: provider) {
            found.append(AudioSource(
                kind: .broadcastAppearance,
                action: .openBroadcast(page, offsetSeconds: item.broadcastOffsetSeconds),
                label: BroadcastSource.label(for: provider),
                detail: item.showTitle,
                rank: 11))
        }
        if let link = item.playbackURLString, let url = URL(string: link),
           let provider = item.embedProviderRaw.flatMap(EmbedProvider.init(rawValue:))
            ?? (YouTubeLink.isYouTube(url) ? .youtube : nil) {
            found.append(AudioSource(
                kind: .streamingLink,
                action: .play(MediaItem(
                    id: "link.\(link)",
                    sourceID: item.embedProviderRaw ?? provider.rawValue,
                    kind: .track,
                    title: item.displayTitle,
                    subtitle: item.displaySubtitle,
                    detail: provider.displayName,
                    remoteArtworkURL: item.artworkURL,
                    playbackURL: url,
                    embedProvider: provider)),
                label: provider.displayName,
                detail: nil,
                rank: 20))
        }
        return found.min { $0.rank < $1.rank }
    }

    /// True when there is nothing to hear — the state the UI has to render
    /// honestly rather than showing a play button that does nothing.
    func isUnavailable(_ recording: Recording) -> Bool {
        resolve(recording).isEmpty
    }
}
