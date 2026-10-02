//
//  IndigoAppDelegate.swift
//  Indigo
//
//  Registers for remote notifications, which CloudKit needs to tell this
//  device that another one changed the listener's data.
//
//  Without it a running Indigo never heard of another device's changes: the
//  Mac logged "Giving up waiting to register for remote notifications", and
//  imports happened only at launch -- an iPhone's three visits sat in CloudKit
//  until the Mac was relaunched. The pushes are silent and carry nothing; no
//  permission to show notifications is asked for.
//

import Foundation

#if os(macOS)
import AppKit

final class IndigoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Trace.note("sync: could not register for pushes (\(error)); other devices' changes arrive at launch only")
    }
}
#else
import UIKit

final class IndigoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Trace.note("sync: could not register for pushes (\(error)); other devices' changes arrive at launch only")
    }
}
#endif
