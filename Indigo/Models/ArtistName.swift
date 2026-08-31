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
}
