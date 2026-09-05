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

    /// `normalize` answers a plain ASCII string with a byte loop instead of
    /// ICU, which is what makes it cheap enough to call for every credit on a
    /// page. That is only sound while it says exactly what the general path
    /// says — and the general path is the rule the table above pins down.
    ///
    /// Every ASCII character, alone and in company, rather than a handful
    /// somebody thought of: the shortcut's whole risk is a character nobody
    /// remembered.
    func testTheASCIIShortcutSaysWhatTheGeneralPathSays() {
        var samples = ["", " ", "  ", "Skee Mask - Rev8617 [Official Audio]"]
        for code in 0..<128 {
            let character = String(UnicodeScalar(UInt8(code)))
            samples += [character, "a\(character)b", " \(character) ",
                        "\(character)\(character)", "\(character)tail"]
        }
        for sample in samples {
            XCTAssertEqual(
                RecordingKey.normalize(sample), Self.generalPath(sample),
                "The shortcut disagrees about \(String(reflecting: sample))")
        }
    }

    /// The rule with no shortcut in it: fold the case, the width and the
    /// diacritics, turn everything that is not alphanumeric into a gap, and
    /// collapse the gaps.
    private static func generalPath(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
