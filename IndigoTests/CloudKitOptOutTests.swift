//
//  CloudKitOptOutTests.swift
//  IndigoTests
//
//  With the iCloud entitlement on, SwiftData's default for a configuration is
//  to sync (`.automatic`). The cache models cannot be synced -- they have
//  unique constraints and required attributes -- and a test that built its own
//  container would start mirroring the test host's rows to the real container.
//
//  So every configuration says out loud whether it syncs, and exactly two
//  places in the app may say yes: `UserData`, in `Persistence`, and the
//  DEBUG-only seed runner. The positive case is pinned as well, so a refactor
//  cannot quietly turn `UserData`'s sync back off.
//

import XCTest
import SwiftData
@testable import Indigo

final class CloudKitOptOutTests: XCTestCase {
    private struct Call { let file: String; let arguments: String }

    private func configurationCalls(in folder: String) throws -> [Call] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent(folder)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var calls: [Call] = []
        for file in files where file.lastPathComponent != "CloudKitOptOutTests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = text[...]
            while let hit = rest.range(of: "ModelConfiguration(") {
                let tail = rest[hit.upperBound...]
                var depth = 1
                var end = tail.startIndex
                for index in tail.indices {
                    if tail[index] == "(" { depth += 1 }
                    if tail[index] == ")" { depth -= 1 }
                    if depth == 0 { end = index; break }
                }
                calls.append(Call(file: file.lastPathComponent, arguments: String(tail[tail.startIndex..<end])))
                rest = tail[end...]
            }
        }
        return calls
    }

    /// A call that only reads a store's default path takes no `cloudKitDatabase`.
    private func readsOnlyAURL(_ call: Call) -> Bool {
        ["schema: Persistence.schema", "schema: schema"].contains(call.arguments.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testEveryModelConfigurationSaysWhetherItSyncs() throws {
        var offenders: [String] = []
        for folder in ["Indigo", "IndigoTests"] {
            for call in try configurationCalls(in: folder) where !call.arguments.contains("cloudKitDatabase") && !readsOnlyAURL(call) {
                offenders.append("\(call.file): ModelConfiguration(\(call.arguments.prefix(60))")
            }
        }
        XCTAssertEqual(offenders, [], "These would sync when the app is signed for iCloud.")
    }

    /// Anything that is not a literal `.none` is a place that may sync.
    func testOnlyTheUserDataConfigurationAndTheSeedMaySync() throws {
        var syncing: [String] = []
        for call in try configurationCalls(in: "Indigo") where call.arguments.contains("cloudKitDatabase") {
            if !call.arguments.contains("cloudKitDatabase: .none") { syncing.append(call.file) }
        }
        XCTAssertEqual(syncing.sorted(), ["CloudKitSeedRunner.swift", "PersistenceController.swift"],
                       "UserData (through Persistence) and the DEBUG seed are the only configurations allowed to sync.")

        var inTests: [String] = []
        for call in try configurationCalls(in: "IndigoTests") where call.arguments.contains("cloudKitDatabase") {
            if !call.arguments.contains("cloudKitDatabase: .none") { inTests.append(call.file) }
        }
        XCTAssertEqual(inTests, [], "A test must never sync: it would write to the real container.")
    }

    // MARK: - What the split container is told

    private func sync(of configuration: ModelConfiguration) -> String { "\(configuration.cloudKitDatabase)" }

    func testUserDataMirrorsToThePrivateDatabaseWhenAskedAndLocalNever() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString)")
        let on = Persistence.splitConfigurations(userData: url, local: url, sync: .privateDatabase)
        XCTAssertEqual(on.map(\.name), ["UserData", "Local"])
        XCTAssertTrue(sync(of: on[0]).contains("iCloud.com.oblaststudio.Indigo"), sync(of: on[0]))
        XCTAssertTrue(sync(of: on[0]).lowercased().contains("private"), sync(of: on[0]))
        XCTAssertEqual(sync(of: on[1]), sync(of: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    func testNothingMirrorsUnlessAskedAndAStoreInMemoryNeverDoes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString)")
        let none = sync(of: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        for configuration in Persistence.splitConfigurations(userData: url, local: url, sync: .off) {
            XCTAssertEqual(sync(of: configuration), none)
        }
        for configuration in Persistence.splitConfigurations(userData: nil, local: nil, sync: .privateDatabase) {
            XCTAssertEqual(sync(of: configuration), none, "memory has nothing to mirror")
        }
    }

    func testTheLaunchMirrorsAndTheSwitchTurnsItOff() {
        XCTAssertEqual(UserDataSync.forLaunch(arguments: ["Indigo"]), .privateDatabase)
        XCTAssertEqual(UserDataSync.forLaunch(arguments: ["Indigo", UserDataSync.disableArgument]), .off)
    }

    /// The launch is the one caller that turns it on; the source says so.
    func testOnlyTheLaunchPathAsksForMirroring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Indigo/Persistence/PersistenceController.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("SplitLaunch.open(layout: layout, sync: sync)"))
        for folder in ["Indigo", "IndigoTests"] {
            let base = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files where !["PersistenceController.swift", "CloudKitOptOutTests.swift", "CloudKitSeedRunner.swift",
                                       "SyncRehearsalRunner.swift", "CloudKitCountRunner.swift", "TwoDeviceSyncRunner.swift"].contains(file.lastPathComponent) {
                let body = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(body.contains("sync: .privateDatabase") && !file.lastPathComponent.hasSuffix("OptOutTests.swift"),
                               "\(file.lastPathComponent) turns mirroring on")
            }
        }
    }
}
