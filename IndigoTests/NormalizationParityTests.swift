//
//  NormalizationParityTests.swift
//  IndigoTests
//
//  RecordingKey.normalize decides what `normalized_name` holds in Postgres, and
//  the Edge Function has its own copy of the rule in TypeScript
//  (supabase/functions/_shared/normalize.ts). The app writes rows with one and
//  queries them with the other, so a disagreement does not surface as an error
//  — it surfaces as a lookup that quietly finds nothing.
//
//  These expectations were produced by the TypeScript implementation. If one
//  fails, the two have drifted and both sides need looking at, not just this
//  table.
//

import XCTest
@testable import Indigo

final class NormalizationParityTests: XCTestCase {
    /// Input, and what the TypeScript normalizer produces for it.
    private let cases: [(String, String)] = [
        ("Rick Astley", "rick astley"),
        ("  Jürgen  Paape ", "jurgen paape"),
        ("Björk", "bjork"),
        ("MOTORBASS", "motorbass"),
        ("Aphex Twin (UK)", "aphex twin uk"),
        ("Skee Mask", "skee mask"),
        ("Ilian Tape", "ilian tape"),
        ("Étienne de Crécy", "etienne de crecy"),
        ("DJ  Koze!!!", "dj koze"),
        ("Ryuichi Sakamoto", "ryuichi sakamoto"),
        ("坂本 龍一", "坂本 龍一"),
        ("Кино", "кино"),
        ("ＮＴＳ", "nts"),
        ("AC/DC", "ac dc"),
        ("Simon & Garfunkel", "simon garfunkel"),
        ("Nathan Fake — Drowning", "nathan fake drowning"),
        ("Jose Gonzalez", "jose gonzalez"),
        ("José González", "jose gonzalez"),
        ("4hero", "4hero"),
        ("808 State", "808 state"),
        ("", ""),
        ("   ", ""),
        ("Motörhead", "motorhead"),
        ("½ Man", "½ man"),
        ("Ø (Mika Vainio)", "ø mika vainio")
    ]

    func testSwiftAgreesWithTheEdgeFunction() {
        for (input, expected) in cases {
            XCTAssertEqual(
                RecordingKey.normalize(input), expected,
                "normalize(\(String(reflecting: input))) disagrees with normalize.ts")
        }
    }
}
