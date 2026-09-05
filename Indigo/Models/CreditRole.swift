//
//  CreditRole.swift
//  Indigo
//
//  Who else made the record.
//
//  Discogs credits everybody: the producer, the engineer who cut the lacquer,
//  the photographer, and whoever laid out the sleeve. All of that is real
//  work, and only some of it is a musical connection. A graph that treats them
//  alike says a designer and a co-producer are the same kind of link, and the
//  first artist you meet through a shared photographer is the moment DIG stops
//  being about music.
//
//  So roles are sorted rather than filtered by a list of names. An allowlist
//  would have to enumerate every instrument anyone has ever been credited with
//  — Discogs has thousands — and would quietly drop the interesting ones. The
//  small closed set is the other end: the handful of jobs that are about the
//  object rather than the music.
//

import Foundation

nonisolated enum CreditRole {
    /// What kind of contribution a credit is.
    nonisolated enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Producer, co-producer, mixed by, remix.
        case production
        /// Written-by, composed by, lyrics.
        case writing
        /// Engineer, recorded by, mastered by.
        case engineering
        /// Anything played or sung.
        case performance

        /// How the lane is titled.
        var label: String {
            switch self {
            case .production: "Produced by"
            case .writing: "Written by"
            case .engineering: "Engineered by"
            case .performance: "Personnel"
            }
        }

        /// Ordered as a sleeve would order them: whoever shaped the record
        /// first, then who played on it.
        var rank: Int {
            switch self {
            case .production: 0
            case .writing: 1
            case .performance: 2
            case .engineering: 3
            }
        }
    }

    /// Jobs that made the object rather than the music. Matched as substrings
    /// because Discogs writes them a dozen ways — "Design", "Artwork By",
    /// "Design, Layout" — and every one of them is still a sleeve credit.
    private static let presentation = [
        "design", "artwork", "photograph", "illustration", "layout", "sleeve",
        "cover", "liner notes", "翻訳", "translation", "lacquer", "pressed by",
        "distributed by", "manufactured", "management", "a&r", "legal",
        "copyright", "phonographic", "typography", "concept", "model"
    ]

    /// Whether this credit is about the music at all.
    static func isMusical(_ role: String?) -> Bool { kind(of: role) != nil }

    /// What sort of credit this is, or nil when it is not a musical one.
    ///
    /// A role naming several jobs — Discogs writes "Producer, Mixed By" in one
    /// field — is read as the strongest of them, so a producer who also took
    /// the photograph is still a producer.
    static func kind(of role: String?) -> Kind? {
        guard let role else { return nil }
        let folded = role.lowercased()
        guard !folded.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var best: Kind?
        for part in folded.split(separator: ",") {
            let job = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !job.isEmpty else { continue }
            guard !presentation.contains(where: { job.contains($0) }) else { continue }
            let found: Kind
            if job.contains("produc") || job.contains("mix") || job.contains("remix") {
                found = .production
            } else if job.contains("written") || job.contains("compos")
                        || job.contains("lyric") || job.contains("songwriter")
                        || job.contains("arrang") {
                found = .writing
            } else if job.contains("engineer") || job.contains("master")
                        || job.contains("record") {
                found = .engineering
            } else {
                found = .performance
            }
            if best == nil || found.rank < (best?.rank ?? .max) { best = found }
        }
        return best
    }

    /// The role as it should read on a line: "Mixed By", not "mixed by".
    ///
    /// Discogs' own casing is kept when it has any, because the site is
    /// consistent about it and second-guessing turns "DJ" into "Dj".
    static func display(_ role: String?) -> String? {
        guard let role else { return nil }
        let clean = role.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
