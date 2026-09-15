//
//  CreditParityTests.swift
//  IndigoTests
//
//  `ArtistName.split` and `creditedNames` in `_shared/credit.ts` answer the
//  same question on two sides of the wire: who is on this record. The backend
//  decides which artist a radio appearance belongs to; the app decides whose
//  page it shows on. A disagreement does not fail — it invents a person, or
//  loses one, quietly.
//
//  Every case here has a twin in `supabase/functions/_shared/credit_test.ts`.
//

import XCTest
@testable import Indigo

final class CreditParityTests: XCTestCase {
    func testACreditNamingOneArtistStaysWhole() {
        XCTAssertEqual(ArtistName.split("Skee Mask"), ["Skee Mask"])
        XCTAssertEqual(ArtistName.split("Jean-Michel Jarre"), ["Jean-Michel Jarre"])
    }

    func testACommaNamesSeveralPeople() {
        XCTAssertEqual(ArtistName.split("DJ Krush, Abijah"), ["DJ Krush", "Abijah"])
        XCTAssertEqual(
            ArtistName.split("Chuck Strangers, Billy Woods, Zeroh"),
            ["Chuck Strangers", "Billy Woods", "Zeroh"])
    }

    /// The guard the whole split turns on. Splitting these invents four people
    /// who do not exist, which is worse than filing a duo under one name.
    func testAnAmpersandDoesNot() {
        XCTAssertEqual(ArtistName.split("Holden & Zimpel"), ["Holden & Zimpel"])
        XCTAssertEqual(ArtistName.split("Coco Steel & Lovebomb"), ["Coco Steel & Lovebomb"])
        XCTAssertEqual(
            ArtistName.split("Alexander Johansson & Mattias Fridell"),
            ["Alexander Johansson & Mattias Fridell"])
    }

    func testNorDoesTheWordAnd() {
        XCTAssertEqual(ArtistName.split("Goya Gumbani and Dom P"), ["Goya Gumbani and Dom P"])
    }

    func testTheFeaturingFormsNameSeveral() {
        XCTAssertEqual(
            ArtistName.split("Mount Kimbie feat. King Krule"), ["Mount Kimbie", "King Krule"])
        XCTAssertEqual(ArtistName.split("Burial ft. Four Tet"), ["Burial", "Four Tet"])
        XCTAssertEqual(
            ArtistName.split("Jah Balla X MikeyNYC X Ibu DaDon"),
            ["Jah Balla", "MikeyNYC", "Ibu DaDon"])
    }

    func testAnUnspacedHyphenBelongsToTheName() {
        XCTAssertEqual(ArtistName.split("Jean-Michel Jarre"), ["Jean-Michel Jarre"])
        XCTAssertEqual(
            ArtistName.split("Andrew Cyrille - Anthony Braxton"),
            ["Andrew Cyrille", "Anthony Braxton"])
    }

    func testAPlaceholderIsNobody() {
        XCTAssertEqual(ArtistName.split("Various"), [])
        XCTAssertEqual(ArtistName.split("Unknown Artist"), [])
        XCTAssertEqual(ArtistName.split(""), [])
        XCTAssertEqual(ArtistName.split(nil), [])
        XCTAssertEqual(ArtistName.split("Unknown Mortal Orchestra"), ["Unknown Mortal Orchestra"])
        XCTAssertEqual(ArtistName.split("Various Production"), ["Various Production"])
    }

    func testAPlaceholderAmongRealNamesIsDropped() {
        XCTAssertEqual(ArtistName.split("Skee Mask, Unknown"), ["Skee Mask"])
    }

    func testOneNameTwiceIsOneName() {
        XCTAssertEqual(ArtistName.split("Burial, Burial"), ["Burial"])
    }
}
