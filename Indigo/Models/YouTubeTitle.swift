//
//  YouTubeTitle.swift
//  Indigo
//
//  Reading the recording's name out of what an uploader typed above it.
//
//  Discogs stores a video's title exactly as YouTube has it, and YouTube
//  titles are advertising as much as they are names: "[Official Audio]",
//  "(HD)", "| Official Music Video". None of that says anything about the
//  recording, and in a Listen list it is what everything has in common —
//  which is the opposite of what a list of titles is for.
//

import Foundation

nonisolated enum YouTubeTitle {
    /// The title with the uploader's promotional asides removed.
    ///
    /// Only asides made entirely of promotional vocabulary go: "(Live at
    /// Dekmantel)", "(Original Mix)" and "(Boiler Room Edit)" all say
    /// something about which recording this is, and stay.
    static func clean(_ raw: String) -> String {
        // Most titles carry no aside at all, and finding that out has to cost
        // less than the scan would: this runs over every recording on a page
        // each time the page is rebuilt.
        let withoutAsides = raw.contains(where: { $0 == "(" || $0 == "[" })
            ? withoutNoisyAsides(raw) : raw
        let withoutTrailers = withoutNoisyTrailers(withoutAsides)
        let tidied = tidy(Substring(withoutTrailers))
        // Never hand back nothing: a recording called "[Official Video]" and
        // nothing else is better listed as that than as an empty row.
        return tidied.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : tidied
    }

    /// "Rev8617 [Official Audio] (HD)" → "Rev8617".
    private static func withoutNoisyAsides(_ raw: String) -> String {
        var kept = ""
        var aside = ""
        var opener: Character?
        for character in raw {
            guard let open = opener else {
                if character == "(" || character == "[" { opener = character } else { kept.append(character) }
                continue
            }
            guard character == closer(for: open) else { aside.append(character); continue }
            if !isNoise(normalized: RecordingKey.normalize(aside)) {
                kept += "\(open)\(aside)\(character)"
            }
            opener = nil
            aside = ""
        }
        // An unbalanced bracket is somebody's typo, not a structure to reason
        // about: what was written stays written.
        if let open = opener { kept += "\(open)\(aside)" }
        return kept
    }

    /// "Rev8617 | Official Video" → "Rev8617", and the same after a dash.
    ///
    /// Only ever the last segment, and only when something is left in front
    /// of it — "Skee Mask - Rev8617" is a credit and a title, not a title and
    /// an aside.
    private static func withoutNoisyTrailers(_ raw: String) -> String {
        var value = Substring(raw)
        while let divider = lastDivider(in: value) {
            let tail = value[divider.upperBound...]
            guard isNoisyTrailer(RecordingKey.normalize(String(tail))) else { break }
            let head = value[..<divider.lowerBound]
            guard !tidy(head).isEmpty else { break }
            value = head
        }
        return String(value)
    }

    /// Where the last "| …" or " - …" in the line begins and ends.
    ///
    /// Walked by hand rather than with `range(of:options:.backwards)`, which
    /// bridges to Foundation, and over the string itself rather than an
    /// `Array(Character)`, which copies it.
    private static func lastDivider(in value: Substring) -> Range<String.Index>? {
        var index = value.endIndex
        while index > value.startIndex {
            index = value.index(before: index)
            let character = value[index]
            let after = value.index(after: index)
            if character == "|" { return index..<after }
            if character == "/", index > value.startIndex,
               value[value.index(before: index)] == "/" {
                return value.index(before: index)..<after
            }
            // A dash only divides when it stands on its own: "Rev8617-2" is
            // one word, "Skee Mask - Rev8617" is two things.
            guard character == "-" || character == "\u{2013}" || character == "\u{2014}",
                  index > value.startIndex, value[value.index(before: index)] == " ",
                  after < value.endIndex, value[after] == " "
            else { continue }
            return value.index(before: index)..<value.index(after: after)
        }
        return nil
    }

    /// Whatever the removals left behind — doubled spaces, a dangling dash.
    private static func tidy(_ raw: Substring) -> String {
        var value = raw
        while let first = value.first, trimmable.contains(first) { value = value.dropFirst() }
        while let last = value.last, trimmable.contains(last) { value = value.dropLast() }
        // Only worth rebuilding when a removal actually left a gap.
        guard value.contains("  ") else { return String(value) }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Punctuation that means nothing on its own at either end of a title.
    private static let trimmable: Set<Character> = [
        "-", "\u{2013}", "\u{2014}", "|", "/", "\u{00B7}", "\u{2022}", ":", ",", " "
    ]

    private static func closer(for opener: Character) -> Character { opener == "[" ? "]" : ")" }

    /// Words that only ever describe how a recording was uploaded. A segment
    /// made of nothing else says nothing about the music.
    private static let noiseWords: Set<String> = [
        "official", "audio", "video", "videoclip", "music", "clip", "mv", "pv",
        "lyric", "lyrics", "visualizer", "visualiser", "visual", "visuals",
        "hd", "hq", "uhd", "sd", "4k", "8k", "1080p", "720p", "480p",
        "full", "high", "quality", "stream", "streaming", "only", "version",
        "upload", "reupload"
    ]

    /// Phrases that are noise as a whole while their words are not.
    private static let noisePhrases: Set<String> = [
        "free download", "free dl", "out now", "buy now", "download",
        "premiere", "exclusive premiere", "new single", "new album",
        "official channel", "with lyrics", "letra"
    ]

    /// The same question outside brackets, asked more carefully.
    ///
    /// A bracket announces an aside; a dash does not. "Ekman - Video" is a
    /// credit and a title, and dropping the title because a single word of it
    /// is also uploader vocabulary loses the recording's name — so out here a
    /// lone word has to be one nobody would call a record.
    private static func isNoisyTrailer(_ normalized: String) -> Bool {
        guard isNoise(normalized: normalized) else { return false }
        let words = normalized.split(separator: " ")
        guard words.count == 1 else { return true }
        return ["hd", "hq", "uhd", "4k", "8k", "1080p", "720p", "480p", "mv", "pv"]
            .contains(String(words[0]))
    }

    /// True when a segment is the uploader talking about the upload. Takes
    /// the normalised form, because every caller already has it.
    private static func isNoise(normalized: String) -> Bool {
        // Empty brackets are somebody's leftover, and go with the rest.
        guard !normalized.isEmpty else { return true }
        if noisePhrases.contains(normalized) { return true }
        // "XLR8R Premiere", "Dekmantel premiere" — a channel's billing.
        let words = normalized.split(separator: " ").map(String.init)
        if words.count <= 3, words.last == "premiere" { return true }
        return words.allSatisfy(noiseWords.contains)
    }
}
