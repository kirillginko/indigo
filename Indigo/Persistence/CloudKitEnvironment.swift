//
//  CloudKitEnvironment.swift
//  Indigo
//
//  Which CloudKit environment this build mirrors `UserData` to, and so which
//  store it may open.
//
//  The environment is set by how the build is signed, not by anything the app
//  chooses: a build run from Xcode talks to Development, a TestFlight or App
//  Store build to Production. One store must only ever mirror to one of them.
//  Core Data keeps per-store state about the zone it mirrors to; a store
//  pointed at the other environment is reconciled against a different zone, and
//  whatever that does, it is not something to find out on the listener's data.
//  So each environment has its own directory: Production the one the app has
//  always used, holding the listener's real store, and Development a folder
//  inside it, which a Debug build fills from the development zone.
//
//  Production is chosen only when it is certain: a Release build that, on
//  macOS, is signed for it. A Debug build, or a Release build signed for
//  development, opens the development store. iOS cannot read its own
//  entitlements, so there a Release build is taken to be distribution-signed.
//

import Foundation
import Security

nonisolated enum CloudKitEnvironment: String, Sendable {
    case production = "Production"
    case development = "Development"

    static let current: CloudKitEnvironment = {
        #if DEBUG
        return .development
        #elseif os(macOS)
        return signedEntitlements().environment == production.rawValue ? .production : .development
        #else
        return .production
        #endif
    }()

    /// The CloudKit containers and environment this process is signed for, as
    /// its code signature says. Nil environment: the entitlement is absent,
    /// which for a development-signed build means Development.
    static func signedEntitlements() -> (containers: [String], environment: String?) {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return ([], nil) }
        func value(_ key: String) -> Any? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        let containers = (value("com.apple.developer.icloud-container-identifiers") as? [String]) ?? []
        let raw = value("com.apple.developer.icloud-container-environment")
        let environment = (raw as? String) ?? (raw as? [String])?.joined(separator: ",")
        return (containers, environment)
        #else
        // A process cannot read its own entitlements on iOS.
        return ([], nil)
        #endif
    }
}
