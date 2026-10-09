//
//  ArtistIdentityTests.swift
//  IndigoTests
//
//  Which artist a reference means, and which profile it is shown with. The
//  entries are Discogs' own (see `ArtistIdentityFixtures`); the search results
//  are shaped like the ones Discogs returned for the same spellings.
//

import XCTest
@testable import Indigo

private func result(_ title: String, id: Int) -> DiscogsSearchResult {
    DiscogsSearchResult(
        id: id, title: title, coverImage: nil, thumbnail: nil,
        genre: nil, style: nil, label: nil, year: nil
    )
}

private func facts(
    _ id: Int, _ name: String, variations: [String] = [], aliases: [(Int, String)] = []
) -> DiscogsIdentityFacts {
    DiscogsIdentityFacts(
        id: id, name: name, realName: nil, nameVariations: variations,
        aliases: aliases.map { DiscogsIdentityFacts.Link(id: $0.0, name: $0.1) },
        groups: [], members: []
    )
}

// MARK: - Spellings

final class SpellingCheckTests: XCTestCase {
    /// What Discogs returned for `q=Prefuse73&type=artist`: fifteen matches,
    /// one page, Prefuse 73 first and nobody filed under "Prefuse73".
    private let prefuseSearch = [
        result("Prefuse 73", id: 3722),
        result("Soarse Spoken", id: 111148),
        result("Savath & Savalas", id: 3838),
        result("Sons Of The Morning", id: 3452158)
    ]

    func testPrefuse73IsACreditedSpellingOfPrefuse73() throws {
        let verdict = SpellingCheck.verdict(
            spelling: "Prefuse73", results: prefuseSearch, complete: true,
            details: [3722: try ArtistIdentityFixtures.facts(3722)]
        )

        XCTAssertEqual(verdict, .variation(3722))
    }

    func testOnlyTheEntriesThatMatchWithoutSpacesAreRead() {
        XCTAssertEqual(SpellingCheck.candidates(for: "Prefuse73", in: prefuseSearch), [3722])
    }

    func testAFailedOrPaginatedSearchIsNoVerdict() throws {
        let details = [3722: try ArtistIdentityFixtures.facts(3722)]

        XCTAssertNil(
            SpellingCheck.verdict(spelling: "Prefuse73", results: prefuseSearch, complete: false, details: details),
            "A search that did not return everything cannot show that nobody else answers to the name"
        )
    }

    func testAnUnreadCandidateIsNoVerdict() {
        XCTAssertNil(
            SpellingCheck.verdict(spelling: "Prefuse73", results: prefuseSearch, complete: true, details: [:]),
            "A candidate whose entry could not be read is unknown, not a no"
        )
    }

    func testTooManyCandidatesIsNoVerdict() {
        let crowded = (1...4).map { result("Pre Fuse 73", id: $0) }
        XCTAssertNil(SpellingCheck.candidates(for: "Prefuse73", in: crowded))
        XCTAssertNil(SpellingCheck.verdict(spelling: "Prefuse73", results: crowded, complete: true, details: [:]))
    }

    /// Scott Herren's records credit him as "Scott" too. That makes "Scott" a
    /// spelling of his, not a name of his — the artist filed as Scott is
    /// somebody else, and the filing name wins.
    func testAFilingNameHeldByAnotherArtistBeatsAVariation() throws {
        let verdict = SpellingCheck.verdict(
            spelling: "Scott",
            results: [result("Scott Herren", id: 229415), result("Scott (3)", id: 900)],
            complete: true,
            details: [229415: try ArtistIdentityFixtures.facts(229415)]
        )

        XCTAssertEqual(verdict, .canonical([900]))
    }

    /// The false positive from the audit: A.R.P. lists "Arp" as a spelling,
    /// and Arp is a different artist filed under exactly that name.
    func testArpIsNotARP() {
        let verdict = SpellingCheck.verdict(
            spelling: "Arp",
            results: [result("A.R.P.", id: 111), result("Arp", id: 222)],
            complete: true,
            details: [111: facts(111, "A.R.P.", variations: ["Arp"])]
        )

        XCTAssertEqual(verdict, .canonical([222]))
    }

