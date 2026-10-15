//
//  NamesakeAttributionTests.swift
//  IndigoTests
//
//  Two artists file their records under "Hype Williams": Dean Blunt and Inga
//  Copeland's duo (Discogs 1874027, "Hype Williams (2)") and the director
//  (here 82). Each page gathered the other's. A release whose credits name an
//  entry says whose it is; one known only by name stays where it is.
//

import XCTest
import SwiftData
@testable import Indigo

private let duo = 1874027
private let director = 82

private func credit(_ name: String, id: Int?, credited: String? = nil) -> ReleaseCredit {
    ReleaseCredit(category: .artist, order: 0, creditedName: credited ?? name, filingName: name,
                  discogsID: id, role: "", tracks: "")
}

final class ReleaseAttributionDecisionTests: XCTestCase {
    private let keys: Set<String> = [RecordingKey.normalizeArtist("Hype Williams")]

    func testACreditNamingThisArtistVerifiesIt() {
        let decided = ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys,
                                                credits: [credit("Hype Williams (2)", id: duo)])
        XCTAssertEqual(decided.verdict, .verified)
        XCTAssertEqual(decided.confidence, 1)
    }

    func testCreditsNamingOnlyAnotherEntryExcludeIt() {
        let decided = ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys,
                                                credits: [credit("Hype Williams", id: director)])
        XCTAssertEqual(decided.verdict, .otherArtist)
        XCTAssertFalse(decided.isShown)
        XCTAssertEqual(decided.evidence, "credits name discogs:\(director)")
    }

    func testNoCreditsHeldIsANameAndStays() {
        let decided = ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys, credits: nil)
        XCTAssertEqual(decided.verdict, .nameOnly)
        XCTAssertTrue(decided.isShown)
        XCTAssertEqual(decided.confidence, 0.5)
    }

    func testACreditWithNoEntryIsNotEvidenceAgainst() {
        let decided = ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys, credits: [
            credit("Hype Williams", id: director), credit("Hype Williams", id: nil)
        ])
        XCTAssertEqual(decided.verdict, .nameOnly)
    }

    /// A page that is only a name has no entry to contradict.
    func testAPageWithNoEntryExcludesNothing() {
        let decided = ReleaseAttribution.decide(subjectID: nil, subjectKeys: keys,
                                                credits: [credit("Hype Williams", id: director)])
        XCTAssertEqual(decided.verdict, .nameOnly)
    }

    /// A split by both namesakes belongs to both.
    func testASplitBetweenNamesakesIsOnBothPages() {
        let split = [credit("Hype Williams (2)", id: duo), credit("Hype Williams", id: director)]
        XCTAssertEqual(ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys, credits: split).verdict, .verified)
        XCTAssertEqual(ReleaseAttribution.decide(subjectID: director, subjectKeys: keys, credits: split).verdict, .verified)
    }

    /// A record crediting Prefuse 73 as "Prefuse73" is his, read under either.
    func testACreditedSpellingCounts() {
        let decided = ReleaseAttribution.decide(
            subjectID: 3722, subjectKeys: [RecordingKey.normalizeArtist("Prefuse73")],
            credits: [credit("Prefuse 73", id: 3722, credited: "Prefuse73")]
        )
        XCTAssertEqual(decided.verdict, .verified)
    }

    /// Credits for somebody else entirely, under another name, say nothing
    /// about whose a release filed under this one is.
    func testCreditsUnderOtherNamesAreNotWeighed() {
        let decided = ReleaseAttribution.decide(subjectID: duo, subjectKeys: keys,
                                                credits: [credit("Dean Blunt", id: 999)])
        XCTAssertEqual(decided.verdict, .nameOnly)
    }
}

