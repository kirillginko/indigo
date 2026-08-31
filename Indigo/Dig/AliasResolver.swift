//
//  AliasResolver.swift
//  Indigo
//
//  Who else is the same person.
//
//  Underground records are signed with a different name almost every time —
//  Prince of Denmark, Traumprinz and DJ Metatron are one artist, and finding
//  that out is half of what digging is. But the spec is firm that the names
//  must not be collapsed into one: they sound different on purpose, and an
//  app that folds them together deletes the distinction the artist built.
//
//  So the family is a route between nodes, never a merge of them. Aliases sit
//  on one branch and collaborative projects on another, because being another
//  name for someone and being in a band with them are not the same claim.
//

import Foundation
import SwiftData

nonisolated enum AliasRole: String, Hashable, Sendable {
    /// The name the family is filed under.
    case primary
    /// The same artist, recording as someone else.
    case alias
    /// A group or collaboration this artist is part of.
    case project
    /// Someone who makes up a group.
    case member

    var label: String {
        switch self {
        case .primary: "PRIMARY"
        case .alias: "ALIAS"
        case .project: "PROJECT"
        case .member: "MEMBER"
        }
    }

    /// How much an edge of this role is worth. An alias is an assertion of
    /// identity and a shared project is an assertion of proximity.
    var confidence: Double {
        switch self {
        case .primary: 1.0
        case .alias: 0.95
        case .project, .member: 0.85
        }
    }
}

nonisolated struct AliasFamily: Sendable {
    let primary: String
    let members: [Member]

    nonisolated struct Member: Identifiable, Hashable, Sendable {
        let name: String
        let role: AliasRole
        var id: String { RecordingKey.normalizeArtist(name) }
    }

    /// The alias branch alone — everyone who *is* the subject.
    var aliases: [Member] { members.filter { $0.role == .alias } }
    /// The project branch — everyone the subject works *with* or *as part of*.
    var projects: [Member] { members.filter { $0.role == .project || $0.role == .member } }

    var isEmpty: Bool { members.isEmpty }
}

nonisolated struct AliasResolver {
    let context: ModelContext
    /// The artist cache, when the caller already has it.
    ///
    /// Resolving a family reads every cached artist. A walk asks twice — once
    /// for the alias branch and once to keep the family out of the peer list —
    /// and each of those was fetching the whole table again. On a real
    /// catalogue that was most of the time it took to open an artist page.
    private let supplied: [DiscogsArtist]?

    init(context: ModelContext) {
        self.context = context
        supplied = nil
    }

    init(context: ModelContext, artists: [DiscogsArtist]) {
        self.context = context
        supplied = artists
    }

    /// The family a name belongs to, walked transitively.
    ///
    /// Discogs states aliases one artist at a time, so a page for Traumprinz
    /// may name DJ Metatron without ever mentioning Prince of Denmark. Closing
    /// over the alias links — and only the alias links — recovers the whole
    /// family from whichever corner of it the listener happened to arrive at.
    func family(of name: String) -> AliasFamily {
        let cache = cachedArtists()
        let subject = RecordingKey.normalizeArtist(name)
        guard !subject.isEmpty else { return AliasFamily(primary: name, members: []) }

        let inbound = Self.inboundAliases(cache)
        var aliasKeys: Set<String> = [subject]
        var display: [String: String] = [subject: cache[subject]?.name ?? name]
        var frontier = [subject]

        while let key = frontier.popLast() {
            guard let record = cache[key] else { continue }
            display[key] = record.name
            for alias in record.aliasNames where ArtistName.isRealArtist(alias) {
                let aliasKey = RecordingKey.normalizeArtist(alias)
                guard !aliasKey.isEmpty, display[aliasKey] == nil || !aliasKeys.contains(aliasKey) else { continue }
                display[aliasKey] = display[aliasKey] ?? alias
                if aliasKeys.insert(aliasKey).inserted { frontier.append(aliasKey) }
            }
            // Someone else's page may be the only one that names this artist
            // as an alias, and an alias link means the same thing read
            // backwards. Indexed once rather than scanned per step — walking
            // the whole cache for every name in the family is quadratic, and
            // the family is walked on every artist page.
            for other in inbound[key] ?? [] {
                display[other.nameKey] = display[other.nameKey] ?? other.name
                if aliasKeys.insert(other.nameKey).inserted { frontier.append(other.nameKey) }
            }
        }

        // Projects hang off the family rather than joining it: they are a
        // different musical entity, however many of its members overlap.
        var projects: [String: (name: String, role: AliasRole)] = [:]
        for key in aliasKeys {
            guard let record = cache[key] else { continue }
            for group in record.groupNames where ArtistName.isRealArtist(group) {
                let groupKey = RecordingKey.normalizeArtist(group)
                guard !groupKey.isEmpty, !aliasKeys.contains(groupKey) else { continue }
                projects[groupKey] = (group, .project)
            }
            for member in record.memberNames where ArtistName.isRealArtist(member) {
                let memberKey = RecordingKey.normalizeArtist(member)
                guard !memberKey.isEmpty, !aliasKeys.contains(memberKey), projects[memberKey] == nil
                else { continue }
                projects[memberKey] = (member, .member)
            }
        }

        var members = aliasKeys
            .filter { $0 != subject }
            .compactMap { key in display[key].map { AliasFamily.Member(name: $0, role: .alias) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        members += projects.values
            .map { AliasFamily.Member(name: $0.name, role: $0.role) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return AliasFamily(primary: display[subject] ?? name, members: members)
    }

    /// Every name in the family, the subject included — what a graph walk
    /// should treat as one artist's output even while showing them apart.
    func aliasKeys(of name: String) -> Set<String> {
        let family = family(of: name)
        var keys: Set<String> = [RecordingKey.normalizeArtist(name)]
        for member in family.aliases { keys.insert(member.id) }
        keys.remove("")
        return keys
    }

    /// Who names each artist as one of *their* aliases.
    private static func inboundAliases(_ cache: [String: DiscogsArtist]) -> [String: [DiscogsArtist]] {
        var inbound: [String: [DiscogsArtist]] = [:]
        for artist in cache.values {
            for alias in artist.aliasNames {
                let key = RecordingKey.normalizeArtist(alias)
                guard !key.isEmpty, key != artist.nameKey else { continue }
                inbound[key, default: []].append(artist)
            }
        }
        return inbound
    }

    private func cachedArtists() -> [String: DiscogsArtist] {
        let all = supplied ?? (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        return Dictionary(all.map { ($0.nameKey, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
