//
//  UserDataObserving.swift
//  Indigo
//
//  Runs `HistoryObserver` for as long as the app runs.
//
//  It used to run from the main window's `.task`, so it stopped when that
//  window closed -- the mini player can play on without it -- and never started
//  in a launch that did not present the window. Imports arriving then were not
//  merged or projected until something else happened to look. It starts here,
//  once, with the app; and it looks when the store reports a change from
//  elsewhere and when CloudKit reports that an import finished, since one
//  without the other has been seen to be missed.
//

import CoreData
import Foundation
import SwiftData

@MainActor
enum UserDataObserving {
    private static var task: Task<Void, Never>?

    static func start(author: String) {
        guard task == nil, !Persistence.isRunningTests, Persistence.userDataWritable else { return }
        let context = Persistence.container.mainContext
        context.author = author
        let observer = {
            var observer = HistoryObserver(context: context, ownAuthor: author)
            observer.onNewerGeneration = { Persistence.refuse(newerGeneration: $0) }
            return observer
        }()
        observer.process()
        task = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                        guard Persistence.userDataWritable else { continue }
                        observer.process()
                    }
                }
                group.addTask { @MainActor in
                    for await note in NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification) {
                        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                            as? NSPersistentCloudKitContainer.Event, event.type == .import, event.endDate != nil,
                              Persistence.userDataWritable else { continue }
                        observer.process()
                    }
                }
            }
        }
    }
}
