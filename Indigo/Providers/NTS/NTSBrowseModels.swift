//
//  NTSBrowseModels.swift
//  Indigo
//
//  Wire format for the browsable parts of the NTS API — shows, episodes,
//  tracklists and infinite mixtapes — plus the provider-independent shapes the
//  UI actually renders.
//

import Foundation

// MARK: - Paging

nonisolated struct NTSPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let metadata: NTSPageMetadata?
    let results: [Item]

    var total: Int { metadata?.resultset?.count ?? results.count }
    var offset: Int { metadata?.resultset?.offset ?? 0 }
}

nonisolated struct NTSPageMetadata: Decodable, Sendable {
    let resultset: NTSResultSet?
}

nonisolated struct NTSResultSet: Decodable, Sendable {
    let count: Int?
    let offset: Int?
    let limit: Int?
}

// MARK: - Wire types

nonisolated struct NTSShowDTO: Decodable, Sendable {
    let name: String?
    let description: String?
    let showAlias: String?
    let locationLong: String?
    let locationShort: String?
    let media: NTSMedia?
    let genres: [NTSTag]?
    let moods: [NTSTag]?
}

nonisolated struct NTSEpisodeDTO: Decodable, Sendable {
    let name: String?
    let description: String?
    let status: String?
    let episodeAlias: String?
    let showAlias: String?
    let broadcast: String?
    let locationLong: String?
    let locationShort: String?
    let media: NTSMedia?
    let genres: [NTSTag]?
    let moods: [NTSTag]?
    let audioSources: [NTSAudioSourceDTO]?
    let mixcloud: String?
    let embeds: NTSEpisodeEmbeds?
}

nonisolated struct NTSAudioSourceDTO: Decodable, Sendable {
    let url: String?
    let source: String?
}

/// `embeds.tracklist` is an object with `results` when a tracklist exists and a
/// bare `[]` when it doesn't, so it cannot be decoded as one fixed shape.
nonisolated struct NTSEpisodeEmbeds: Decodable, Sendable {
    let tracklist: [NTSTrackDTO]

    private enum CodingKeys: String, CodingKey { case tracklist }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let page = try? container.decode(NTSPage<NTSTrackDTO>.self, forKey: .tracklist) {
            tracklist = page.results
        } else {
            tracklist = []
        }
    }
}

nonisolated struct NTSTrackDTO: Decodable, Sendable {
    let uid: String?
    let artist: String?
    let title: String?
    let offset: Int?
    /// NTS falls back to this when it couldn't pin the exact start.
    let offsetEstimate: Int?
    let duration: Int?
}

nonisolated struct NTSMixtapeDTO: Decodable, Sendable {
    let mixtapeAlias: String?
    let title: String?
    let subtitle: String?
    let description: String?
    let audioStreamEndpoint: String?
    let media: NTSMedia?
    /// The residencies feeding this channel.
    let credits: [NTSMixtapeCredit]?
}

nonisolated struct NTSMixtapeCredit: Decodable, Sendable {
    let name: String?
    let path: String?
}

nonisolated struct NTSMixtapeShow: Identifiable, Hashable, Sendable {
    let name: String
    let showAlias: String?
    let episodeAlias: String?
    let path: String?

    /// Several credits can point into the same show (NTS files one-off guest
    /// sets under /shows/guests/episodes/...), so the alias alone is not a
    /// unique identity — using it drops every credit after the first.
    var id: String { "\(path ?? "")|\(name)" }

    /// A credit naming one broadcast should open that broadcast, not the
    /// catch-all show it was filed under.
    var destination: DetailPage? {
        if let showAlias, let episodeAlias {
            return .ntsEpisode(show: showAlias, episode: episodeAlias)
        }
        if let showAlias {
            return .ntsShow(alias: showAlias)
        }
        return nil
    }
}

// MARK: - Domain types

nonisolated struct NTSShowSummary: Identifiable, Hashable, Sendable {
    let alias: String
    let name: String
    let summary: String?
    let location: String?
    let genres: [String]
    let artworkURL: URL?

    var id: String { alias }
}

nonisolated struct NTSEpisodeSummary: Identifiable, Hashable, Sendable {
    let showAlias: String
    let episodeAlias: String
    let name: String
    let summary: String?
    let location: String?
    let genres: [String]
    let moods: [String]
    let artworkURL: URL?
    let broadcastAt: Date?
    let isPublished: Bool

    var id: String { "\(showAlias)/\(episodeAlias)" }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }
}

nonisolated struct NTSTracklistEntry: Identifiable, Hashable, Sendable {
    let id: String
    let artist: String
    let title: String
    /// Seconds from the start of the broadcast, when NTS reports it.
    let offset: Int?

    var offsetLabel: String? {
        guard let offset, offset >= 0 else { return nil }
        return TimeFormat.clock(TimeInterval(offset))
    }
}

/// Where an archived episode can actually be heard. NTS hosts archives on
/// SoundCloud and Mixcloud rather than serving a stream Indigo could play, so
/// these are links out, not playback sources.
nonisolated struct NTSExternalAudio: Identifiable, Hashable, Sendable {
    let source: String
    let url: URL

    var id: String { url.absoluteString }

    /// Nil when NTS points somewhere Indigo has no widget for.
    var provider: EmbedProvider? { EmbedProvider(rawValue: source.lowercased()) }

    var displayName: String {
        switch source.lowercased() {
        case "soundcloud": "SoundCloud"
        case "mixcloud": "Mixcloud"
        default: source.capitalized
        }
    }
}

