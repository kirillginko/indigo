//
//  ReleaseAttribution.swift
//  Indigo
//
//  Whether a release belongs on an artist's page.
//
//  An artist page gathers the releases credited to its name, and a name is
//  not an artist: both Hype Williams file their records under "Hype
//  Williams", so each page collected the other's. A release whose kept
//  credits name a Discogs entry says exactly whose it is, and that settles it.
//
//  Entirely internal. The page shows what belongs on it and nothing about
//  how that was decided: a verified release and a release known only by name
//  look the same, because underground records are very often known only by
//  name and are no less the artist's for it. The one thing evidence changes on
//  screen is that a release known to be somebody else's is not there. The
//  verdict and its confidence are kept on each line for whatever wants to
//  weigh them — diagnostics, enrichment, and the recommendation side, which
//  must not treat a name-only link as strong evidence.
//
//  Decided from what is held when the page is read, so a credit's id arriving
//  later moves a release on or off the page without anything being rewritten.
//

import Foundation

nonisolated struct ReleaseAttribution: Hashable, Sendable {
    nonisolated enum Verdict: String, Hashable, Sendable {
        /// A credit names this artist's own Discogs entry, or the release came
        /// from their own shelf.
        case verified
        /// Credited to the name with nothing to say which artist holds it, and
        /// nothing saying it is anyone else's.
        case nameOnly
        /// Every credit under this name names a different Discogs entry.
        case otherArtist
    }

    let verdict: Verdict
    /// How much the attribution is worth as evidence: 1 for verified, a half
    /// for a name, nothing for somebody else's.
    let confidence: Double
    /// What it rests on, for diagnostics: "credit discogs:3722", "shelf",
    /// "names only", "credits name discogs:1874027".
    let evidence: String

    /// Whether the release belongs on the page.
    var isShown: Bool { verdict != .otherArtist }

    static let shelf = ReleaseAttribution(verdict: .verified, confidence: 1, evidence: "shelf")
    static let namesOnly = ReleaseAttribution(verdict: .nameOnly, confidence: 0.5, evidence: "names only")

    /// The decision, for one release and one artist.
    ///
    /// - Parameters:
    ///   - subjectID: the artist's Discogs entry, when the page has one.
    ///   - subjectKeys: the folded names the page reads under — its own and
    ///     every spelling verified to be the artist.
    ///   - credits: the release's kept credits, or nil when none are held.
    ///
    /// Only headline credits under one of the page's names are weighed: they
    /// are why the release surfaced here. A release with none held, or with
    /// one under the name that names no entry, stays — the absence of an id is
    /// not evidence against anybody. It leaves only when every credit under
    /// the name names an entry, and none of them is this artist's.
    static func decide(subjectID: Int?, subjectKeys: Set<String>, credits: [ReleaseCredit]?) -> ReleaseAttribution {
        guard let credits else { return .namesOnly }
        let underName = credits.filter { credit in
            credit.category == .artist
                && (subjectKeys.contains(RecordingKey.normalizeArtist(credit.name))
                    || subjectKeys.contains(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(credit.creditedName))))
        }
        if let subjectID, underName.contains(where: { $0.discogsID == subjectID }) {
            return ReleaseAttribution(verdict: .verified, confidence: 1, evidence: "credit discogs:\(subjectID)")
        }
        guard let subjectID, !underName.isEmpty, underName.allSatisfy({ $0.discogsID != nil }) else {
            return .namesOnly
        }
        let others = Set(underName.compactMap(\.discogsID)).subtracting([subjectID]).sorted()
        return ReleaseAttribution(
            verdict: .otherArtist, confidence: 0,
            evidence: "credits name " + others.map { "discogs:\($0)" }.joined(separator: ",")
        )
    }
}
