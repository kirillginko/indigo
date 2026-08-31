//
//  TrackCredit.swift
//  Indigo
//
//  Recovering "who" from "what" when a station only publishes one string.
//
//  Plenty of broadcasters hand over a tracklist as lines of text rather than
//  as fields — "SPACE AFRIKA - MLN ft. Tony Njoku" — and a recording that
//  keeps the whole line as its title has no artist. That is not a cosmetic
//  problem: DIG cannot open an artist it does not have, and MusicBrainz,
//  asked for a track called "SPACE AFRIKA - MLN ft. Tony Njoku" by nobody in
//  particular, finds nothing and marks the lookup failed. One unsplit string
//  costs the recording its artist page, its release, and its sleeve.
//

import Foundation

nonisolated enum TrackCredit {
    /// The dashes stations actually use, longest first so an em dash is never
    /// matched as a hyphen with odd spacing around it.
    private static let separators = [" — ", " – ", " - "]

    /// Splits "Artist - Title" when the line clearly is one. Deliberately
    /// strict: exactly one separator, and something on both sides of it.
    /// "Artist - Title - Extra Mix" is left alone, because guessing which
    /// dash was the credit and which was part of the name gets it wrong more
    /// often than it gets it right.
    static func split(_ line: String) -> (artist: String, title: String)? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in separators {
            let parts = text.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty, !title.isEmpty { return (artist, title) }
        }
        return nil
    }

    /// The title with the featured-artist tail taken off, for looking things
    /// up. Catalogues file "MLN" and stations write "MLN ft. Tony Njoku"; the
    /// suffix is true, and it is also the reason the search returns nothing.
    /// Only ever used to ask a question — never to rename the recording.
    static func searchTitle(_ title: String) -> String {
        var text = title
        for marker in [" ft. ", " ft ", " feat. ", " feat ", " featuring ", " w/ ", " with "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// What a provider row amounts to: its own credit when it has one, the
    /// line read apart when it doesn't.
    static func resolve(artist: String?, title: String) -> (artist: String?, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return (artist, trimmedTitle)
        }
        if let credit = split(trimmedTitle) { return (credit.artist, credit.title) }
        return (nil, trimmedTitle)
    }
}
