//
//  ArtistName.swift
//  Indigo
//
//  Names that are not artists.
//
//  Catalogues need somewhere to file a compilation, so they invent a credit:
//  "Various", "Various Artists", "Unknown Artist". Those are filing
//  conventions, not people — and treated as artists they are catastrophic for
//  a graph, because every compilation in existence connects to every other one
//  through them. "Various" becomes the best-connected artist in music.
//
//  Distinct from an *unidentified* recording, which is a real thing nobody has
//  named yet and belongs in the graph. This is a name that refers to nobody.
//

import Foundation

nonisolated enum ArtistName {
    private static let placeholders: Set<String> = [
        "various", "various artists", "various artist",
        "unknown artist", "unknown artists", "unknown",
        "no artist", "not on label", "untitled"
    ]

    /// Whether this credit stands for nobody in particular.
    ///
    /// Matched on the whole normalised name, never as a prefix: "Various
    /// Production" is a real group and "Unknown Mortal Orchestra" is a real
    /// band, and both would be lost to a looser rule.
    static func isPlaceholder(_ name: String?) -> Bool {
        guard let name else { return false }
        let key = RecordingKey.normalize(name)
        guard !key.isEmpty else { return true }
        return placeholders.contains(key)
    }

    /// Whether this credit is worth putting in the graph at all.
    static func isRealArtist(_ name: String?) -> Bool {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !isPlaceholder(name)
    }

    /// The words that join two names into one credit.
    ///
    /// Kept here so `RecordingKey.creditedArtists` and anything that needs the
    /// original spellings work from one list. The dashes and the slash are
    /// spaced on purpose: an unspaced hyphen belongs to the name carrying it,
    /// and splitting on it would make two people out of Jean-Michel Jarre.
    static let creditSeparators = [
        " x ", " X ", " & ", " and ", " with ", " vs. ", " vs ", ", ",
        " feat. ", " feat ", " ft. ", " ft ", " featuring ",
        " - ", " – ", " — ", " / "
    ]

    /// The people named in a credit, spelled as the credit spelled them.
    ///
    /// `RecordingKey.creditedArtists` answers the same question in normalised
    /// form, which is what comparisons want. This is for the places that have
    /// to *show* the answer — a scene's membership, a page's heading — where
    /// "anthony braxton" is not a name anybody wrote.
    static func split(_ credit: String?) -> [String] {
        guard let credit, !credit.isEmpty else { return [] }
        var parts = [credit]
        for separator in creditSeparators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var seen = Set<String>()
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                guard isRealArtist($0) else { return false }
                return seen.insert(RecordingKey.normalizeArtist($0)).inserted
            }
    }
}
