//
//  CatalogReleaseSource.swift
//  Indigo
//
//  Indigo's own backend, standing in front of Discogs for release lookups.
//
//  The resolution order the build plan asks for is local cache, then Indigo's
//  cache, then the provider. DiscogsEnricher already had the first and the
//  last; this is the middle. When it can answer, the record was described by a
//  request some other Indigo made, and Discogs is never asked at all.
//
//  Answers nil rather than throwing. A backend that is down, unconfigured or
//  slow is a reason to fall through to Discogs, not a reason for a page to
//  fail — the app worked without any of this a moment ago.
//

import Foundation

nonisolated struct CatalogReleaseSource: Sendable {
    static let shared = CatalogReleaseSource()

    private let repository: MetadataRepository
    private let isEnabled: Bool

    init(
        repository: MetadataRepository = .shared,
        isEnabled: Bool = CatalogReleaseSource.isEnabledByDefault,
        canReachProviderDirectly: Bool = DiscogsConfiguration.token != nil
    ) {
        self.repository = repository
        self.isEnabled = isEnabled
        self.canReachProviderDirectly = canReachProviderDirectly
    }

    /// Off under XCTest, for the reason DiscogsConfiguration is: the fixture
    /// tests drive the enricher with a stub client, and a packaged credential
    /// must not quietly turn those into live calls. Tests that do want the
    /// backend talk to MetadataRepository directly.
    static var isEnabledByDefault: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return SupabaseService.isConfigured
    }

    private static let provider = "discogs"
    private static let resourceType = "release"

    /// Whether the caller can ask Discogs itself if this returns nothing.
    ///
    /// When it can, the Edge Function has no business on the path of a page
    /// somebody is waiting for: it takes roughly a second where Discogs takes
    /// a third of one, because it is a round trip to another region wrapped
    /// around the same request Indigo could just make.
    ///
    /// Injectable because `DiscogsConfiguration.token` is deliberately nil
    /// under XCTest, which would otherwise make this branch untestable.
    let canReachProviderDirectly: Bool

    func release(id: Int) async -> DiscogsReleaseDetail? {
        guard isEnabled else { return nil }
        let resourceID = String(id)

        // Asking at all costs about a fifth of a second, and it is only won
        // back when the answer is there. The shared cache holds a few dozen
        // records against a catalogue of millions, so today it nearly always
        // is not — which made every cold release open pay for a question whose
        // answer was no.
        //
        // A build that can reach Discogs itself therefore does, and fills the
        // shared copy behind the page. Worth revisiting when the cache is
        // dense enough that the probe usually hits: this is the line to flip.
        if canReachProviderDirectly {
            populateInBackground(id: id)
            return nil
        }

        // No credential of our own. Postgres first — quicker than the Edge
        // Function that fronts it, and quicker than Discogs.
        let hit = try? await repository.cached(
            DiscogsReleaseDetail.self,
            provider: Self.provider,
            resourceType: Self.resourceType,
            resourceID: resourceID
        )

        if let hit, hit.isFresh { return hit.value }

        // Missing or stale, and no way to Discogs except through the backend,
        // so its extra hop is the price of getting anything at all.
        let refreshed = try? await repository.refresh(
            DiscogsReleaseDetail.self,
            provider: Self.provider,
            resourceType: Self.resourceType,
            resourceID: resourceID,
            lifetime: MetadataRepository.Lifetime.release
        )

        // Stale beats empty. If the refresh could not happen, what we already
        // had is still a description of the record.
        return refreshed ?? hit?.value
    }

    /// Many releases at once, out of the shared cache.
    ///
    /// The probe `release(id:)` skips on a build with a credential, made worth
    /// making. One PostgREST read for the whole batch an artist page wants,
    /// against one Discogs request per release — so even a cache that misses
    /// most of the time costs a single round trip to find that out, and a
    /// cache that hits saves eight.
    ///
    /// Returns only what it has and only while fresh. Everything absent is the
    /// caller's to fetch, and telling the backend about those is
    /// `requestCache(ids:)` below.
    func releases(ids: [Int]) async -> [Int: DiscogsReleaseDetail] {
        guard isEnabled, !ids.isEmpty else { return [:] }

        let found = try? await repository.cached(
            DiscogsReleaseDetail.self,
            provider: Self.provider,
            resourceType: Self.resourceType,
            resourceIDs: ids.map(String.init),
            fresherThan: MetadataRepository.Lifetime.release
        )

        var byID: [Int: DiscogsReleaseDetail] = [:]
        for (key, value) in found ?? [:] {
            guard let identifier = Int(key) else { continue }
            byID[identifier] = value
        }
        return byID
    }

    /// Tells the backend which releases a page wanted and could not get.
    ///
    /// The other half of the probe. A miss today is a hit for everybody
    /// tomorrow, but only if somebody writes down that it was wanted — and the
    /// app is the only thing that knows. One call for the whole batch, not
    /// waited on: the page has already gone to Discogs for these.
    ///
    /// `request_release_cache` is the narrowest thing the publishable key can
    /// reach. It takes Discogs release ids, refuses anything that is not
    /// digits, and the only work it can cause is a fetch of exactly those
    /// releases. See migration 0027.
    func requestCache(ids: [Int]) {
        guard isEnabled, !ids.isEmpty else { return }
        let repository = repository
        Task.detached(priority: .background) {
            await repository.requestReleaseCache(ids: ids)
        }
    }

    /// Asks the backend to fetch and normalize this release, without waiting.
    ///
    /// Costs one more upstream request than strictly necessary — the app has
    /// just made the same one — but it is the only path that writes the
    /// normalized tables, and it happens where nobody is watching.
    func populateInBackground(id: Int) {
        guard isEnabled else { return }
        let repository = repository
        Task.detached(priority: .background) {
            _ = try? await repository.refresh(
                DiscogsReleaseDetail.self,
                provider: Self.provider,
                resourceType: Self.resourceType,
                resourceID: String(id),
                lifetime: MetadataRepository.Lifetime.release
            )
        }
    }
}

