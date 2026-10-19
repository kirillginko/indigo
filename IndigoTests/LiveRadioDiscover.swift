import XCTest
import SwiftData
@testable import Indigo

/// A short, opt-in listening run on a private copy of this Mac's real history.
/// Recommendations and report stay in Caches/tmp, never repository files.
@MainActor
final class LiveRadioDiscover: XCTestCase {
    private func historyInputs() async throws -> RadioDiscover.Inputs {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_RADIO_DISCOVER"] == "1")
        // The caller supplies a checkpointed SQLite backup, never a live WAL
        // store. Keeping this explicit also avoids touching the app's stores.
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["INDIGO_RADIO_HISTORY_ROOT"], "Provide a private checkpointed history snapshot.")
        let support = URL(fileURLWithPath: root)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("RadioDiscover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["UserData.store", "Local.store"] {
            try FileManager.default.copyItem(at: support.appendingPathComponent(name), to: copy.appendingPathComponent(name))
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
        let read = await Task.detached { RadioDiscover.inputs(context: ModelContext(container)) }.value
        return try XCTUnwrap(read)
    }

    func testLocalHistoryInputs() async throws {
        let inputs = try await historyInputs()
        XCTAssertFalse(inputs.seeds.isEmpty)
        XCTAssertGreaterThanOrEqual(Set(inputs.seeds.map(\.cluster)).count, 2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("radio-discover-profile.txt")
        let report = "Local profile: \(inputs.seeds.count) seeds across \(inputs.labels.count) clusters.\n" + inputs.seeds.map { "\($0.cluster): \($0.name)" }.joined(separator: "\n")
        try report.write(to: path, atomically: true, encoding: .utf8)
        print("RADIO_DISCOVER_PROFILE=\(path.path)")
    }

    func testRealHistory() async throws {
        let inputs = try await historyInputs()
        let result = try await RadioDiscover(source: .live).discover(inputs)
        await RadioDiscoverCache.shared.save(result)
        var report = ["# Radio Discover — private listening results", "", "\(result.picks.count) tracks; \(result.requests) catalogue reads; \(result.checked) playback checks; \(inputs.seeds.count) seeds across \(inputs.labels.count) clusters."]
        for pick in result.picks {
            report += ["", "## \(pick.track.artist) — \(pick.track.title)", "Programme: \(pick.programme); episode: \(pick.episode)",
                       "Cluster: \(pick.clusterLabel)", pick.track.reason, pick.timing.label]
            switch pick.track.source {
            case .recording(let url, _): report.append("Listen: \(url.absoluteString)")
            case .episode(let listen, let at): report.append("Listen: \(listen.archiveURL.absoluteString) at \(at / 60):\(String(format: "%02d", at % 60))")
            }
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("radio-discover-personal.md")
        try report.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        print("RADIO_DISCOVER_REPORT=\(path.path)")
        let attachment = XCTAttachment(string: report.joined(separator: "\n")); attachment.name = "radio-discover-personal"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThanOrEqual(result.picks.count, 5)
    }
}
