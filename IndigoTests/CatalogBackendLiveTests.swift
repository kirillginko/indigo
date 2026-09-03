//
//  CatalogBackendLiveTests.swift
//  IndigoTests
//
//  The one thing fixtures cannot prove: that Indigo's own types decode what the
//  backend actually sends. Opt-in, because the rest of the suite is offline by
//  design and a test that fails on a train is worse than no test.
//
//  Set INDIGO_LIVE_BACKEND_TESTS=1 in the Indigo scheme's Test action, under
//  Arguments -> Environment Variables, then run this class.
//
//  Note it cannot be switched on from the command line: these are hosted in
//  Indigo.app, and xcodebuild passes neither its own environment nor
//  TEST_RUNNER_-prefixed settings through to a unit-test host. Both were tried.
//

import XCTest
@testable import Indigo

final class CatalogBackendLiveTests: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["INDIGO_LIVE_BACKEND_TESTS"] == "1"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(isEnabled, "Set INDIGO_LIVE_BACKEND_TESTS=1 to run against the live backend.")
        try XCTSkipUnless(SupabaseService.isConfigured, "Backend is not configured for this build.")
    }

    /// Rick Astley, Never Gonna Give You Up. Cached during the backend
    /// bring-up, and a release that is not going to be deleted.
    private let knownRelease = "249504"

    func testTheCacheDecodesIntoIndigosOwnTypes() async throws {
        struct DiscogsRelease: Decodable, Sendable {
            let id: Int
            let title: String
            let year: Int?
        }

        let cached = try await MetadataRepository.shared.cached(
            DiscogsRelease.self,
            provider: "discogs",
            resourceType: "release",
            resourceID: knownRelease
        )

        let hit = try XCTUnwrap(cached, "Expected the bring-up release to still be cached.")
        XCTAssertEqual(hit.value.id, 249504)
        XCTAssertFalse(hit.value.title.isEmpty)
        XCTAssertTrue(hit.isFresh, "A 60-day payload cached during bring-up should not be stale yet.")
    }

    func testAMissReadsAsAMissRatherThanAnError() async throws {
        struct Anything: Decodable, Sendable {}

        let cached = try await MetadataRepository.shared.cached(
            Anything.self,
            provider: "discogs",
            resourceType: "release",
            resourceID: "000000000"
        )
        XCTAssertNil(cached)
    }

    // MARK: - The normalized graph
    //
    // Asserted against the release the backend was brought up on, which
    // catalog-refresh normalized into artist, label, release, external ids and
    // artwork. This is the whole point of the schema: DIG asks Postgres these
    // questions instead of asking Discogs.

    private let knownArtistDiscogsID = "72872"

    func testAnArtistIsReachableByNameAndByUpstreamID() async throws {
        let byExternal = try await ArtistRepository.shared.artist(
            externalID: knownArtistDiscogsID, provider: "discogs")
        let artist = try XCTUnwrap(byExternal)
        XCTAssertEqual(artist.name, "Rick Astley")
        XCTAssertEqual(artist.normalizedName, RecordingKey.normalize(artist.name))

        // The normalized_name written by the Edge Function has to match what
        // the app computes, or a name lookup finds nothing at all.
        let byName = try await ArtistRepository.shared.artists(named: "Rick Astley")
        XCTAssertEqual(byName.map(\.id), [artist.id])

        let byID = try await ArtistRepository.shared.artist(id: artist.id)
        XCTAssertEqual(byID?.id, artist.id)
    }

    func testALabelIsReachableByName() async throws {
        let labels = try await LabelRepository.shared.labels(named: "RCA")
        let label = try XCTUnwrap(labels.first)
        XCTAssertEqual(label.name, "RCA")

        let byID = try await LabelRepository.shared.label(id: label.id)
        XCTAssertEqual(byID?.id, label.id)
    }

    /// The catalogue number is what a record calls itself when nothing else
    /// agrees — the string printed on the sleeve.
    func testAReleaseCarriesItsCatalogueDetail() async throws {
        let found = try await ReleaseRepository.shared.release(externalID: "249504", provider: "discogs")
        let release = try XCTUnwrap(found)

        XCTAssertEqual(release.title, "Never Gonna Give You Up")
        XCTAssertEqual(release.releaseYear, 1987)
        XCTAssertEqual(release.catalogNumber, "PB 41447")
        XCTAssertNotNil(release.artistID)
        XCTAssertNotNil(release.labelID)

        let byCatalogNumber = try await ReleaseRepository.shared.releases(catalogNumber: "PB 41447")
        XCTAssertTrue(byCatalogNumber.contains { $0.id == release.id })
    }

    /// The join the DIG label page is built on, answered in one round trip.
    func testALabelsCatalogueComesBackFromPostgres() async throws {
        let found = try await ReleaseRepository.shared.release(externalID: "249504", provider: "discogs")
        let release = try XCTUnwrap(found)
        let labelID = try XCTUnwrap(release.labelID)
        let artistID = try XCTUnwrap(release.artistID)

        let onLabel = try await ReleaseRepository.shared.releases(onLabel: labelID)
        XCTAssertTrue(onLabel.contains { $0.id == release.id })

        let byArtist = try await ReleaseRepository.shared.releases(byArtist: artistID)
        XCTAssertTrue(byArtist.contains { $0.id == release.id })
    }

    /// Discogs does not clearly license re-hosting, so this row is expected to
    /// carry an upstream URL and no storage path — a complete answer, not a
    /// half-filled cache entry.
    func testArtworkResolvesToTheProviderUntilItIsRehosted() async throws {
        let found = try await ReleaseRepository.shared.release(externalID: "249504", provider: "discogs")
        let release = try XCTUnwrap(found)

        let artworkRow = try await ArtworkRepository.shared.artwork(for: .release, id: release.id)
        let row = try XCTUnwrap(artworkRow)
        XCTAssertNotNil(row.originalURL)

        let imageURL = try await ArtworkRepository.shared.imageURL(for: .release, id: release.id)
        let resolved = try XCTUnwrap(imageURL)
        XCTAssertFalse(resolved.isCached)
    }

    func testAnAbsentEntityReadsAsNothingRatherThanAnError() async throws {
        let artist = try await ArtistRepository.shared.artist(id: UUID())
        XCTAssertNil(artist)

        let release = try await ReleaseRepository.shared.release(externalID: "0", provider: "discogs")
        XCTAssertNil(release)

        let labels = try await LabelRepository.shared.labels(named: "No Such Label At All")
        XCTAssertTrue(labels.isEmpty)
    }

    // MARK: - The DIG integration
    //
    // CatalogReleaseSource is inert under XCTest by default, so the fixture
    // tests that drive DiscogsEnricher stay offline. These construct it with
    // the guard lifted, which is the only way to exercise the real path.

    private var liveSource: CatalogReleaseSource { CatalogReleaseSource(isEnabled: true) }

    /// The whole point: a release page served without asking Discogs.
    func testAReleaseComesBackFromIndigosCacheNotTheProvider() async throws {
        let found = await liveSource.release(id: 249504)
        let detail = try XCTUnwrap(found)
        XCTAssertEqual(detail.id, 249504)
        XCTAssertEqual(detail.title, "Never Gonna Give You Up")
        XCTAssertEqual(detail.year, 1987)
        XCTAssertEqual(detail.labels?.first?.catno, "PB 41447")
    }

    /// A record no catalogue has claimed is a real state in this app, not a
    /// failure — the caller falls through to Discogs rather than showing an
    /// error, so this must not throw.
    func testAnUnknownReleaseFallsThroughQuietly() async {
        let detail = await liveSource.release(id: 999_999_999)
        XCTAssertNil(detail)
    }

    /// The guard that keeps the rest of the suite offline.
    func testTheSourceIsInertWhenDisabled() async {
        let detail = await CatalogReleaseSource(isEnabled: false).release(id: 249504)
        XCTAssertNil(detail)
    }

    /// A cache miss must not send the page through the Edge Function when the
    /// app can ask Discogs itself. Returning nil is how it hands over.
    func testAMissDefersToTheProviderWhenTheAppCanReachIt() async {
        let source = CatalogReleaseSource(isEnabled: true, canReachProviderDirectly: true)
        let detail = await source.release(id: 987_654_321)
        XCTAssertNil(detail)
    }

    /// A build with no credential of its own still reads the shared cache,
    /// which is quicker than Discogs and quicker than the function fronting it.
    func testABuildWithoutACredentialReadsTheSharedCache() async throws {
        let source = CatalogReleaseSource(isEnabled: true, canReachProviderDirectly: false)
        let found = await source.release(id: 249504)
        let detail = try XCTUnwrap(found, "The bring-up release should still be cached.")
        XCTAssertEqual(detail.id, 249504)
    }

    /// Even a cached release is handed over when the app can fetch it itself:
    /// the probe costs about a fifth of a second and, against a cache holding
    /// a few dozen records, almost never earns it back.
    func testACachedReleaseIsStillHandedOverWhenTheAppCanFetchItself() async {
        let source = CatalogReleaseSource(isEnabled: true, canReachProviderDirectly: true)
        let detail = await source.release(id: 249504)
        XCTAssertNil(detail)
    }

    // MARK: - Discogs without a bundled credential
    //
    // The app no longer carries a Discogs token, so every one of these would
    // have been impossible a moment ago. The gateway is inert under XCTest by
    // default; these lift that guard deliberately.

    private var liveGateway: CatalogDiscogsGateway { CatalogDiscogsGateway(isEnabled: true) }

    func testASearchGoesThroughIndigosBackend() async throws {
        let response = try await liveGateway.get(
            DiscogsSearchResponse.self,
            path: "database/search",
            query: [
                URLQueryItem(name: "q", value: "Skee Mask"),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "per_page", value: "3"),
            ])
        let results = try XCTUnwrap(response.results)
        XCTAssertFalse(results.isEmpty)
    }

    func testAnArtistDetailGoesThroughIndigosBackend() async throws {
        let detail = try await liveGateway.get(
            DiscogsArtistDetail.self, path: "artists/72872", query: [])
        XCTAssertEqual(detail.name, "Rick Astley")
    }

    /// Searches go stale as a catalogue grows; a pressed record does not.
    func testSearchesExpireSoonerThanCatalogueEntries() {
        XCTAssertLessThan(
            CatalogDiscogsGateway.lifetime(forPath: "database/search"),
            CatalogDiscogsGateway.lifetime(forPath: "releases/249504"))
    }

    /// The token ships again, for the latency reasons in DiscogsClient.get —
    /// but scrambled, so it is not readable from the bundle at a glance.
    /// ObfuscatedSecretTests covers the unscrambling; this covers the promise
    /// that the plain value is not sitting there.
    func testTheShippedCredentialIsNotStoredInTheClear() throws {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String
        let blob = try XCTUnwrap(bundled)
        try XCTSkipIf(blob.contains("$("), "No token configured in this build.")

        let token = try XCTUnwrap(ObfuscatedSecret.reveal(blob))
        XCTAssertNotEqual(blob, token)
        XCTAssertFalse(blob.contains(token))
        // A "/" here would be truncated by xcconfig's comment syntax.
        XCTAssertFalse(blob.contains("/"))
    }

    /// Proves the whole resolution order in one call: the function answers from
    /// cache, and the payload still decodes on Indigo's side.
    func testRefreshReturnsAPayloadTheAppCanRead() async throws {
        struct DiscogsRelease: Decodable, Sendable {
            let id: Int
        }

        let payload = try await MetadataRepository.shared.refresh(
            DiscogsRelease.self,
            provider: "discogs",
            resourceType: "release",
            resourceID: knownRelease,
            lifetime: MetadataRepository.Lifetime.release
        )
        XCTAssertEqual(payload.id, 249504)
    }
}