nonisolated struct NTSEpisodeDetail: Sendable {
    let summary: NTSEpisodeSummary
    let tracklist: [NTSTracklistEntry]
    let audio: [NTSExternalAudio]

    /// SoundCloud first — it is what NTS publishes for virtually every episode
    /// and its widget reports position and duration more reliably.
    var playbackSource: NTSExternalAudio? {
        audio.first { $0.provider == .soundcloud } ?? audio.first { $0.provider != nil }
    }

    var isPlayable: Bool { playbackSource != nil }

    func mediaItem() -> MediaItem? {
        guard let source = playbackSource, let provider = source.provider else { return nil }
        return MediaItem(
            id: "nts.episode.\(summary.id)",
            sourceID: NTSProvider.providerID,
            kind: .episode,
            title: summary.name,
            subtitle: [summary.broadcastLabel, summary.location].compactMap { $0 }.joined(separator: " · "),
            detail: "NTS",
            genres: summary.genres + summary.moods,
            remoteArtworkURL: summary.artworkURL,
            playbackURL: source.url,
            duration: nil,
            embedProvider: provider
        )
    }
}

nonisolated struct NTSMixtape: Identifiable, Hashable, Sendable {
    let alias: String
    let title: String
    let subtitle: String?
    let summary: String?
    let artworkURL: URL?
    let streamURL: URL
    let credits: [NTSMixtapeShow]

    var id: String { alias }
}

// MARK: - Mapping

extension NTSShowDTO {
    func asSummary() -> NTSShowSummary? {
        guard let showAlias, !showAlias.isEmpty else { return nil }
        return NTSShowSummary(
            alias: showAlias,
            name: HTMLText.decode(name ?? showAlias).trimmingCharacters(in: .whitespaces),
            summary: description.map(HTMLText.decode),
            location: locationLong ?? locationShort,
            genres: (genres ?? []).compactMap(\.value).map(HTMLText.decode),
            artworkURL: media?.thumbnail
        )
    }
}

extension NTSEpisodeDTO {
    func asSummary() -> NTSEpisodeSummary? {
        guard let showAlias, let episodeAlias, !episodeAlias.isEmpty else { return nil }
        return NTSEpisodeSummary(
            showAlias: showAlias,
            episodeAlias: episodeAlias,
            name: HTMLText.decode(name ?? episodeAlias).trimmingCharacters(in: .whitespaces),
            summary: description.map(HTMLText.decode),
            location: locationLong ?? locationShort,
            genres: (genres ?? []).compactMap(\.value).map(HTMLText.decode),
            moods: (moods ?? []).compactMap(\.value).map(HTMLText.decode),
            artworkURL: media?.large,
            broadcastAt: NTSTimestamp.parse(broadcast),
            isPublished: (status ?? "") == "published"
        )
    }

    func asDetail() -> NTSEpisodeDetail? {
        guard let summary = asSummary() else { return nil }

        let entries = (embeds?.tracklist ?? []).enumerated().compactMap { index, track -> NTSTracklistEntry? in
            let artist = HTMLText.decode(track.artist ?? "").trimmingCharacters(in: .whitespaces)
            let title = HTMLText.decode(track.title ?? "").trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty || !title.isEmpty else { return nil }
            return NTSTracklistEntry(
                // A uid can repeat within an episode when a track is played
                // more than once, so the position is part of the identity.
                id: "\(track.uid ?? "track")#\(index)",
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                title: title.isEmpty ? "Untitled" : title,
                offset: track.offset ?? track.offsetEstimate
            )
        }

        var audio = (audioSources ?? []).compactMap { source -> NTSExternalAudio? in
            guard let raw = source.url, let url = URL(string: raw) else { return nil }
            return NTSExternalAudio(source: source.source ?? "link", url: url)
        }
        if audio.isEmpty, let mixcloud, let url = URL(string: mixcloud) {
            audio.append(NTSExternalAudio(source: "mixcloud", url: url))
        }

        return NTSEpisodeDetail(summary: summary, tracklist: entries, audio: audio)
    }
}

extension NTSMixtapeDTO {
    func asMixtape() -> NTSMixtape? {
        guard let mixtapeAlias,
              let endpoint = audioStreamEndpoint,
              let streamURL = URL(string: endpoint)
        else { return nil }
        return NTSMixtape(
            alias: mixtapeAlias,
            title: HTMLText.decode(title ?? mixtapeAlias),
            subtitle: subtitle.map(HTMLText.decode),
            summary: description.map(HTMLText.decode),
            artworkURL: media?.large,
            streamURL: streamURL,
            credits: (credits ?? []).compactMap { credit in
                let name = HTMLText.decode(credit.name ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                let parsed = credit.path.flatMap { NTSSitePath.parse($0) }
                return NTSMixtapeShow(
                    name: name,
                    showAlias: parsed?.show,
                    episodeAlias: parsed?.episode,
                    path: credit.path
                )
            }
        )
    }
}
