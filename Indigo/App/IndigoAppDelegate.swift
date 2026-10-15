//
//  IndigoAppDelegate.swift
//  Indigo
//
//  Registers for remote notifications, which CloudKit needs to tell this
//  device that another one changed the listener's data; on iOS, also asks for
//  an audio session that plays music.
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

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Trace.note("sync: registered for pushes")
        Trace.flush()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Trace.note("sync: push received")
        Trace.flush()
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Trace.note("sync: could not register for pushes (\(error)); other devices' changes arrive at launch only")
        Trace.flush()
    }
}
#else
import AVFoundation
import UIKit

final class IndigoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        Self.configureAudioSession()
        return true
    }

    /// iOS gives an app that says nothing the default audio session, which the
    /// ring/silent switch mutes and which stops when the app leaves the
    /// screen: radio stations, played by the app's own stream player, were
    /// silent on an iPhone on silent, while crate items and archives -- web
    /// players with sessions of their own -- played. Indigo plays music, so it
    /// asks for playback, as long-form audio; with the `audio` background mode
    /// in Info.plist it keeps playing with the phone locked.
    static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            Trace.note("audio: could not set the playback session (\(error))")
        }
    }

    /// The iPhone stays upright, except while a video is full screen; the
    /// iPad turns freely. See `OrientationLock`.
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? OrientationLock.mask : .all
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Trace.note("sync: registered for pushes")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Trace.note("sync: could not register for pushes (\(error)); other devices' changes arrive at launch only")
    }
}

/// Which ways the iPhone may turn. Upright, so the phone layout is never
/// laid out sideways (turned, it took two turns to come back, and the larger
/// phones swapped to the Mac's layout). A video full screen opens upright
/// and may be turned on its side by turning the phone; closed, the phone
/// stands back up.
@MainActor
enum OrientationLock {
    static private(set) var mask: UIInterfaceOrientationMask = .portrait

    static func allowsLandscape(_ landscape: Bool) {
        mask = landscape ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // Only ever asked to stand up: a video is turned by the hand holding
        // the phone, not by the app.
        if !landscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}
#endif
