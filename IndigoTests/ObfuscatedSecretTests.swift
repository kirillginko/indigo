//
//  ObfuscatedSecretTests.swift
//  IndigoTests
//
//  The scrambling happens in Python at configure time and is undone in Swift at
//  launch. If the two drift, the app reads a corrupt token and every Discogs
//  request fails with a credential error that looks nothing like a build
//  problem. These blobs came out of Scripts/obfuscate-token.py.
//

import XCTest
@testable import Indigo

final class ObfuscatedSecretTests: XCTestCase {
    /// Plain value, and what the script produced for it.
    private let cases: [(String, String)] = [
        ("test-token-1234", "Bt7Yh5nhHgzHzau_vW1F"),
        ("AAAAbbbbCCCCddddEEEEffffGGGGhhhhIIIIjjjj", "M_rqstb3EwXh4MXN6zoVyJYM69DEwhwL0cnwOD4eMdDsjomB-cAQpA=="),
        ("a", "Ew=="),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "CsPTi8ztCR_a2_729yYJ1Ksx1u3a3AIV7vbPBy4OIcDdv7iw69ICtlzpIRUdByfU6IDJ99Pq_tja2_QmEwe4Qg=="),
        ("Ünïcode-tøken", "sSfFMBv2HgPHjvJNNzUUwg==")
    ]

    func testSwiftUnscramblesWhatTheScriptProduced() {
        for (plain, blob) in cases {
            XCTAssertEqual(ObfuscatedSecret.reveal(blob), plain,
                           "reveal disagrees with obfuscate-token.py for \(plain.prefix(8))…")
        }
    }

    func testConcealAndRevealAreInverses() {
        for (plain, _) in cases {
            XCTAssertEqual(ObfuscatedSecret.reveal(ObfuscatedSecret.conceal(plain)), plain)
        }
    }

    /// The scrambled form must not contain the plain one, or none of this is
    /// doing anything at all.
    func testTheBlobDoesNotContainThePlainValue() {
        for (plain, blob) in cases where plain.count > 4 {
            XCTAssertFalse(blob.contains(plain))
        }
    }

    /// The end-to-end check: the blob the build actually shipped unscrambles
    /// into something Discogs-token shaped. Asserts the shape, never the value.
    func testTheShippedBlobResolvesToAPlausibleToken() throws {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String
        let blob = try XCTUnwrap(bundled, "This build shipped no token at all.")
        try XCTSkipIf(blob.contains("$("), "No token configured in this build.")

        let token = try XCTUnwrap(ObfuscatedSecret.reveal(blob), "Shipped blob did not unscramble.")
        XCTAssertEqual(token.count, 40, "A Discogs personal access token is 40 characters.")
        XCTAssertTrue(token.allSatisfy(\.isLetter) || token.allSatisfy { $0.isLetter || $0.isNumber })
        XCTAssertFalse(blob.contains(token), "The blob must not contain the token it hides.")
    }

    /// A half-configured build reads as "no token" rather than as a token that
    /// fails every request.
    func testMalformedInputResolvesToNothing() {
        XCTAssertNil(ObfuscatedSecret.reveal(""))
        XCTAssertNil(ObfuscatedSecret.reveal("   "))
        XCTAssertNil(ObfuscatedSecret.reveal("$(DISCOGS_TOKEN_OBFUSCATED)"))
        XCTAssertNil(ObfuscatedSecret.reveal("not base64 at all !!!"))
    }
}
