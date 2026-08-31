//
//  ReleaseKind.swift
//  Indigo
//
//  What kind of object a record is.
//
//  A catalogue built for albums and singles throws away the categories that
//  matter most underground: the white label with no name on it, the dubplate
//  cut for one DJ, the test press that leaked. Those are not defective albums.
//  They are their own kinds of thing, and a release with almost no metadata is
//  a valid release rather than a broken one.
//

import Foundation

nonisolated enum ReleaseKind: String, Hashable, Sendable, CaseIterable {
    case album
    case ep
    case single
    case compilation
    case mix
    case promo
    case whiteLabel
    case dubplate
    case testPress
    case bootleg
    case unknown

    var label: String {
        switch self {
        case .album: "ALBUM"
        case .ep: "EP"
        case .single: "SINGLE"
        case .compilation: "COMPILATION"
        case .mix: "MIX"
        case .promo: "PROMO"
        case .whiteLabel: "WHITE LABEL"
        case .dubplate: "DUBPLATE"
        case .testPress: "TEST PRESS"
        case .bootleg: "BOOTLEG"
        case .unknown: "UNKNOWN RELEASE"
        }
    }

    /// How far off the beaten track this kind of object is, 0…1. A dubplate
    /// exists in single figures; an album is in every shop.
    var deepness: Double {
        switch self {
        case .album, .single: 0.0
        case .compilation: 0.05
        case .ep: 0.1
        case .mix: 0.3
        case .promo: 0.55
        case .bootleg: 0.7
        case .testPress: 0.8
        case .whiteLabel: 0.9
        case .dubplate: 0.95
        case .unknown: 0.75
        }
    }

    /// True for the objects a catalogue would rather not admit exist.
    var isUnderground: Bool { deepness >= 0.5 }
}

nonisolated enum ReleaseClassifier {
    /// Ordered longest-phrase-first so "test pressing" is never read as a
    /// press of something, and the underground markers are checked before the
    /// ordinary formats — a "Promo EP" is a promo.
    private static let markers: [(needle: String, kind: ReleaseKind)] = [
        ("test pressing", .testPress),
        ("test press", .testPress),
        ("white label", .whiteLabel),
        ("whitelabel", .whiteLabel),
        ("dubplate", .dubplate),
        ("acetate", .dubplate),
        ("unofficial", .bootleg),
        ("bootleg", .bootleg),
        ("promotional", .promo),
        ("promo", .promo),
        ("compilation", .compilation),
        ("mixtape", .mix),
        ("dj mix", .mix),
        ("album", .album),
        ("single", .single),
        ("ep", .ep)
    ]

    /// Reads whatever text a catalogue gave us. Deliberately looks at notes
    /// and format as well as title: "white label" is far more often written in
    /// the notes than in the name of a record that, by definition, has no name
    /// printed on it.
    static func classify(
        title: String? = nil,
        releaseType: String? = nil,
        notes: String? = nil,
        catalogNumber: String? = nil,
        artistNames: [String] = []
    ) -> ReleaseKind {
        // A record credited to "Various" is a compilation. The credit is not a
        // person — which is why it never becomes an artist node — but it is a
        // perfectly good fact about the record, and the most informative one
        // available about what kind of record it is.
        if !artistNames.isEmpty, artistNames.allSatisfy({ ArtistName.isPlaceholder($0) }) {
            return .compilation
        }
        let haystack = [title, releaseType, notes, catalogNumber]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()

        for marker in markers where contains(haystack, word: marker.needle) {
            return marker.kind
        }

        // Nothing said what it is. For a record with a catalogue number that
        // is a real answer — an object that exists and refuses to explain
        // itself — rather than a gap to be apologised for.
        return .unknown
    }

    /// Whole-word matching. "ep" must not fire on "deep", and "promo" must not
    /// fire on "promotion" — but it should on "Promo)" and "promo-only".
    private static func contains(_ haystack: String, word: String) -> Bool {
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: word, range: search) {
            let startsCleanly = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isLetter
            let endsCleanly = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isLetter
            if startsCleanly, endsCleanly { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            search = found.upperBound..<haystack.endIndex
        }
        return false
    }
}
