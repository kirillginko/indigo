//
//  CounterRehearsalRunner.swift
//  Indigo
//
//  Development builds only. Opens a *copy* of the listener's UserData store
//  (made by `Scripts/counter-rehearsal.sh`) through the real launch path --
//  migration to V7, then the move of its counts into base components -- twice,
//  with no mirroring, and reports. The script checks the result against the
//  copy as it was, from outside the app. The listener's own stores are not
//  opened.
//

#if DEBUG

import Foundation
import SwiftData

@MainActor
enum CounterRehearsalRunner {
    static let argument = "-INDIGO_REHEARSE_COUNTERS"

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let directory = Persistence.layout.directory.appendingPathComponent("CounterRehearsal", isDirectory: true)
        let layout = StoreLayout(directory: directory)
        guard directory.lastPathComponent == "CounterRehearsal", layout.userData != Persistence.layout.userData,
              FileManager.default.fileExists(atPath: layout.userData.path) else {
            print("REFUSED: no copy at \(layout.userData.path); run Scripts/counter-rehearsal.sh"); exit(2)
        }
        print("predates components: \(CounterBaseline.needsBaseline(store: layout.userData))")
        for pass in 1...2 {
            do {
                let started = Date()
                let context = ModelContext(try Persistence.openSplitStores(layout: layout))
                let counters = try context.fetch(FetchDescriptor<DigCounter>())
                let violations = UserDataInvariants.violations(in: context)
                print("open \(pass): \(String(format: "%.2f", Date().timeIntervalSince(started)))s; components \(counters.count) "
                      + "(visit \(counters.filter { $0.kind == .visit }.count), step \(counters.filter { $0.kind == .step }.count), "
                      + "generation \(counters.filter { $0.kind == .generation }.count)); invariant violations \(violations.count)")
                for violation in violations.prefix(5) { print("  \(violation)") }
                print("pending marker after open \(pass): \(FileManager.default.fileExists(atPath: CounterBaseline.marker(in: layout).path))")
            } catch {
                print("open \(pass) FAILED: \(error)"); exit(1)
            }
        }
        exit(0)
    }
}

#endif
