//
//  MirroringMonitor.swift
//  Indigo
//
//  Says, in the trace file, what CloudKit mirroring of `UserData` is doing:
//  that it set up, that an export or an import began and finished, and whether
//  it succeeded -- and if not, which error. Nothing about what is in the rows:
//  not a title, not a count of anything the listener did. Event type, outcome,
//  error domain and code, and how long it took.
//
//  Core Data reports no row counts, so whether the first upload has *finished*
//  is read from CloudKit itself (`CloudKitCountRunner`), not guessed from these.
//

import CoreData
import Foundation

nonisolated enum MirroringMonitor {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var observer: NSObjectProtocol?

    /// What one finished event is written as. Pure, so it can be tested.
    static func describe(
        type: String, succeeded: Bool, seconds: Double, errorDomain: String?, errorCode: Int?
    ) -> String {
        let took = String(format: "%.1fs", seconds)
        if succeeded { return "sync: \(type) ok (\(took))" }
        return "sync: \(type) FAILED (\(took)) \(errorDomain ?? "unknown error") \(errorCode.map(String.init) ?? "-")"
    }

    /// Starts once; a second call does nothing.
    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event, let end = event.endDate else { return }
            let type: String
            switch event.type {
            case .setup: type = "setup"
            case .import: type = "import"
            case .export: type = "export"
            @unknown default: type = "event"
            }
            let error = event.error as NSError?
            Trace.note(describe(
                type: type, succeeded: event.succeeded, seconds: end.timeIntervalSince(event.startDate),
                errorDomain: error?.domain, errorCode: error?.code))
        }
        Trace.note("sync: UserData mirrors to the private CloudKit database")
    }
}
