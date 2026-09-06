//
//  SceneRosterTests.swift
//  IndigoTests
//
//  A scene page could only list the artists this listener's own catalogue had
//  already met — eight names under "New York / Jazz", which is a story about
//  one record shelf rather than about a scene. The rest is in MusicBrainz,
//  which asks for one request a second from a named client: a phone cannot
//  honour that, and a few hundred copies of the app certainly cannot.
//
//  So the crawl belongs to the backend and the app reads a table. What is
//  pinned here is the part the app is responsible for — the address it asks
//  under, and the query the worker builds from it.
//

import XCTest
@testable import Indigo

final class SceneRosterTests: XCTestCase {

    // MARK: The address

    /// The keys are computed in the app because there is no normalizer in
    /// Postgres: the app and the worker each carry one and
    /// `NormalizationParityTests` keeps them in step. A third in SQL would be
    /// a third thing to drift.
    func testASceneIsAskedForUnderTheSameKeysItIsNamedBy() {
        XCTAssertEqual(RecordingKey.normalize("New York"), "new york")
        XCTAssertEqual(RecordingKey.normalize("Hard Techno"), "hard techno")
        // A place with no sound of its own asks under an empty one, which is
        // what the roster table stores for it.
        XCTAssertEqual(RecordingKey.normalize(nil), "")
    }

    func testTwoScenesInOnePlaceAskUnderDifferentAddresses() {
        let techno = MusicNode.scene(city: "Manchester", sound: "Hard Techno")
        let hipHop = MusicNode.scene(city: "Manchester", sound: "Hip Hop")
        XCTAssertNotEqual(techno.id, hipHop.id)
        // And each carries its own half of the address, so a page can ask for
        // the scene it is showing rather than for its city.
        XCTAssertEqual(techno.providerID, "Manchester")
        XCTAssertEqual(techno.handle, "Hard Techno")
    }

    // MARK: What a member reads as

    private func member(
        began: Int?, ended: Int?
    ) -> SceneRepository.Member {
        let json = """
        {"name":"Anthony Braxton","normalized_name":"anthony braxton","mbid":null,
         "area":"New York","began_year":\(began.map(String.init) ?? "null"),
         "ended_year":\(ended.map(String.init) ?? "null"),
         "disambiguation":null,"score":100}
        """
        return try! JSONDecoder().decode(SceneRepository.Member.self, from: Data(json.utf8))
    }

    func testAMemberSaysWhenTheyWereAround() {
        XCTAssertEqual(member(began: 1968, ended: 1994).yearsLabel, "1968–1994")
        XCTAssertEqual(member(began: 2011, ended: nil).yearsLabel, "since 2011")
        XCTAssertEqual(member(began: nil, ended: 1994).yearsLabel, "until 1994")
        // Silence is a real answer rather than a guess.
        XCTAssertNil(member(began: nil, ended: nil).yearsLabel)
    }

    func testAMemberIsIdentifiedByTheNameEverythingElseComparesOn() {
        // So a name found upstream can be matched against the artists the
        // listener already has, and shown once rather than twice.
        XCTAssertEqual(member(began: nil, ended: nil).id, "anthony braxton")
        XCTAssertEqual(
            member(began: nil, ended: nil).normalizedName,
            RecordingKey.normalize("Anthony Braxton")
        )
    }

    func testARosterStillFillingIsUsableAndSaysSo() {
        func roster(_ status: String) -> SceneRepository.Roster {
            let json = """
            {"id":"11111111-1111-1111-1111-111111111111","status":"\(status)",
             "member_count":40,"total_available":300}
            """
            return try! JSONDecoder().decode(SceneRepository.Roster.self, from: Data(json.utf8))
        }
        // Half a scene is more than none, and worth marking as half.
        XCTAssertFalse(roster("filling").isComplete)
        XCTAssertTrue(roster("ready").isComplete)
        XCTAssertEqual(roster("filling").memberCount, 40)
    }
}
