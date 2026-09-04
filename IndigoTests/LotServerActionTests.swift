//
//  LotServerActionTests.swift
//  IndigoTests
//
//  The Lot's server action ids are content hashes minted when the site builds,
//  so they go stale on a redeploy and every call still using one answers 404.
//  Both of Indigo's went stale at once: the Shows directory stopped loading
//  and the Index quietly shrank to a single unpageable page.
//
//  Recovery is reading the current id out of the site's own client bundle, so
//  what is pinned here is the shape of that bundle — trimmed from the real
//  pages on www.thelotradio.com.
//

import XCTest
@testable import Indigo

final class LotServerActionTests: XCTestCase {
    /// Turbopack's output, as the site actually ships it: the id, a short run
    /// of arguments, then the name the action was exported under.
    private let bundle = """
    (globalThis.TURBOPACK||(globalThis.TURBOPACK=[])).push([,526973,e=>{"use strict";\
    var t=e.i(447472),h=e.i(550724);let c=(0,h.createServerReference)\
    ("4052bb1bfa64a179284635d97f5f2035d6601ae0c8",h.callServer,void 0,h.findSourceMapURL,"getShows");\
    e.s(["ShowsList",0,({since:n})=>{}])}]);
    """

    func testTheIdIsReadOutOfTheBundleByTheNameItWasExportedUnder() {
        XCTAssertEqual(
            LotServerActions.actionID(named: "getShows", inScript: bundle),
            "4052bb1bfa64a179284635d97f5f2035d6601ae0c8"
        )
    }

    /// One chunk defines several actions. Picking the wrong one sends a
    /// perfectly valid request to a function that answers a different question.
    func testTheRightActionIsPickedOutOfAChunkThatDefinesSeveral() {
        let script = """
        let o=(0,l.createServerReference)("40740d22d56e20581ac3045e41535242ca8195d1eb",\
        l.callServer,void 0,l.findSourceMapURL,"getSavedEpisodes"),\
        h=(0,l.createServerReference)("40f27ab14ad5c5475deb83ded171a0f9361fa28ccf",\
        l.callServer,void 0,l.findSourceMapURL,"getSavedTracks"),\
        d=(0,l.createServerReference)("404c777e51da10a130ababf450109e62056d9dae07",\
        l.callServer,void 0,l.findSourceMapURL,"getEpisodes");
        """

        XCTAssertEqual(
            LotServerActions.actionID(named: "getEpisodes", inScript: script),
            "404c777e51da10a130ababf450109e62056d9dae07"
        )
        XCTAssertEqual(
            LotServerActions.actionID(named: "getSavedTracks", inScript: script),
            "40f27ab14ad5c5475deb83ded171a0f9361fa28ccf"
        )
    }

    /// A chunk that does not define the action must say so rather than hand
    /// back the nearest hash it happened to find — an id from the wrong module
    /// is a 404 that looks like the site is down.
    func testAChunkThatDoesNotDefineTheActionYieldsNothing() {
        XCTAssertNil(LotServerActions.actionID(named: "getEpisodes", inScript: bundle))
        XCTAssertNil(LotServerActions.actionID(named: "getShows", inScript: "no actions here"))
    }

    /// The hash and the name sit close together in one call. A hash from an
    /// unrelated statement far above must not be paired with a later name.
    func testAHashFarFromTheNameIsNotTakenForIt() {
        let script = """
        let unrelated="4052bb1bfa64a179284635d97f5f2035d6601ae0c8";\
        \(String(repeating: "var padding=\"x\";", count: 40))\
        let c=(0,h.createServerReference)("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\
        h.callServer,void 0,h.findSourceMapURL,"getShows");
        """

        XCTAssertEqual(
            LotServerActions.actionID(named: "getShows", inScript: script),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "The id belonging to the call, not the first hash in the file"
        )
    }

    // MARK: - The page

    private let markup = """
    <!DOCTYPE html><html data-dpl-id="dpl_Dtks65GRnQLg56p4g7VugXc68GBj" lang="en"><head>\
    <link rel="preload" as="script" href="/_next/static/chunks/159jqsb_oi4-d.js?dpl=dpl_Dtks65GRnQLg56p4g7VugXc68GBj"/>\
    <script src="/_next/static/chunks/01l3b_0_x8i8o.js?dpl=dpl_Dtks65GRnQLg56p4g7VugXc68GBj" async=""></script>\
    <script src="/_next/static/chunks/01l3b_0_x8i8o.js?dpl=dpl_Dtks65GRnQLg56p4g7VugXc68GBj" async=""></script>\
    <link rel="stylesheet" href="/_next/static/chunks/1c2h2e1kurstx.css"/>\
    </head><body></body></html>
    """

    func testTheChunksAPageLoadsAreFoundWithoutTheirCacheBuster() {
        let paths = LotServerActions.chunkPaths(inHTML: markup)

        XCTAssertEqual(paths, [
            "/_next/static/chunks/159jqsb_oi4-d.js",
            "/_next/static/chunks/01l3b_0_x8i8o.js"
        ], "Scripts only, each one once, and no ?dpl= — the bare path serves the file")
    }

    /// The deployment is what a cached id is worth trusting against: only a
    /// redeploy moves an id, so a matching build means an earlier session's
    /// answer still stands and the megabytes of scanning can be skipped.
    func testTheDeploymentThePageCameFromIsReadable() {
        XCTAssertEqual(
            LotServerActions.deploymentID(inHTML: markup),
            "dpl_Dtks65GRnQLg56p4g7VugXc68GBj"
        )
        XCTAssertNil(LotServerActions.deploymentID(inHTML: "<html lang=\"en\"></html>"))
    }

    /// Until a call has actually been refused there is nothing to discover, so
    /// the shipped id is what gets used — no page fetch on the happy path.
    func testTheShippedIdIsUsedUntilSomethingRefusesIt() async {
        let actions = LotServerActions()

        let id = await actions.id(for: LotServerActions.shows)
        XCTAssertFalse(id.isEmpty)
        XCTAssertTrue(
            id.range(of: "^[0-9a-f]{40,42}$", options: .regularExpression) != nil,
            "An action id is a hash; anything else would be refused before it was sent"
        )
    }
}