@MainActor
final class NamesakeDiscographyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private var enricher: DiscogsEnricher { DiscogsEnricher(context: context, client: DiscogsClient()) }

    private func release(_ id: Int, _ title: String, by artistID: Int, filing: String, label: String) throws {
        let json = """
        {"id":\(id),"title":"\(title)","year":2010,
         "artists":[{"id":\(artistID),"name":"\(filing)"}],
         "labels":[{"id":\(id + 100),"name":"\(label)","catno":"X\(id)"}]}
        """
        enricher.store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
    }

    /// A release cached by name alone, as older builds kept them.
    private func nameOnlyRelease(_ id: Int, _ title: String) {
        let record = DiscogsReleaseRecord(discogsID: id, title: title)
        record.artistNames = ["Hype Williams"]
        record.year = 2011
        context.insert(record)
    }

    private func pages() throws {
        try release(1, "One Nation", by: duo, filing: "Hype Williams (2)", label: "Hippos In Tanks")
        try release(2, "Belly", by: director, filing: "Hype Williams", label: "Palm Pictures")
        nameOnlyRelease(3, "Untitled Tape")
        try context.save()
    }

    private func titles(_ profile: ArtistProfile) -> Set<String> { Set(profile.releases.map(\.title)) }

    func testEachNamesakeKeepsOnlyWhatIsTheirs() throws {
        try pages()
        let engine = DigEngine(context: context)

        let duoPage = engine.artistProfile(name: "Hype Williams", mbid: nil, discogsID: duo)
        let directorPage = DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil, discogsID: director)

        XCTAssertEqual(titles(duoPage), ["One Nation", "Untitled Tape"])
        XCTAssertEqual(titles(directorPage), ["Belly", "Untitled Tape"],
                       "A record known only by name stays on both: nothing says it is anyone else's")
        XCTAssertFalse(duoPage.labels.map(\.name).contains("Palm Pictures"), "Nor the other's labels")
        XCTAssertTrue(duoPage.labels.map(\.name).contains("Hippos In Tanks"))
    }

    /// The decision is internal: kept on each line, never a separate list.
    func testTheAttributionIsKeptOnTheLine() throws {
        try pages()
        let page = DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil, discogsID: duo)

        let byTitle = Dictionary(uniqueKeysWithValues: page.releases.map { ($0.title, $0.attribution?.verdict) })
        XCTAssertEqual(byTitle["One Nation"], .verified)
        XCTAssertEqual(byTitle["Untitled Tape"], .nameOnly)
    }

    /// When the evidence arrives the page follows, with nothing rewritten.
    func testEvidenceArrivingLaterMovesARecordOff() throws {
        try pages()
        XCTAssertTrue(titles(DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil, discogsID: duo))
            .contains("Untitled Tape"))

        try release(3, "Untitled Tape", by: director, filing: "Hype Williams", label: "Palm Pictures")
        try context.save()

        XCTAssertFalse(titles(DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil, discogsID: duo))
            .contains("Untitled Tape"))
    }

    /// The same record from the artist's own shelf and from the release cache
    /// is one line, and its own shelf is what places it there.
    func testARecordKnownTwiceIsOneLine() throws {
        try pages()
        let shelf = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Hype Williams"), discogsID: duo, name: "Hype Williams (2)")
        shelf.releaseTitles = ["One Nation"]
        shelf.releaseYears = ["2010"]
        shelf.releaseDiscogsIDs = [1]
        shelf.releaseImageURLStrings = [""]
        shelf.releaseLabels = ["Hippos In Tanks"]
        context.insert(shelf)
        try context.save()

        let page = DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil)
        XCTAssertEqual(page.releases.filter { $0.title == "One Nation" }.count, 1)
        XCTAssertFalse(titles(page).contains("Belly"),
                       "The page's entry comes from the record filed under its name when it was opened by name")
    }

    /// A page that is only a name — somebody known from a tracklist — keeps
    /// everything filed under it, as it always did.
    func testANameOnlyPageIsUnchanged() throws {
        try pages()
        let page = DigEngine(context: context).artistProfile(name: "Hype Williams", mbid: nil)
        XCTAssertEqual(titles(page), ["One Nation", "Belly", "Untitled Tape"])
    }
}