    /// Two entries both credited under one spelling: neither can claim it.
    func testASpellingTwoEntriesShareIsAmbiguous() {
        let verdict = SpellingCheck.verdict(
            spelling: "Bob",
            results: [result("B.O.B", id: 1), result("B.o.B", id: 2)],
            complete: true,
            details: [1: facts(1, "B.O.B", variations: ["Bob"]), 2: facts(2, "B.o.B", variations: ["Bob"])]
        )

        XCTAssertEqual(verdict, .ambiguous([1, 2]))
    }

    /// Twin S and TWÏNS fold together once spaces and diacritics go, and are
    /// different artists. Nothing Discogs says links them, so nothing does.
    func testSpacingAndDiacriticsAloneAreNotASpelling() {
        let verdict = SpellingCheck.verdict(
            spelling: "TWÏNS",
            results: [result("Twin S", id: 77)],
            complete: true,
            details: [77: facts(77, "Twin S")]
        )

        XCTAssertEqual(verdict, .nobody)
    }
}

// MARK: - Resolving references

final class ArtistIdentityResolverTests: XCTestCase {
    private func resolver(
        spellings: [String: SpellingVerdict] = [:],
        links: [String: [Int]] = [:],
        extra: [DiscogsIdentityFacts] = []
    ) throws -> ArtistIdentityResolver {
        ArtistIdentityResolver(evidence: ArtistIdentityEvidence(
            facts: try ArtistIdentityFixtures.allFacts() + extra,
            spellings: spellings,
            musicBrainzLinks: links
        ))
    }

    func testBothSpellingsOfPrefuse73AreOneIdentity() throws {
        let resolver = try resolver(spellings: [
            ArtistSpelling.key("Prefuse73"): .variation(3722),
            ArtistSpelling.key("Prefuse 73"): .canonical([3722])
        ])

        let joined = resolver.resolve(ArtistReference(name: "Prefuse73"))
        let spaced = resolver.resolve(ArtistReference(name: "Prefuse 73"))

        XCTAssertEqual(joined.identity, .discogs(3722))
        XCTAssertEqual(spaced.identity, .discogs(3722))
        XCTAssertEqual(joined.basis, .nameVariation)
        XCTAssertEqual(joined.canonicalName, "Prefuse 73")
        XCTAssertTrue(joined.isRedirect)
        XCTAssertFalse(spaced.isRedirect)
        XCTAssertEqual(joined.equivalentNames, ["Prefuse 73", "Prefuse73"])
        XCTAssertEqual(spaced.equivalentNames, ["Prefuse 73", "Prefuse73"],
                       "Opening either spelling reads the records filed under both")
    }

    /// Before anything was checked, "Prefuse73" is only its own name. Prefuse
    /// 73 looks like it, and is kept as a possibility rather than followed.
    func testAnUncheckedSpellingStaysItsOwnName() throws {
        let resolution = try resolver().resolve(ArtistReference(name: "Prefuse73"))

        XCTAssertEqual(resolution.identity, .name("Prefuse73"))
        XCTAssertNil(resolution.basis)
        XCTAssertFalse(resolution.isRedirect)
        XCTAssertEqual(resolution.possibleMatches, [3722])
    }

    func testNamesakesAreNeverChosenBetweenByName() throws {
        let resolution = try resolver(spellings: [
            ArtistSpelling.key("Anika"): .canonical([555, 1982320])
        ]).resolve(ArtistReference(name: "Anika"))

        XCTAssertEqual(resolution.identity, .name("Anika"))
        XCTAssertEqual(resolution.possibleMatches, [555, 1982320])
    }

