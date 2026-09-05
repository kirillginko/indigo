//
//  LabelName.swift
//  Indigo
//
//  Names that are not labels.
//
//  Discogs files a self-released record under "Not On Label", often with the
//  artist's name in brackets after it — "Not On Label (Seefeel Self-Released)".
//  It is the absence of a label written down, not an imprint, and treated as
//  one it does the same damage "Various" does to artists: every self-released
//  record in the catalogue becomes a labelmate of every other, and the app
//  cheerfully explains that two strangers are connected because both are on
//  Not On Label.
//
//  Being self-released is a real and interesting fact. It is just not a
//  shared one.
//

import Foundation

nonisolated enum LabelName {
    private static let exact: Set<String> = [
        "unknown label", "no label", "none", "unknown", "self released",
        "self release", "white label"
    ]

    /// Whether this stands for the absence of a label.
    ///
    /// "Not On Label" is matched as a prefix, unlike the rest: Discogs almost
    /// always appends whose self-release it was, and every one of those is
    /// still not a label.
    static func isPlaceholder(_ name: String?) -> Bool {
        guard let name else { return false }
        let key = RecordingKey.normalize(name)
        guard !key.isEmpty else { return true }
        return key.hasPrefix("not on label") || exact.contains(key)
    }

    static func isRealLabel(_ name: String?) -> Bool {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !isPlaceholder(name)
    }

    /// The labels named by one Discogs label string.
    ///
    /// Plural, because Discogs' `/artists/{id}/releases` hands back every
    /// label on a record joined into a single field: "AMF Records (3), Virgin
    /// EMI Records" is two imprints, and stored whole it is one imprint that
    /// does not exist. A real cache here held over a hundred of them, each one
    /// a row that opened onto nothing.
    ///
    /// The disambiguating number goes too. Discogs files the eighth label
    /// called World Music as "World Music (8)"; the same imprint arrives from
    /// the release endpoint as plain "World Music", so keeping the suffix gave
    /// one artist's own label two entries on his page — and neither of them
    /// could be looked up by name, which is how the label pages find anything.
    ///
    /// Commas inside a genuine label name are the cost of this, and they are
    /// rare. Splitting is still the better trade: a real label wrongly halved
    /// leaves two names that mostly still resolve, and not splitting leaves a
    /// name that never does.
    static func names(inDiscogsField field: String?) -> [String] {
        guard let field else { return [] }
        var seen = Set<String>()
        var found: [String] = []
        for part in field.split(separator: ",") {
            let name = DiscogsClient.withoutDisambiguator(String(part))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRealLabel(name) else { continue }
            guard seen.insert(RecordingKey.normalize(name)).inserted else { continue }
            found.append(name)
        }
        return found
    }

    /// The single label to credit a release to, when only one line is going to
    /// be shown for it. Nil when Discogs named none worth showing.
    static func primary(inDiscogsField field: String?) -> String? {
        names(inDiscogsField: field).first
    }

    /// Whether a publisher is really just the artist releasing their own
    /// record.
    ///
    /// Bandcamp's JSON-LD names the page owner as the publisher, so an artist
    /// who sells their own music is listed as their own label — which is most
    /// of Bandcamp. It is the same fact "Not On Label" records, said
    /// in a way that looks like an imprint, and treated as one it makes every
    /// self-releasing artist a labelmate of themselves and puts their own name
    /// in the list of who put their records out.
    /// Three ways of being the same person, all of them readable off the two
    /// strings. What is deliberately *not* here is an artist-run imprint named
    /// after its founder — Grouper publishing Jefre Cantu-Ledesma, John Lurie
    /// publishing The Lounge Lizards. Telling those from a side project needs
    /// to know who is who, and guessing wrong deletes a real label, which is
    /// the worse mistake of the two.
    static func isSelfPublished(publisher: String?, artist: String?) -> Bool {
        guard let publisher, let artist else { return false }
        let label = RecordingKey.normalizeArtist(publisher)
        let credited = RecordingKey.normalizeArtist(artist)
        guard !label.isEmpty, !credited.isEmpty else { return false }

        // The plain case: they are the same name.
        if label == credited { return true }

        // The publisher is one of the people credited — "Bardo Pond" putting
        // out "Bardo Pond, Acid Mothers Temple, Guru Guru". A collaboration
        // released by one of its members is still nobody's label.
        let publishing = Set(RecordingKey.creditedArtists(publisher))
        let performing = Set(RecordingKey.creditedArtists(artist))
        if !publishing.isEmpty, !publishing.isDisjoint(with: performing) { return true }

        // The credit is the publisher and then a formation: "Christof Thewes
        // Quartet", "Misha Panfilov Septet", "Soft Machine Legacy". Matched at
        // a word boundary, so a label called Warp does not swallow Warpaint.
        return credited.hasPrefix(label + " ")
    }
}
