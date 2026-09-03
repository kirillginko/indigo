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
