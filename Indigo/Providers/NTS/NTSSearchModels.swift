//
//  NTSSearchModels.swift
//  Indigo
//
//  The NTS search API. Note the `version=2` query parameter — without it the
//  endpoint answers every query with an empty result set.
//
//  Results are heterogeneous: shows, episodes, tracks, artists and videos all
//  come back in one list, distinguished by `article_type` and located by a
//  site path like "/shows/{show}/episodes/{episode}".
//

import Foundation

nonisolated enum NTSSearchScope: String, CaseIterable, Hashable, Sendable {
    case all
    case show
    case episode
    case track

    var title: String {
        switch self {
        case .all: "All"
        case .show: "Shows"
        case .episode: "Episodes"
        case .track: "Tracks"
        }
    }

    /// `types` accepts exactly one value; a comma-separated list returns nothing.
    var queryValue: String? { self == .all ? nil : rawValue }
}

// MARK: - Wire types

nonisolated struct NTSSearchResponse: Decodable, Sendable {
    let metadata: NTSPageMetadata?
    let results: [NTSSearchResultDTO]
}

nonisolated struct NTSSearchResultDTO: Decodable, Sendable {
    let articleType: String?
    let title: String?
    let artists: [NTSSearchArtist]?
    let article: NTSSearchArticle?
    let description: NTSSearchDescription?
    let image: NTSSearchImage?
    let localDate: String?
    let location: String?
    let genres: [NTSNamedTag]?
    let trackUid: String?
}

nonisolated struct NTSSearchArtist: Decodable, Sendable {
    let name: String?
    let role: String?
}

nonisolated struct NTSSearchArticle: Decodable, Sendable {
    let path: String?
    let title: String?
}

nonisolated struct NTSSearchDescription: Decodable, Sendable {
    let highlightHtml: String?
    let highlightPlain: String?
}

nonisolated struct NTSSearchImage: Decodable, Sendable {
    let large: String?
    let mediumLarge: String?
    let medium: String?
    let small: String?

    var thumbnail: URL? {
        for candidate in [medium, small, mediumLarge, large] {
            if let candidate, !candidate.isEmpty, let url = URL(string: candidate) { return url }
        }
        return nil
    }
}

/// Search uses `name` where the rest of the API uses `value`.
nonisolated struct NTSNamedTag: Decodable, Sendable {
    let id: String?
    let name: String?
}

// MARK: - Domain type

nonisolated struct NTSSearchResult: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case show, episode, track, artist, video, other
    }

    let id: String
    let kind: Kind
    let title: String
    let artists: [String]
    let showAlias: String?
    let episodeAlias: String?
    /// The matched text, with the terms NTS highlighted marked up.
    let highlight: [HighlightRun]
    let artworkURL: URL?
    let date: String?
    let location: String?
    let genres: [String]
    /// The episode a track was heard in, for the "played on" line.
    let contextTitle: String?

    /// Where tapping this result should take you, if anywhere.
    var destination: DetailPage? {
        if let showAlias, let episodeAlias {
            return .ntsEpisode(show: showAlias, episode: episodeAlias)
        }
        if let showAlias {
            return .ntsShow(alias: showAlias)
        }
        return nil
    }

    var kindLabel: String {
        switch kind {
        case .show: "Show"
        case .episode: "Episode"
        case .track: "Track"
        case .artist: "Artist"
        case .video: "Video"
        case .other: "NTS"
        }
    }
}

nonisolated struct HighlightRun: Hashable, Sendable {
    let text: String
    let isMatch: Bool
}

// MARK: - Mapping

extension NTSSearchResultDTO {
    func asResult(index: Int) -> NTSSearchResult? {
        let path = article?.path ?? ""
        let aliases = NTSSitePath.parse(path)

        let kind: NTSSearchResult.Kind
        switch articleType {
        case "show": kind = .show
        case "episode": kind = .episode
        case "track": kind = .track
        case "artist": kind = .artist
        case "video": kind = .video
        default: kind = .other
        }

        let names = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
        let cleanTitle = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return nil }

        // Tracks repeat across episodes, so the uid alone is not unique here.
        let identity = [articleType ?? "?", path, trackUid ?? cleanTitle, String(index)].joined(separator: "|")

        return NTSSearchResult(
            id: identity,
            kind: kind,
            title: cleanTitle,
            artists: names.map(HTMLText.decode),
            showAlias: aliases?.show,
            episodeAlias: aliases?.episode,
            highlight: HighlightRun.parse(description?.highlightHtml),
            artworkURL: image?.thumbnail,
            date: localDate?.isEmpty == false ? localDate : nil,
            location: location?.isEmpty == false ? location : nil,
            genres: (genres ?? []).compactMap(\.name).map(HTMLText.decode),
            contextTitle: article?.title.map(HTMLText.decode)
        )
    }
}

/// "/shows/floating-points/episodes/fp-1" → ("floating-points", "fp-1")
nonisolated enum NTSSitePath {
    static func parse(_ path: String) -> (show: String, episode: String?)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "shows" else { return nil }
        let show = parts[1]
        guard !show.isEmpty else { return nil }
        if parts.count >= 4, parts[2] == "episodes", !parts[3].isEmpty {
            return (show, parts[3])
        }
        return (show, nil)
    }
}

extension HighlightRun {
    /// Splits NTS's `<em>`-marked snippet into plain and matched runs.
    static func parse(_ html: String?) -> [HighlightRun] {
        guard let html, !html.isEmpty else { return [] }

        var runs: [HighlightRun] = []
        var remainder = Substring(html)

        while let open = remainder.range(of: "<em>") {
            let before = String(remainder[remainder.startIndex..<open.lowerBound])
            if !before.isEmpty { runs.append(HighlightRun(text: strip(before), isMatch: false)) }

            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "</em>") else {
                runs.append(HighlightRun(text: strip(String(afterOpen)), isMatch: false))
                return compact(runs)
            }
            runs.append(HighlightRun(text: strip(String(afterOpen[afterOpen.startIndex..<close.lowerBound])),
                                     isMatch: true))
            remainder = afterOpen[close.upperBound...]
        }

        if !remainder.isEmpty { runs.append(HighlightRun(text: strip(String(remainder)), isMatch: false)) }
        return compact(runs)
    }

    private static func strip(_ value: String) -> String {
        HTMLText.decode(value.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        ))
    }

    private static func compact(_ runs: [HighlightRun]) -> [HighlightRun] {
        runs.filter { !$0.text.isEmpty }
    }
}

extension NTSSearchResult {
    /// Lets a `types=show` search render in the same grid as the A–Z browse.
    func asShowSummary() -> NTSShowSummary? {
        guard kind == .show, let showAlias else { return nil }
        let blurb = highlight.map(\.text).joined()
        return NTSShowSummary(
            alias: showAlias,
            name: title,
            summary: blurb.isEmpty ? nil : blurb,
            location: location,
            genres: genres,
            artworkURL: artworkURL
        )
    }
}
