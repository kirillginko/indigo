//
//  SupabaseService.swift
//  Indigo
//
//  Indigo's own backend: a shared metadata and artwork cache that sits between
//  the app and the slow public catalogues. The listener's library stays local
//  in SwiftData; only the shared music graph lives here.
//

import Foundation
import Supabase

nonisolated enum SupabaseError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Indigo's backend is not configured for this build."
        case .offline: "Indigo's backend is unavailable while offline."
        case .badStatus(let code): "Indigo's backend returned an unexpected response (\(code))."
        case .malformedResponse: "Indigo's backend sent something the app couldn't read."
        case .transport(let detail): detail
        }
    }
}

nonisolated enum SupabaseConfiguration {
    /// The bare project ref, e.g. `leynozulpkjuufbbjjpa`. The xcconfig must
    /// hold the ref rather than a full URL: `//` starts a comment there, so
    /// `https://<ref>.supabase.co` truncates to `https:` and still builds.
    static var projectRef: String? { value(forKey: "IndigoSupabaseProjectRef", environment: "SUPABASE_PROJECT_REF") }

    /// The publishable (anon) key. Public by design — it ships in every client
    /// and Row Level Security is what actually guards the data. A service-role
    /// key must never be read here.
    static var publishableKey: String? { value(forKey: "IndigoSupabasePublishableKey", environment: "SUPABASE_PUBLISHABLE_KEY") }

    static var url: URL? {
        guard let ref = projectRef else { return nil }
        return url(fromRef: ref)
    }

    /// Accepts either a bare ref or a whole `https://…` URL, since the
    /// environment override is a natural place to paste one.
    ///
    /// Anything else resolves to nil rather than to a plausible-looking URL.
    /// The failure this guards against is a ref of `https:` — an xcconfig
    /// truncated at its `//` — which would otherwise be spliced into
    /// `https://https:.supabase.co` and fail far from its cause.
    static func url(fromRef ref: String) -> URL? {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)

        if ref.contains("://") {
            guard let url = URL(string: ref), url.host != nil else { return nil }
            return url
        }

        let isRefShaped = !ref.isEmpty && ref.allSatisfy {
            $0.isNumber || ($0.isLetter && $0.isLowercase)
        }
        guard isRefShaped else { return nil }
        return URL(string: "https://\(ref).supabase.co")
    }

    static var isConfigured: Bool { url != nil && publishableKey != nil }

    private static func value(forKey key: String, environment name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty { return value }
        guard let bundled = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unsubstituted `$(VAR)` means the xcconfig never reached the build.
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}

nonisolated enum SupabaseService {
    /// Absent rather than fatal when unconfigured. Indigo already degrades to
    /// its upstream providers when an optional service is missing, and a
    /// force-unwrapped client would turn a bad build setting into a crash on
    /// launch instead of a cache miss.
    static let client: SupabaseClient? = {
        guard let url = SupabaseConfiguration.url,
              let key = SupabaseConfiguration.publishableKey
        else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var isConfigured: Bool { client != nil }

    static func requireClient() throws -> SupabaseClient {
        guard let client else { throw SupabaseError.notConfigured }
        return client
    }
}
