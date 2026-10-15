//
//  R2LatencyProbe.swift
//  IndigoTests
//
//  How the catalogue host answers from inside the app process: 40 reads of
//  the pilot pointer through the shared session the pilot uses, and 10
//  through a fresh ephemeral session each (a new connection every time), with
//  every failure's URLError code. Opt-in: `TEST_RUNNER_INDIGO_PROBE_R2=1`.
//  Writes `r2-latency.json` to the host's temporary directory.
//

import XCTest
@testable import Indigo

final class R2LatencyProbe: XCTestCase {
    struct Read: Codable { var session: String; var ms: Int; var outcome: String }

    func testHowTheHostAnswers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_PROBE_R2"] == "1", "Set TEST_RUNNER_INDIGO_PROBE_R2=1.")
        let host = try XCTUnwrap(SupabaseConfiguration.catalogCacheHost)
        let url = try XCTUnwrap(URL(string: "https://\(host)/\(CataloguePilot.pointerKey)"))
        var reads: [Read] = []
        func read(_ session: URLSession, _ name: String) async {
            let started = Date()
            do {
                let (_, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
                reads.append(Read(session: name, ms: Int(Date().timeIntervalSince(started) * 1000),
                                  outcome: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            } catch {
                reads.append(Read(session: name, ms: Int(Date().timeIntervalSince(started) * 1000),
                                  outcome: (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(error)"))
            }
        }
        for _ in 0..<40 { await read(.shared, "shared") }
        for _ in 0..<10 {
            let fresh = URLSession(configuration: .ephemeral)
            await read(fresh, "fresh connection")
            fresh.invalidateAndCancel()
        }
        let data = try JSONEncoder().encode(reads)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("r2-latency.json"))
        print("R2_PROBE " + reads.map { "\($0.session):\($0.ms):\($0.outcome)" }.joined(separator: " "))
    }
}
