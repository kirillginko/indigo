//
//  SupabaseConfigurationTests.swift
//  IndigoTests
//
//  The backend URL is assembled from a project ref held in xcconfig, where a
//  `//` opens a comment. Pasting the full https:// URL there truncates it to
//  `https:` and the build still succeeds, so the cost of getting this wrong is
//  a backend that is quietly unreachable rather than a compile error. These
//  cover the shapes that mistake actually produces.
//

import XCTest
@testable import Indigo

final class SupabaseConfigurationTests: XCTestCase {
    func testBareRefBecomesAProjectURL() {
        XCTAssertEqual(
            SupabaseConfiguration.url(fromRef: "leynozulpkjuufbbjjpa"),
            URL(string: "https://leynozulpkjuufbbjjpa.supabase.co")
        )
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(
            SupabaseConfiguration.url(fromRef: "  leynozulpkjuufbbjjpa\n"),
            URL(string: "https://leynozulpkjuufbbjjpa.supabase.co")
        )
    }

    /// The environment override is a natural place to paste a whole URL.
    func testAFullURLIsTakenAsGiven() {
        XCTAssertEqual(
            SupabaseConfiguration.url(fromRef: "https://leynozulpkjuufbbjjpa.supabase.co"),
            URL(string: "https://leynozulpkjuufbbjjpa.supabase.co")
        )
    }

    /// What an xcconfig leaves behind after truncating at `//`. Nothing about
    /// it is ref-shaped, and splicing it would yield `https://https:.supabase.co`.
    func testATruncatedURLResolvesToNothing() {
        XCTAssertNil(SupabaseConfiguration.url(fromRef: "https:"))
    }

    func testAnEmptyRefResolvesToNothing() {
        XCTAssertNil(SupabaseConfiguration.url(fromRef: ""))
        XCTAssertNil(SupabaseConfiguration.url(fromRef: "   "))
    }

    func testARefCarryingHostPunctuationResolvesToNothing() {
        XCTAssertNil(SupabaseConfiguration.url(fromRef: "leynozulpkjuufbbjjpa.supabase.co"))
        XCTAssertNil(SupabaseConfiguration.url(fromRef: "$(SUPABASE_PROJECT_REF)"))
    }
}
