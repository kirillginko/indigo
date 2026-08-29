//
//  AlharaAPI.swift
//  Indigo
//
//  Transport for Radio alHara. Two hosts, because the station is split across
//  two:
//
//  · ch2.radioalhara.net — three now-playing endpoints, one per channel. This
//    is the station's whole public surface for what is on the air.
//  · api.mixcloud.com — where alHara's recorded shows actually live. The
//    station hosts no archive of its own, and Mixcloud's API is open,
//    documented and needs no key.
//

import Foundation

nonisolated enum AlharaError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "Radio alHara returned an unexpected response (\(code))."
        case .malformedResponse:
            "Radio alHara sent something Indigo couldn't read."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct AlharaArchivePage: Sendable {
    var shows: [AlharaShow]
    /// Mixcloud pages by opaque cursor URL rather than by number.
    var next: URL?
}

nonisolated struct AlharaSnapshot: Sendable {
    /// Keyed by station id.
    var channels: [String: AlharaChannelState]
    var hidden: Set<String>
}

nonisolated struct AlharaAPI: Sendable {
    private static let base = URL(string: "https://ch2.radioalhara.net/")!
    private static let archive = URL(
        string: "https://api.mixcloud.com/radioalhara/cloudcasts/?limit=50"
    )!

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    /// All three channels at once. The main one is the only endpoint that has
    /// to succeed — the relays are frequently idle and answering thinly, and a
    /// failure there should not blank the station.
    func fetchSnapshot() async throws -> AlharaSnapshot {
        async let main: AlharaNowPlayingDTO = decode("api/now-playing")
        async let second: AlharaRelayDTO? = try? decode("api/ra2/now-playing")
        async let third: AlharaRelayDTO? = try? decode("api/ra3/now-playing")

        let primary = try await main
        var channels: [String: AlharaChannelState] = ["alhara.ra": primary.asChannelState()]
        if let second = await second { channels["alhara.ra2"] = second.asChannelState() }
        if let third = await third { channels["alhara.ra3"] = third.asChannelState() }

        return AlharaSnapshot(channels: channels, hidden: primary.hiddenChannels)
    }

    // MARK: - Archive

    /// alHara's recorded shows, newest first. `cursor` is the address Mixcloud
    /// handed back for the following page; it is opaque and goes back as it
    /// came.
    func fetchArchive(cursor: URL? = nil) async throws -> AlharaArchivePage {
        let page: MixcloudPageDTO = try await decode(url: cursor ?? Self.archive)
        return AlharaArchivePage(
            shows: page.data.compactMap { $0.asShow() },
            next: page.paging?.next.flatMap { URL(string: $0) }
        )
    }

    /// One show, with the description and tracklist the listing leaves out.
    func fetchShow(slug: String) async throws -> AlharaShow {
        let escaped = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "https://api.mixcloud.com/radioalhara/\(escaped)/") else {
            throw AlharaError.malformedResponse
        }
        let dto: MixcloudCloudcastDTO = try await decode(url: url)
        guard let show = dto.asShow() else { throw AlharaError.malformedResponse }
        return show
    }

    // MARK: - Transport

    private func decode<T: Decodable>(_ path: String) async throws -> T {
        try await decode(url: Self.base.appendingPathComponent(path, isDirectory: false))
    }

    private func decode<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw AlharaError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw AlharaError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AlharaError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Unknown paths on this host answer with the site's own HTML
            // rather than a 404, so a decode failure is the real signal.
            throw AlharaError.malformedResponse
        }
    }
}