/// An artist's shelf, out of Indigo's cache rather than Discogs'.
///
/// `artists/{id}/releases` is the slowest request a cold artist page makes and
/// the one it cannot draw without: measured at 2,727ms for Ryuichi Sakamoto and
/// 1,916ms for Haruomi Hosono, on a Discogs that was refusing nothing. Unlike
/// the release reads beside it, one shelf is one request, so there is no batch
/// to amortise the probe across — but there is also nothing else on the page
/// that is slower, so a probe that misses costs a fifth of a second against a
/// wait of two or three seconds.
///
/// The enrichment crawl already fetches this exact listing for the artists
/// radio says are worth having ready, and since migration 0027 it keeps it. A
/// miss asks the backend to keep this one too.
nonisolated struct CatalogShelfSource: Sendable {
    static let shared = CatalogShelfSource()

    private let repository: MetadataRepository
    private let isEnabled: Bool

    init(
        repository: MetadataRepository = .shared,
        isEnabled: Bool = CatalogReleaseSource.isEnabledByDefault
    ) {
        self.repository = repository
        self.isEnabled = isEnabled
        self.held = nil
        self.asked = nil
    }

    /// Which shelves a test says are already cached, and which ones it saw
    /// handed back.
    ///
    /// Injected rather than reached through a backend, for the reason
    /// `CatalogReleaseSource.canReachProviderDirectly` is injected: the
    /// publishable key is deliberately absent under XCTest, so the real path
    /// answers nil for both a hit and a miss and the difference — which is the
    /// whole behaviour — cannot be seen.
    nonisolated final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []
        func record(_ id: Int) { lock.withLock { seen.append(id) } }
        var ids: [Int] { lock.withLock { seen } }
    }

    private let held: [String: DiscogsArtistReleases]?
    private let asked: Asked?

    init(holding shelves: [String: DiscogsArtistReleases], asked: Asked? = nil) {
        self.repository = .shared
        self.isEnabled = true
        self.held = shelves
        self.asked = asked
    }

    func shelf(discogsID id: Int) async -> DiscogsArtistReleases? {
        guard isEnabled else { return nil }
        if let held { return held[DiscogsClient.shelfPath(id: id)] }

        let found = try? await repository.cached(
            DiscogsArtistReleases.self,
            provider: "discogs",
            path: DiscogsClient.shelfPath(id: id),
            query: DiscogsClient.shelfQuery
        )
        guard let found, found.fetchedAt > Date().addingTimeInterval(-Self.lifetime) else {
            return nil
        }
        return found.value
    }

    /// Matches `shelf_cache_lifetime()` in 0027 and `SHELF_CACHE_TTL_SECONDS`
    /// in `discogs.ts`. A record never changes; a discography gains one
    /// whenever the artist puts something out.
    static let lifetime: TimeInterval = 30 * 86_400

    /// Tells the backend which shelf a page had to fetch for itself.
    ///
    /// Not waited on: the page has already gone to Discogs for this. What it
    /// buys is the next listener, and this listener tomorrow.
    func requestCache(discogsID id: Int) {
        guard isEnabled else { return }
        if let asked {
            asked.record(id)
            return
        }
        let repository = repository
        Task.detached(priority: .background) {
            await repository.requestArtistShelf(discogsID: id)
        }
    }
}
