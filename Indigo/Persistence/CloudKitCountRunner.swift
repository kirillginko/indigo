//
//  CloudKitCountRunner.swift
//  Indigo
//
//  Development builds only. Read-only: says how many records of each type the
//  development zone holds, how many of those carry a distinct row id, and a
//  digest of the ids -- so the first upload of the real `UserData` can be
//  compared with the store it came from without printing anything the listener
//  made. It opens no store of the app's, and writes nothing.
//

#if DEBUG

import CloudKit
import CryptoKit
import Foundation

nonisolated enum RowIDs {
    /// The digest both sides compute: the ids, upper case, sorted, one per line.
    static func digest(_ ids: [String]) -> String {
        let joined = ids.map { $0.uppercased() }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum CloudKitCountRunner {
    static let argument = "-INDIGO_COUNT_CLOUDKIT_DEV"
    /// Also deletes the two-device harness's own rows -- every record whose key
    /// carries its marker, in any field that names a thing -- and nothing else.
    static let cleanArgument = "-INDIGO_CLEAN_TEST_ROWS_DEV"

    static func isTestRow(_ record: CKRecord) -> Bool {
        ["CD_nodeKey", "CD_nodeID", "CD_identity", "CD_key", "CD_providerID", "CD_showID"]
            .compactMap { record[$0] as? String }
            .contains(where: TwoDeviceSyncRunner.isMarker)
    }

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in exit(await run()) }
        dispatchMain()
    }

    private static func run() async -> Int32 {
        let entitlements = CloudKitSeedRunner.signedEntitlements()
        if let environment = entitlements.environment, environment != "Development" {
            print("REFUSED: the signed environment is \(environment)"); return 2
        }
        guard entitlements.containers.contains(CloudKitSeedRunner.containerID) else { print("REFUSED: not signed for the container"); return 2 }
        do {
            let database = CKContainer(identifier: CloudKitSeedRunner.containerID).privateCloudDatabase
            var records = try await CloudKitSeedRunner.fetchAll(database)
            print("environment: Development; records in the zone: \(records.count)")
            let test = records.filter(isTestRow)
            print("harness test rows: \(Dictionary(grouping: test, by: \.recordType).mapValues(\.count).sorted { $0.key < $1.key })")
            if ProcessInfo.processInfo.arguments.contains(cleanArgument), !test.isEmpty {
                let result = try await database.modifyRecords(saving: [], deleting: test.map(\.recordID))
                let deleted = result.deleteResults.values.filter { (try? $0.get()) != nil }.count
                print("deleted \(deleted) of \(test.count) test rows")
                records = try await CloudKitSeedRunner.fetchAll(database)
                print("test rows left: \(records.filter(isTestRow).count); records in the zone: \(records.count)")
            }
            // The fields each type has in CloudKit, against the manifest.
            for (type, group) in Dictionary(grouping: records, by: \.recordType).sorted(by: { $0.key < $1.key }) {
                let entity = String(type.dropFirst(3))
                guard let expected = CloudKitSchemaManifest.expected[entity] else { print("\(type): not in the manifest"); continue }
                var seen: [String: Set<String>] = [:]
                for record in group { for key in record.allKeys() { if let value = record[key] { seen[key, default: []].insert(CloudKitSchemaManifest.classify(value)) } } }
                let wrong = expected.filter { attribute, kind in seen[CloudKitSchemaManifest.fieldName(attribute)].map { $0 != [kind] } ?? false }
                let missing = expected.keys.filter { seen[CloudKitSchemaManifest.fieldName($0)] == nil }
                let extra = Set(seen.keys).subtracting(expected.keys.map(CloudKitSchemaManifest.fieldName)).subtracting(["CD_entityName"])
                print("\(type) fields: \(expected.count - wrong.count - missing.count) of \(expected.count) as the manifest says; wrong \(wrong.keys.sorted()); absent \(missing.sorted()); extra \(extra.sorted())")
            }
            for (type, group) in Dictionary(grouping: records, by: \.recordType).sorted(by: { $0.key < $1.key }) {
                let ids = group.compactMap { $0["CD_id"] as? String }
                print("\(type): records \(group.count), distinct ids \(Set(ids).count), digest \(RowIDs.digest(Array(Set(ids))))")
                // Any id that appears twice: which records, when they were written, and
                // whether they are this test's. No content.
                for (id, copies) in Dictionary(grouping: group, by: { ($0["CD_id"] as? String) ?? "?" }) where copies.count > 1 {
                    for copy in copies {
                        let key = ((copy["CD_nodeKey"] as? String) ?? (copy["CD_nodeID"] as? String) ?? (copy["CD_identity"] as? String) ?? (copy["CD_showID"] as? String) ?? "").lowercased()
                        print("  repeated \(id): record \(copy.recordID.recordName.prefix(8)), modified \(copy.modificationDate.map { "\($0)" } ?? "?"), marker \(key.contains("indigo-sync-test")), seconds \((copy["CD_seconds"] as? Double).map { "\($0)" } ?? "-")")
                    }
                }
            }
            return 0
        } catch let error as CKError where error.code == .zoneNotFound {
            print("the zone does not exist"); return 0
        } catch {
            print("could not read: \(error)"); return 1
        }
    }
}

#endif
