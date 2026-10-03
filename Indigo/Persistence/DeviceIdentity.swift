//
//  DeviceIdentity.swift
//  Indigo
//
//  Which writer this installation is, for the counter components it owns
//  (`DigCounter.deviceID`).
//
//  What matters is that two physical devices never share one, or they would
//  write the same component and lose each other's counts again. A UUID in
//  UserDefaults is copied by a restore or by Migration Assistant to a second
//  machine; a Keychain item marked ThisDeviceOnly and not synchronizable is not
//  restored onto another device and never travels through iCloud Keychain. No
//  hardware identifier is used: the id is random and means nothing outside
//  Indigo's own counters.
//
//  If the item is lost, a new id is made. That is safe: the old component keeps
//  its count, and this installation starts a new one at zero. If the Keychain
//  cannot be used at all, the id lives for the session only -- also safe, only
//  more components -- and that is traced.
//

import Foundation
import Security

nonisolated enum DeviceIdentity {
    static let service = "com.oblaststudio.Indigo.counter-writer"
    static let account = "device"

    /// This installation's writer id, made on first use.
    static let current: String = load() ?? create() ?? sessionOnly()

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil
        else { return nil }
        return id
    }

    private static func create() -> String? {
        let id = UUID().uuidString
        var item = baseQuery()
        item[kSecValueData as String] = Data(id.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return id }
        // Another launch made it first.
        if status == errSecDuplicateItem { return load() }
        Trace.note("counters: the device id could not be kept in the Keychain (\(status))")
        return nil
    }

    private static func sessionOnly() -> String {
        Trace.note("counters: using a device id for this session only")
        return UUID().uuidString
    }
}