    func testAnIDTheReferenceCarriesDecides() throws {
        let resolution = try resolver(spellings: [
            ArtistSpelling.key("Anika"): .canonical([555, 1982320])
        ]).resolve(ArtistReference(name: "Anika", discogsID: 1982320))

        XCTAssertEqual(resolution.identity, .discogs(1982320))
        XCTAssertEqual(resolution.basis, .discogsID)
        XCTAssertEqual(resolution.canonicalName, "Anika")
    }

    /// MusicBrainz links Anika's MBID to both of her Discogs entries. Discogs
    /// keeps them as aliases with separate discographies, so each name opens
    /// its own, and they are linked rather than combined.
    func testAnikaAndAnnikaHendersonAreLinkedNotMerged() throws {
        let mbid = "15c0e62b-3e46-4666-845d-d6c86bd44774"
        let resolver = try resolver(links: [mbid: [1982320, 3999072]])

        let anika = resolver.resolve(ArtistReference(name: "Anika", mbid: mbid))
        let annika = resolver.resolve(ArtistReference(name: "Annika Henderson", mbid: mbid))

        XCTAssertEqual(anika.identity, .discogs(1982320))
        XCTAssertEqual(anika.basis, .musicBrainzLink)
        XCTAssertEqual(annika.identity, .discogs(3999072))
        XCTAssertEqual(anika.equivalentNames, ["Anika"], "Her real name is an alias, not a spelling")
        XCTAssertTrue(resolver.relations(of: 1982320).contains(
            ArtistRelation(identity: .discogs(3999072), name: "Annika Henderson", kind: .alias)))
    }

    func testSeveralMusicBrainzLinksAndNoMatchingNameSettleOnNone() throws {
        let mbid = "15c0e62b-3e46-4666-845d-d6c86bd44774"
        let resolution = try resolver(links: [mbid: [1982320, 3999072]])
            .resolve(ArtistReference(name: "ANIKA HENDERSON-ish", mbid: mbid))

        XCTAssertEqual(resolution.identity, .musicBrainz(mbid))
        XCTAssertEqual(resolution.possibleMatches, [1982320, 3999072])
    }

    func testMicaLeviAndMicachuStayTwoProjects() throws {
        let resolver = try resolver()

        let mica = resolver.resolve(ArtistReference(name: "Mica Levi", discogsID: 2576890))
        let micachu = resolver.resolve(ArtistReference(name: "Micachu", discogsID: 1172814))

        XCTAssertNotEqual(mica.identity, micachu.identity)
        XCTAssertEqual(mica.equivalentNames, ["Mica Levi"])
        XCTAssertTrue(resolver.relations(of: 2576890).contains(
            ArtistRelation(identity: .discogs(1172814), name: "Micachu", kind: .alias)))
        XCTAssertTrue(resolver.relations(of: 2576890).contains {
            $0.kind == .group && $0.name == "Micachu & The Shapes"
        })
    }

    func testIdentitiesAreStableStrings() {
        XCTAssertEqual(ArtistIdentity.name("Prefuse73").rawValue, "name:prefuse73")
        XCTAssertEqual(ArtistIdentity.discogs(3722).discogsID, 3722)
        XCTAssertEqual(ArtistIdentity.musicBrainz("ABC").rawValue, "mbid:abc")
        XCTAssertFalse(ArtistIdentity.name("x").isVerified)
    }
}

// MARK: - Preferred profiles

final class PreferredProfileResolverTests: XCTestCase {
    private let prefuse = ProfileCompleteness(
        releases: 441, credits: 60, hasBiography: true, hasArtwork: true, styles: 8, labels: 20, links: 8)
    private let scottHerren = ProfileCompleteness(releases: 128, hasBiography: true, hasArtwork: true)
    private let pianoOverlord = ProfileCompleteness(releases: 19, hasArtwork: true)
    private let retoSparse = ProfileCompleteness(releases: 2, hasArtwork: true)
    private let empty = ProfileCompleteness()

