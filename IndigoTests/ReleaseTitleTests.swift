//
//  ReleaseTitleTests.swift
//  IndigoTests
//
//  Discogs writes a release title as the sleeve prints it, credit and all:
//  "Boards Of Canada = ボーズ・オブ・カナダ* - Inferno = インフェルノ". Stored
//  that way, the credit is later handed to a `release_title` search, which
//  matches on the title alone and so finds nothing — and the record opens as
//  one no catalogue has an entry for, which is a lie about a record that is
//  right there in the catalogue.
//

import XCTest
@testable import Indigo

final class ReleaseTitleTests: XCTestCase {
    private func strip(_ title: String, artist: String) -> String {
        DiscogsEnricher.releaseTitle(title, artist: artist)
    }

    func testAPlainCreditIsStripped() {
        XCTAssertEqual(strip("Skee Mask - Compro", artist: "Skee Mask"), "Compro")
    }

    /// The case from the screenshot: the credit carries a translation and a
    /// disambiguating asterisk, so an exact match never fired.
    func testATranslatedCreditIsStripped() {
        XCTAssertEqual(
            strip("Boards Of Canada = ボーズ・オブ・カナダ* - Inferno = インフェルノ",
                  artist: "Boards Of Canada"),
            "Inferno = インフェルノ")
    }

    func testANumericDisambiguatorIsStripped() {
        XCTAssertEqual(strip("Speedkiller (2) - Inferno", artist: "Speedkiller"), "Inferno")
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertEqual(strip("JÜRGEN PAAPE - So Weit Wie Noch Nie", artist: "Jurgen Paape"),
                       "So Weit Wie Noch Nie")
    }

    /// A hyphen in a title is not a credit. Stripping here would rename the
    /// record after its own second half.
    func testATitleThatMerelyContainsAHyphenIsLeftAlone() {
        XCTAssertEqual(strip("Blue - Green", artist: "Aphex Twin"), "Blue - Green")
    }

    /// A different artist's name in front is a compilation credit, not this
    /// artist's, and removing it would misattribute the record.
    func testAnotherArtistsCreditIsLeftAlone() {
        XCTAssertEqual(strip("Autechre - Amber", artist: "Boards Of Canada"),
                       "Autechre - Amber")
    }

    /// "Boards" must not match "Boards Of Canada": a prefix has to end on a
    /// word boundary or half the catalogue matches half the artists.
    func testAPartialWordIsNotACredit() {
        XCTAssertEqual(strip("Boardsmith - Ledger", artist: "Boards"), "Boardsmith - Ledger")
    }

    func testNothingIsStrippedIfNothingWouldRemain() {
        XCTAssertEqual(strip("Aphex Twin - ", artist: "Aphex Twin"), "Aphex Twin - ")
    }

    func testAnEmptyArtistStripsNothing() {
        XCTAssertEqual(strip("Skee Mask - Compro", artist: ""), "Skee Mask - Compro")
    }
}
