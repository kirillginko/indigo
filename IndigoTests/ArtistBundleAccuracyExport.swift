//
//  ArtistBundleAccuracyExport.swift
//  IndigoTests
//
//  What this device's own Discogs enrichment derived for a few artists, written
//  out so the backend's artist bundles (supabase/functions/_shared/
//  artist_bundle.ts) can be checked against it. Opt-in:
//  `TEST_RUNNER_INDIGO_EXPORT_ARTISTS=<discogs ids, comma separated>`. Reads a
//  copy of the real stores; writes `artist-local.json` to the host's
//  temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ArtistBundleAccuracyExport: XCTestCase {
    func testExportWhatThisDeviceDerived() throws {
        let wanted = (ProcessInfo.processInfo.environment["INDIGO_EXPORT_ARTISTS"] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        try XCTSkipIf(wanted.isEmpty, "Set INDIGO_EXPORT_ARTISTS to Discogs artist ids to export.")
        let context = ModelContext(try ExploreSharedDataComparison.copyOfRealStores())
        var out: [[String: Any]] = []
        for id in wanted {
            let found = try context.fetch(FetchDescriptor<DiscogsArtist>(predicate: #Predicate { $0.discogsID == id }))
            guard let artist = found.first else { continue }
            let releaseIDs = artist.releaseDiscogsIDs
            var credits: [[String: Any]] = []
            for releaseID in releaseIDs {
                let records = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.discogsID == releaseID }))
                guard let record = records.first else { continue }
                for (index, name) in record.creditNames.enumerated() {
                    credits.append([
                        "release": releaseID, "name": name,
                        "role": index < record.creditRoles.count ? record.creditRoles[index] : "",
                    ])
                }
            }
            out.append([
                "discogsID": id, "name": artist.name,
                "styles": artist.styles, "genres": artist.genres,
                "labels": artist.labelNames, "collaborators": artist.collaboratorNames,
                "releases": releaseIDs, "credits": credits,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("artist-local.json"))
        XCTAssertFalse(out.isEmpty)
    }
}