    private func resolver(_ completeness: [Int: ProfileCompleteness]) throws -> PreferredProfileResolver {
        PreferredProfileResolver(
            evidence: ArtistIdentityEvidence(facts: try ArtistIdentityFixtures.allFacts()),
            completeness: completeness
        )
    }

    /// Reto A Ichi has two records and no biography; Discogs lists Prefuse 73
    /// among its aliases. The page keeps Reto A Ichi's name and records and
    /// borrows Prefuse 73's description, attributed.
    func testASparseAliasBorrowsFromTheRichestAlias() throws {
        let choice = try resolver([
            6810891: retoSparse, 3722: prefuse, 229415: scottHerren, 227795: pianoOverlord
        ]).choice(for: .discogs(6810891))

        XCTAssertEqual(choice.mode, .ownWithFallback(.discogs(3722)))
        XCTAssertEqual(choice.opens, .discogs(6810891), "A sparse alias still opens as itself")
    }

    /// The navigation case: an alias whose own record says nothing opens the
    /// richer page, and the choice remembers where the listener came from.
    func testAnEmptyAliasOpensTheRichestRelatedProfile() throws {
        let choice = try resolver([
            6810891: empty, 3722: prefuse, 229415: scottHerren
        ]).choice(for: .discogs(6810891))

        XCTAssertEqual(choice.mode, .openRelated(.discogs(3722)))
        XCTAssertEqual(choice.opens, .discogs(3722))
        XCTAssertEqual(choice.subject, .discogs(6810891))
    }

    func testARichProfileIsShownAsItself() throws {
        let choice = try resolver([3722: prefuse, 229415: scottHerren]).choice(for: .discogs(3722))
        XCTAssertEqual(choice.mode, .own)
    }

    func testAnAliasNobodyHasReadIsNeverPreferred() throws {
        let choice = try resolver([6810891: empty]).choice(for: .discogs(6810891))
        XCTAssertEqual(choice.mode, .own)
    }

    /// Recomputed from what is known now: when Prefuse 73's record arrives,
    /// it replaces Piano Overlord without anything being rewritten.
    func testThePreferenceMovesWhenARicherRecordArrives() throws {
        var known: [Int: ProfileCompleteness] = [6810891: retoSparse, 227795: pianoOverlord]
        XCTAssertEqual(try resolver(known).choice(for: .discogs(6810891)).mode, .ownWithFallback(.discogs(227795)))

        known[3722] = prefuse
        XCTAssertEqual(try resolver(known).choice(for: .discogs(6810891)).mode, .ownWithFallback(.discogs(3722)))
    }

    func testATieGoesToTheLowerID() {
        let resolver = PreferredProfileResolver(
            evidence: ArtistIdentityEvidence(facts: [
                facts(10, "Subject", aliases: [(30, "B"), (20, "A")]),
                facts(20, "A"), facts(30, "B")
            ]),
            completeness: [10: empty, 20: pianoOverlord, 30: pianoOverlord]
        )
        XCTAssertEqual(resolver.choice(for: .discogs(10)).mode, .openRelated(.discogs(20)))
    }

    /// A group is somebody else's discography as well. Mica Levi's bands are
    /// related to her, never shown in her place.
    func testAGroupIsNeverPreferred() throws {
        // Micachu & The Shapes, richly known; her aliases unknown.
        let choice = try resolver([2576890: empty, 8234107: prefuse]).choice(for: .discogs(2576890))
        XCTAssertEqual(choice.mode, .own)
        // The same record known as her alias Micachu is preferred, which is
        // what shows the rule above is about groups and not about records.
        let alias = try resolver([2576890: empty, 1172814: prefuse]).choice(for: .discogs(2576890))
        XCTAssertEqual(alias.mode, .openRelated(.discogs(1172814)))
    }

    func testNameIdentitiesHaveNoProfileToPrefer() throws {
        let choice = try resolver([3722: prefuse]).choice(for: .name("Prefuse73"))
        XCTAssertEqual(choice.mode, .own)
    }
}
