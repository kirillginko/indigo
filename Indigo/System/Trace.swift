//
//  Trace.swift
//  Indigo
//
//  Where the time goes.
//
//  Cold pages have been slow, and every theory about why — too many
//  catalogue searches, a background job spending the request budget, a view
//  tree built too eagerly — was arrived at by reading the code and counting.
//  Some of it was wrong, and one of the fixes made the page slower. This
//  measures instead.
//
//  Every stage is both an Instruments interval and a line in Console, so a
//  cold load can be read either way:
//
//    * Instruments → "os_signpost", subsystem `dig`, for the shape of it.
//    * `log stream --predicate 'subsystem CONTAINS "Indigo"' --level info`
//      for a plain list of stages and milliseconds.
//

import Foundation
import OSLog

nonisolated enum Trace {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Indigo"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "dig")
    private static let log = Logger(subsystem: subsystem, category: "dig")

    /// Times one stage of a page load.
    ///
    /// `detail` is for the part that varies — which artist, which endpoint —
    /// so a slow load can be told apart from a slow request to one address.
    static func stage<T>(
        _ name: StaticString,
        _ detail: String = "",
        _ body: () async throws -> T
    ) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let started = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = ContinuousClock.now - started
            let where_ = Thread.isMainThread ? "MAIN" : "bg"
            let line = "\(name) [\(where_)] \(detail) \(Self.milliseconds(elapsed))ms"
            log.info("\(line, privacy: .public)")
            Self.write(line)
        }
        return try await body()
    }

    /// The same, for work that is not async.
    ///
    /// Rebuilding the engines is a synchronous read of six whole tables
    /// inside the worker, and it needed separating from the walk that
    /// follows it: the two were being counted as one number, which said
    /// where the time went without saying what it was spent on.
    @discardableResult
    static func step<T>(
        _ name: StaticString,
        _ detail: String = "",
        _ body: () throws -> T
    ) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let started = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = ContinuousClock.now - started
            let where_ = Thread.isMainThread ? "MAIN" : "bg"
            let line = "\(name) [\(where_)] \(detail) \(Self.milliseconds(elapsed))ms"
            log.info("\(line, privacy: .public)")
            Self.write(line)
        }
        return try body()
    }

    /// The same, for something called on every render.
    ///
    /// A step in a `body` writes a line per redraw, and a trace flooded with
    /// "0ms" is a trace nobody can read — worse, the file flushes every forty
    /// lines, so measuring the render adds to it. This one keeps quiet until
    /// it has something to report.
    @discardableResult
    static func slowStep<T>(
        _ name: StaticString,
        _ detail: String = "",
        over threshold: Duration = .milliseconds(50),
        _ body: () throws -> T
    ) rethrows -> T {
        let started = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - started
            if elapsed > threshold {
                let where_ = Thread.isMainThread ? "MAIN" : "bg"
                let line = "\(name) [\(where_)] \(detail) \(Self.milliseconds(elapsed))ms"
                log.info("\(line, privacy: .public)")
                Self.write(line)
            }
        }
        return try body()
    }

    /// Under test, the same lines go to a file.
    ///
    /// A test host's `Logger` output reaches neither xcodebuild nor the
    /// system log, so a measurement taken in a benchmark was unreadable —
    /// which is how a change with no effect got shipped twice as an
    /// improvement. Written where it can be read, a benchmark can be run
    /// before and after and believed.
    static let fileSink: String? = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return (NSTemporaryDirectory() as NSString).appendingPathComponent("indigo-bench.txt")
        }
        #if DEBUG
        // The running app writes too, so a session can be read afterwards
        // rather than watched live. A test host's log reaches neither
        // xcodebuild nor the system log, and neither does a sandboxed app's
        // at `info` level — which is why measurements kept being unreadable.
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("indigo-trace.txt")
        #else
        return nil
        #endif
    }()

    /// Buffered, not written as it goes.
    ///
    /// Opening and closing a file inside a timer that is still running adds
    /// its own cost to whatever encloses it — which made a nested measurement
    /// blame its parent for time the measuring spent. Lines are kept in
    /// memory and written once, by `flush()`.
    private static let buffer = Buffer()

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func drain() -> [String] { lock.withLock { defer { lines = [] }; return lines } }
        var count: Int { lock.withLock { lines.count } }
    }

    private static func write(_ line: String) {
        guard fileSink != nil else { return }
        buffer.append(line)
        // A running app is never "done", so it flushes as it fills rather
        // than at the end of a benchmark.
        if buffer.count >= 40 { flush() }
    }

    /// Records a line that is not an interval — a stall, a marker.
    static func note(_ line: String) {
        log.info("\(line, privacy: .public)")
        write(line)
    }

    /// Writes everything measured so far. Call at the end of a benchmark.
    static func flush() {
        guard let fileSink else { return }
        let lines = buffer.drain()
        guard !lines.isEmpty else { return }
        let body = lines.joined(separator: "\n") + "\n"
        if let handle = FileHandle(forWritingAtPath: fileSink) {
            handle.seekToEndOfFile()
            handle.write(Data(body.utf8))
            try? handle.close()
        } else {
            try? body.write(toFile: fileSink, atomically: true, encoding: .utf8)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
