//
//  StreamingLinkSource.swift
//  Indigo
//
//  A recording that can be played straight from a link — a YouTube upload of a
//  track, kept when the listener crated it off a release page.
//
//  Ranked below a local file and below a broadcast, deliberately. Somebody's
//  own copy is better than anybody's, and hearing a track inside the show it
//  was played in is the thing this app is for; a video of it is the fallback,
//  not the point.
//

import Foundation
import SwiftData

nonisolated struct StreamingLinkSource {
    let context: ModelContext

    func sources(for recording: Recording) -> [AudioSource] {
        // The sleeve the recording already has. Without it a kept track plays
        // with an empty square in the player bar, which is the one picture the
        // listener always has in front of them.
        let identifier = recording.id
        var descriptor = FetchDescriptor<RecordingMetadata>(
            predicate: #Predicate { $0.recordingID == identifier }
        )
        descriptor.fetchLimit = 1
        let artwork = (try? context.fetch(descriptor))?.first?.artworkURL

        return recording.sources
            .filter { $0.kind == .streamingLink }
            .compactMap { link -> AudioSource? in
                guard let url = URL(string: link.identifier),
                      let provider = Self.provider(for: link, url: url)
                else { return nil }
                return AudioSource(
                    kind: .streamingLink,
                    action: .play(MediaItem(
                        id: "link.\(link.identifier)",
                        sourceID: link.providerID ?? provider.rawValue,
                        kind: .track,
                        title: recording.displayTitle,
                        subtitle: recording.displayArtist,
                        detail: provider.displayName,
                        remoteArtworkURL: artwork,
                        playbackURL: url,
                        embedProvider: provider
                    )),
                    label: provider.displayName,
                    detail: nil,
                    rank: 20
                )
            }
    }

    /// Which player a link belongs to. Read from the address rather than
    /// trusted from the stored provider id, so a row written by an older
    /// build still resolves.
    static func provider(for link: RecordingSource, url: URL) -> EmbedProvider? {
        if let stored = link.providerID.flatMap(EmbedProvider.init(rawValue:)) { return stored }
        if YouTubeLink.isYouTube(url) { return .youtube }
        guard let host = url.host()?.lowercased() else { return nil }
        if host.contains("soundcloud.com") { return .soundcloud }
        if host.contains("mixcloud.com") { return .mixcloud }
        return nil
    }
}
