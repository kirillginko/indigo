//
//  NTSModels.swift
//  Indigo
//
//  Wire format for https://www.nts.live/api/v2/live. These types stay inside
//  the NTS folder; the rest of the app sees RadioStation / RadioShow.
//

import Foundation

nonisolated struct NTSLiveResponse: Decodable, Sendable {
    let results: [NTSChannel]
}

nonisolated struct NTSChannel: Decodable, Sendable {
    let channelName: String?
    let now: NTSBroadcast?
    let next: NTSBroadcast?
}

nonisolated struct NTSBroadcast: Decodable, Sendable {
    let broadcastTitle: String?
    let startTimestamp: String?
    let endTimestamp: String?
    let embeds: NTSEmbeds?
}

nonisolated struct NTSEmbeds: Decodable, Sendable {
    let details: NTSDetails?
}

nonisolated struct NTSDetails: Decodable, Sendable {
    let name: String?
    let showAlias: String?
    let episodeAlias: String?
    let description: String?
    let locationLong: String?
    let locationShort: String?
    let media: NTSMedia?
    let genres: [NTSTag]?
    let moods: [NTSTag]?
}

nonisolated struct NTSMedia: Decodable, Sendable {
    let pictureLarge: String?
    let pictureMediumLarge: String?
    let pictureMedium: String?
    let pictureSmall: String?

    /// Best size for a detail page.
    var large: URL? { NTSMedia.url(pictureLarge ?? pictureMediumLarge ?? pictureMedium) }
    /// Small enough for the player bar and sidebar.
    var thumbnail: URL? { NTSMedia.url(pictureMedium ?? pictureSmall ?? pictureMediumLarge) }

    private static func url(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }
}

nonisolated struct NTSTag: Decodable, Sendable {
    let id: String?
    let value: String?
}

// MARK: - Mapping

extension NTSBroadcast {
    func asRadioShow() -> RadioShow {
        let details = embeds?.details
        return RadioShow(
            title: HTMLText.decode(broadcastTitle ?? details?.name ?? "NTS"),
            host: details?.name.map(HTMLText.decode),
            summary: details?.description.map(HTMLText.decode),
            location: details?.locationLong ?? details?.locationShort,
            genres: (details?.genres ?? []).compactMap(\.value).map(HTMLText.decode),
            moods: (details?.moods ?? []).compactMap(\.value).map(HTMLText.decode),
            artworkURL: details?.media?.large,
            startsAt: NTSTimestamp.parse(startTimestamp),
            endsAt: NTSTimestamp.parse(endTimestamp),
            detailID: NTSEpisodeRef.encode(show: details?.showAlias, episode: details?.episodeAlias)
        )
    }
}

/// Packs the show/episode alias pair into the shared `RadioShow.detailID`.
nonisolated enum NTSEpisodeRef {
    static func encode(show: String?, episode: String?) -> String? {
        guard let show, let episode, !show.isEmpty, !episode.isEmpty else { return nil }
        return "\(show)/\(episode)"
    }

    static func decode(_ value: String) -> (show: String, episode: String)? {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

nonisolated enum NTSTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value)
    }
}

/// NTS titles arrive HTML-escaped ("DEBT &amp; REFUGE").
nonisolated enum HTMLText {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}"
    ]

    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            guard input[index] == "&",
                  let semicolon = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semicolon) <= 10 else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }
            let entity = String(input[input.index(after: index)..<semicolon])
            if let replacement = named[entity] {
                output.append(replacement)
            } else if entity.hasPrefix("#"),
                      let scalar = numericScalar(entity.dropFirst()) {
                output.append(Character(scalar))
            } else {
                output.append(contentsOf: input[index...semicolon])
            }
            index = input.index(after: semicolon)
        }
        return output
    }

    private static func numericScalar(_ digits: Substring) -> Unicode.Scalar? {
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value else { return nil }
        return Unicode.Scalar(value)
    }
}
