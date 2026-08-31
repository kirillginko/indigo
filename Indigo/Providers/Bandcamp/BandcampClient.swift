//
//  BandcampClient.swift
//  Indigo
//
//  Reads Bandcamp release pages, and nothing else.
//
//  Deliberately has no search. Bandcamp's robots.txt disallows `/search` and
//  `/api/` to every user agent, so Indigo never asks Bandcamp to find
//  anything — it is told where to look by a sanctioned source and reads the
//  structured description published on that page.
//
//  Requests are serialised and spaced. One listener idly digging should never
//  look like a crawler to somebody else's server.
//

import Foundation

nonisolated enum BandcampError: LocalizedError, Equatable {
    case notABandcampPage
    case badStatus(Int)
    case noStructuredData
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notABandcampPage: "That isn't a Bandcamp address."
        case .badStatus(let code): "Bandcamp returned an unexpected response (\(code))."
        case .noStructuredData: "That Bandcamp page doesn't describe a release."
        case .transport(let detail): detail
        }
    }
}

protocol BandcampTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: BandcampTransport {}

nonisolated struct BandcampClient: Sendable {
    private let transport: BandcampTransport
    private let gate: RateGate

    /// A second between requests. Bandcamp publishes no rate limit, so this
    /// errs well on the polite side of one.
    init(transport: BandcampTransport = NetworkEnvironment.metadataSession) {
        self.transport = transport
        gate = RateGate(interval: 1.0)
    }

    /// Only ever *.bandcamp.com and only the paths its robots.txt permits.
    /// A URL that arrives from a catalogue is still a URL from the internet.
    static func isReadable(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(),
              host == "bandcamp.com" || host.hasSuffix(".bandcamp.com")
        else { return false }
        let path = url.path().lowercased()
        let forbidden = ["/tools", "/checkout", "/download_check", "/cart/",
                         "/corpbanner/", "/stream", "/api/", "/design_tokens", "/search"]
        return !forbidden.contains { path.hasPrefix($0) }
    }

    /// The releases an artist has published, from their own index page.
    func releaseURLs(forArtistAt page: URL) async throws -> [URL] {
        guard Self.isReadable(page) else { throw BandcampError.notABandcampPage }
        var index = page
        // The index lives at /music; a bare artist URL redirects to whichever
        // release they are currently featuring, which is not what we want.
        if index.path().isEmpty || index.path() == "/" {
            index = page.appending(path: "music")
        }
        let html = try await html(at: index)
        let origin = Self.origin(of: page)

        var seen = Set<String>()
        var found: [URL] = []
        for match in html.matches(of: /href="(\/(?:album|track)\/[A-Za-z0-9\-_%]+)"/) {
            let path = String(match.output.1)
            guard seen.insert(path).inserted, let url = URL(string: origin + path) else { continue }
            found.append(url)
        }
        return found
    }

    /// One release, as Bandcamp itself describes it.
    func release(at url: URL) async throws -> BandcampReleaseInfo {
        guard Self.isReadable(url) else { throw BandcampError.notABandcampPage }
        let html = try await html(at: url)
        guard let json = Self.structuredData(in: html) else { throw BandcampError.noStructuredData }
        let album = try JSONDecoder().decode(BandcampAlbumLD.self, from: Data(json.utf8))
        guard let release = album.asRelease(url: url) else { throw BandcampError.noStructuredData }
        return release
    }

    /// The `application/ld+json` block. Extracted by hand rather than with a
    /// full HTML parse: it is one well-known tag on a page that is otherwise
    /// several hundred kilobytes of markup nobody needs.
    static func structuredData(in html: String) -> String? {
        guard let opening = html.range(of: "<script type=\"application/ld+json\">") else { return nil }
        let rest = html[opening.upperBound...]
        guard let closing = rest.range(of: "</script>") else { return nil }
        let block = rest[..<closing.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : block
    }

    static func origin(of url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host() else { return "" }
        return "\(scheme)://\(host)"
    }

    private func html(at url: URL) async throws -> String {
        await gate.wait()
        var request = URLRequest(url: url)
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw BandcampError.badStatus(http.statusCode)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw BandcampError.noStructuredData
            }
            return text
        } catch let error as BandcampError {
            throw error
        } catch {
            throw BandcampError.transport(error.localizedDescription)
        }
    }
}

nonisolated extension DiscogsArtist {
    /// The artist's own Bandcamp, as their catalogue entry states it. This is
    /// how Indigo learns the address without ever searching Bandcamp.
    var bandcampURL: URL? {
        for value in externalURLStrings {
            guard let url = URL(string: value), BandcampClient.isReadable(url) else { continue }
            return url
        }
        return nil
    }
}
