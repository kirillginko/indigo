//
//  LotServerActions.swift
//  Indigo
//
//  Where The Lot's server action ids come from, and how Indigo gets a new one
//  when they change.
//
//  A Next.js action id is a content hash of the module that exports it, minted
//  at build time. It is the site's private wiring rather than an API, so it
//  changes whenever The Lot redeploys that module — and every call still using
//  the old one answers 404. That is not hypothetical: both ids Indigo shipped
//  with went stale at once, which took the Shows directory down and quietly
//  reduced the Index to a single unpageable page.
//
//  So the ids below are a starting guess, not the answer. The real one is read
//  out of the site's own client bundle, where Next writes it beside the
//  action's human name:
//
//      createServerReference("4052bb…",h.callServer,void 0,h.findSourceMapURL,"getShows")
//
//  The name is the anchor because the name is the part that means something.
//  Scanning for it costs a few megabytes of JavaScript, so it happens only
//  after a call has actually been refused, and what it finds is remembered
//  across launches.
//

import Foundation

actor LotServerActions {
    static let shared = LotServerActions()

    /// One action, and the page whose bundle defines it.
    nonisolated struct Action: Sendable, Hashable {
        let name: String
        let page: String
        /// The id Indigo shipped with. Correct until The Lot redeploys.
        let seed: String
    }

    static let shows = Action(
        name: "getShows",
        page: "shows",
        seed: "4052bb1bfa64a179284635d97f5f2035d6601ae0c8"
    )

    static let episodes = Action(
        name: "getEpisodes",
        page: "the-index",
        seed: "404c777e51da10a130ababf450109e62056d9dae07"
    )

    private static let base = URL(string: "https://www.thelotradio.com/")!
    private static let defaultsKey = "lot.serverActions"

    /// Chunks are fetched a few at a time and the scan stops at the first hit,
    /// but a page that has grown a hundred of them should not be walked whole.
    private static let maxChunks = 48
    private static let concurrentChunkFetches = 6

    private var resolved: [String: String] = [:]
    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
        resolved = Self.persisted()
    }

    /// The id to try. What was discovered this session, else what was
    /// discovered in a previous one, else what Indigo shipped with.
    func id(for action: Action) -> String {
        resolved[action.name] ?? action.seed
    }

    /// Reads the current id out of the site. Returns nil when the site does
    /// not name the action at all, which means something larger changed than
    /// a hash and the page-scraped fallback is the honest answer.
    ///
    /// `rejected` is the id that just failed. If another call has already
    /// refreshed past it, that newer one is returned without going near the
    /// network — a burst of failing requests costs one scan, not one each.
    func rediscover(_ action: Action, rejected: String) async -> String? {
        if let current = resolved[action.name], current != rejected { return current }

        guard let html = try? await text(at: action.page) else { return nil }

        // A redeploy is the only thing that moves an id, so the deployment the
        // page came from is the natural key. Matching it means a relaunch can
        // trust what an earlier session found without proving it again.
        let deployment = Self.deploymentID(inHTML: html)
        if let deployment, deployment == Self.persistedDeployment(),
           let stored = Self.persisted()[action.name], stored != rejected {
            resolved[action.name] = stored
            return stored
        }

        guard let found = await scan(html: html, for: action.name) else { return nil }
        resolved[action.name] = found
        Self.persist(resolved, deployment: deployment)
        return found
    }

    // MARK: - Scanning

    private func scan(html: String, for name: String) async -> String? {
        let paths = Self.chunkPaths(inHTML: html).prefix(Self.maxChunks)
        guard !paths.isEmpty else { return nil }

        for batch in Array(paths).chunked(into: Self.concurrentChunkFetches) {
            let found = await withTaskGroup(of: String?.self) { group in
                for path in batch {
                    group.addTask { [session] in
                        guard let url = URL(string: path, relativeTo: Self.base),
                              let (data, _) = try? await session.data(from: url),
                              let script = String(data: data, encoding: .utf8)
                        else { return nil }
                        return Self.actionID(named: name, inScript: script)
                    }
                }
                for await result in group where result != nil {
                    group.cancelAll()
                    return result
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }

    // MARK: - Reading the bundle
    //
    // Pure, so the shapes can be pinned against a real page without a network.

    /// The id Next.js registered under `name`.
    ///
    /// Anchored on the id and the name rather than on the helper that joins
    /// them: `createServerReference` is an import, and an import is exactly
    /// the kind of name a minifier is free to rewrite. What sits between the
    /// two is a short run of arguments with no string literal in it.
    nonisolated static func actionID(named name: String, inScript script: String) -> String? {
        let pattern = "\"([0-9a-f]{40,42})\"[^\"]{0,240}\"\(NSRegularExpression.escapedPattern(for: name))\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(script.startIndex..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              let idRange = Range(match.range(at: 1), in: script)
        else { return nil }
        return String(script[idRange])
    }

    /// Every client chunk the page pulls in, without the cache-busting query —
    /// the path alone serves the file.
    nonisolated static func chunkPaths(inHTML html: String) -> [String] {
        let pattern = "/_next/static/chunks/[A-Za-z0-9_./-]+\\.js"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)

        var seen = Set<String>()
        var paths: [String] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let found = Range(match.range, in: html) else { return }
            let path = String(html[found])
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    /// The build the page was served from, as Vercel stamps it on `<html>`.
    nonisolated static func deploymentID(inHTML html: String) -> String? {
        let pattern = "data-dpl-id=\"([A-Za-z0-9_-]{1,80})\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let found = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[found])
    }

    // MARK: - Plumbing

    private func text(at path: String) async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent(path, isDirectory: false))
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LotError.malformedResponse
        }
        return text
    }

    private static func persisted() -> [String: String] {
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: "deployment")
        return stored
    }

    private static func persistedDeployment() -> String? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?["deployment"]
    }

    private static func persist(_ ids: [String: String], deployment: String?) {
        var stored = ids
        stored["deployment"] = deployment
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }
}
