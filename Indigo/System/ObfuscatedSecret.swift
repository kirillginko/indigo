//
//  ObfuscatedSecret.swift
//  Indigo
//
//  Keeps a shipped credential from being readable at a glance.
//
//  This is obfuscation, not encryption, and the distinction matters. A
//  credential inside an application belongs to whoever holds the application:
//  the key to unscramble it has to ship alongside it, and the token goes out
//  over the wire in an Authorization header where a proxy shows it in plain
//  sight. Anyone who wants it can have it.
//
//  What it does buy is that the token no longer appears in `strings`, in a
//  `plutil` dump, or in a crash log or screen-share — which is how a
//  credential usually escapes. Treat the token as one that will eventually
//  leak: keep it rotatable, and watch its usage.
//

import Foundation

nonisolated enum ObfuscatedSecret {
    /// Mixed into the key so the scrambled bytes are not a plain XOR against
    /// something guessable like the bundle identifier alone.
    private static let salt: [UInt8] = [
        0x49, 0x6e, 0x64, 0x69, 0x67, 0x6f, 0x2d, 0x44,
        0x49, 0x47, 0x2d, 0x32, 0x30, 0x32, 0x36, 0x5f,
    ]

    private static func keystream(length: Int) -> [UInt8] {
        let identifier = Array((Bundle.main.bundleIdentifier ?? "com.oblaststudio.Indigo").utf8)
        return (0..<length).map { index in
            salt[index % salt.count] &+ identifier[index % identifier.count] &* 3
        }
    }

    /// The blob uses the URL-safe base64 alphabet, so it can never contain a
    /// "/". Standard base64 produces "//" by chance often enough, and "//"
    /// opens a comment in xcconfig — which truncates the value mid-blob and
    /// ships half a credential that fails every request. The same trap that
    /// swallowed the Supabase URL.
    private static func decode(_ encoded: String) -> Data? {
        var value = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        return Data(base64Encoded: value)
    }

    /// Reverses `Scripts/obfuscate-token.py`. Returns nil for anything that is
    /// not a well-formed blob, so a missing or half-configured value reads as
    /// "no token" rather than as a token that will fail every request.
    static func reveal(_ encoded: String) -> String? {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("),
              let data = decode(trimmed), !data.isEmpty
        else { return nil }

        let key = keystream(length: data.count)
        let plain = zip(data, key).map { $0 ^ $1 }
        guard let value = String(bytes: plain, encoding: .utf8),
              !value.isEmpty,
              value.allSatisfy({ !$0.isNewline })
        else { return nil }
        return value
    }

    /// The same transform forwards, so a test can prove the two directions
    /// agree without the real token being involved.
    static func conceal(_ value: String) -> String {
        let plain = Array(value.utf8)
        let key = keystream(length: plain.count)
        return Data(zip(plain, key).map { $0 ^ $1 })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
