//
//  ArtworkRepositoryTests.swift
//  IndigoTests
//
//  Choosing which URL a record's picture comes from. Pure resolution, no
//  network — the fallbacks matter because a provider that forbids re-hosting
//  leaves rows that are cached-in-part or not at all.
//

import XCTest
@testable import Indigo

final class ArtworkRepositoryTests: XCTestCase {
    private func row(
        thumbnail: String? = nil,
        medium: String? = nil,
        large: String? = nil,
        storage: String? = nil,
        original: String? = nil
    ) -> Catalog.Artwork {
        Catalog.Artwork(
            id: UUID(),
            entityType: .release,
            entityID: UUID(),
            provider: "discogs",
            originalURL: original,
            storagePath: storage,
            thumbnailPath: thumbnail,
            mediumPath: medium,
            largePath: large,
            width: nil,
            height: nil,
            fetchedAt: nil
        )
    }

    func testTheRequestedSizeWinsWhenItIsThere() throws {
        let resolved = try XCTUnwrap(
            ArtworkRepository.shared.resolve(
                row(thumbnail: "releases/a/thumb.webp", medium: "releases/a/medium.webp"),
                size: .medium))

        XCTAssertTrue(resolved.isCached)
        XCTAssertTrue(resolved.url.absoluteString.hasSuffix("/artwork/releases/a/medium.webp"))
    }

    /// A half-populated row should still render rather than sending the caller
    /// upstream for an image Indigo already holds at another size.
    func testAMissingSizeFallsBackWithinTheCache() throws {
        let resolved = try XCTUnwrap(
            ArtworkRepository.shared.resolve(row(large: "releases/a/large.webp"), size: .medium))

        XCTAssertTrue(resolved.isCached)
        XCTAssertTrue(resolved.url.absoluteString.hasSuffix("/artwork/releases/a/large.webp"))
    }

    /// The re-hosting case from the build plan: a row that legitimately has
    /// only the provider's URL.
    func testAnUncachedRowFallsBackToTheProvider() throws {
        let resolved = try XCTUnwrap(
            ArtworkRepository.shared.resolve(
                row(original: "https://img.discogs.com/x.jpeg"), size: .large))

        XCTAssertFalse(resolved.isCached)
        XCTAssertEqual(resolved.url.absoluteString, "https://img.discogs.com/x.jpeg")
    }

    func testCachedSizesAreStillPreferredOverTheProvider() throws {
        let resolved = try XCTUnwrap(
            ArtworkRepository.shared.resolve(
                row(thumbnail: "releases/a/thumb.webp", original: "https://img.discogs.com/x.jpeg"),
                size: .large))

        XCTAssertTrue(resolved.isCached)
    }

    func testAnEmptyRowResolvesToNothing() {
        XCTAssertNil(ArtworkRepository.shared.resolve(row(), size: .medium))
    }

    func testPublicURLRejectsAnEmptyPath() {
        XCTAssertNil(ArtworkRepository.publicURL(forPath: ""))
    }
}
