//
//  DigEnrichmentSwitch.swift
//  Indigo
//
//  Whether this device may show shared DIG enrichment (the catalogue pilot),
//  decided remotely (`dig_enrichment_config`, 0084) and checked every time a
//  bundle would be read -- from the network, from disk or from memory.
//
//  Off unless all of these hold:
//  - a config has been read (never read: off);
//  - it was read within its offline grace (24 h) -- a device that cannot ask
//    keeps the last answer that long and no longer;
//  - it says enabled;
//  - it lists this device's cohort: `debug` for development builds,
//    `testflight` for TestFlight, `appstore` otherwise.
//
//  It is asked again when its TTL (15 min) has passed, in the background and
//  never in front of a page. When the answer changes, DIG is told, so a page
//  showing enrichment drops it at its next walk. Turning it off deletes
//  nothing: the bundles kept on disk are simply not read.
//

import Foundation
import Supabase

extension Notification.Name {
    static let digEnrichmentSwitchChanged = Notification.Name("indigo.digEnrichmentSwitchChanged")
}

nonisolated final class DigEnrichmentSwitch: @unchecked Sendable {
    static let shared = DigEnrichmentSwitch()

    struct Config: Codable, Equatable, Sendable {
        let version: Int
        let enabled: Bool
        let cohorts: [String]
        let manifest: String
        let ttlSeconds: Int
        let offlineGraceSeconds: Int
    }

    struct Stored: Codable, Equatable, Sendable {
        let config: Config
        let fetchedAt: Date
    }

    enum Cohort: String, Sendable {
        case debug, testflight, appstore

        static var thisBuild: Cohort {
            #if DEBUG
            .debug
            #else
            Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testflight : .appstore
            #endif
        }
    }

    enum Decision: Equatable, Sendable {
        case on(manifest: String)
        case off(String)
    }

    static let storedKey = "digEnrichment.switch.v1"

    // Replaced in tests.
    var cohort: Cohort = .thisBuild
    var defaults: UserDefaults = .standard
    var now: @Sendable () -> Date = { Date() }
    var fetch: @Sendable () async throws -> Config = DigEnrichmentSwitch.live

    private let lock = NSLock()
    private var loaded = false
    private var stored: Stored?
    private var refreshing = false

    private func current() -> Stored? {
        lock.withLock {
            if !loaded {
                loaded = true
                stored = defaults.data(forKey: Self.storedKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            }
            return stored
        }
    }

    func decision() -> Decision {
        guard let stored = current() else { return .off("never read") }
        let age = now().timeIntervalSince(stored.fetchedAt)
        guard age < TimeInterval(stored.config.offlineGraceSeconds) else { return .off("expired") }
        guard stored.config.enabled else { return .off("disabled") }
        guard stored.config.cohorts.contains(cohort.rawValue) else { return .off("cohort \(cohort.rawValue) not listed") }
        return .on(manifest: stored.config.manifest)
    }

    var isOn: Bool { if case .on = decision() { true } else { false } }

    /// The one manifest devices may read, while the switch is on.
    var pinnedManifest: String? { if case .on(let manifest) = decision() { manifest } else { nil } }

    private var isDue: Bool {
        guard let stored = current() else { return true }
        return now().timeIntervalSince(stored.fetchedAt) >= TimeInterval(stored.config.ttlSeconds)
    }

    /// Reads the config again when it is due. A failure keeps the last answer,
    /// which then holds until its grace runs out.
    func refreshIfDue() async {
        guard isDue, lock.withLock({ refreshing ? false : { refreshing = true; return true }() }) else { return }
        defer { lock.withLock { refreshing = false } }
        let before = decision()
        guard let config = try? await fetch() else {
            Trace.note("dig.enrichment.switch refresh failed; \(before)")
            return
        }
        let fresh = Stored(config: config, fetchedAt: now())
        lock.withLock { stored = fresh; loaded = true }
        if let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Self.storedKey) }
        let after = decision()
        Trace.note("dig.enrichment.switch \(after)")
        if after != before {
            NotificationCenter.default.post(name: .digEnrichmentSwitchChanged, object: nil)
        }
    }

    /// The same, started in the background, for callers that must not wait.
    func refreshInBackgroundIfDue() {
        guard isDue else { return }
        Task.detached(priority: .utility) { await self.refreshIfDue() }
    }

    /// Forgets the kept answer (tests), so the next decision is "never read".
    func reset() {
        lock.withLock { stored = nil; loaded = true; refreshing = false }
        defaults.removeObject(forKey: Self.storedKey)
    }

    @Sendable static func live() async throws -> Config {
        let client = try SupabaseService.requireClient()
        return try await client.rpc("dig_enrichment_config").execute().value
    }
}
