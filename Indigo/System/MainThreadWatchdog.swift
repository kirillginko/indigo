//
//  MainThreadWatchdog.swift
//  Indigo
//
//  How long the main thread was busy, and when.
//
//  A stutter is the main thread failing to come back within a frame. Reading
//  code cannot find that, and `sample` cannot answer it either: it
//  reconstructs *async* call stacks, so work that ran on a cooperative thread
//  is printed beneath whichever thread was awaiting it. Twice that made
//  background work look like it was blocking the UI when it was not.
//
//  So this asks the question directly. A timer off the main thread posts a
//  token to it and times how long it takes to come back. If the main thread
//  is drawing, that is milliseconds. If something is holding it, the delay is
//  the length of the stall — and the line lands in the same trace file as the
//  stages, so a stall can be read against whatever was happening.
//

import Foundation

nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    /// Anything longer than this is a dropped frame somebody can feel.
    private let threshold: Duration = .milliseconds(100)
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil, Trace.fileSink != nil else { return }
        task = Task.detached(priority: .utility) { [threshold] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let asked = ContinuousClock.now
                await MainActor.run { _ = asked }
                let waited = ContinuousClock.now - asked
                if waited > threshold {
                    Trace.note("main.stall \(Self.milliseconds(waited))ms")
                }
                // Written as it goes, from here rather than from inside a
                // measurement — a file opened inside a timer adds its own
                // cost to whatever encloses it.
                Trace.flush()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
