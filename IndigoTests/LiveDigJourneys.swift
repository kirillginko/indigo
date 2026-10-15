//
//  LiveDigJourneys.swift
//  IndigoTests
//
//  Guided DIG journeys on real pages: open an artist as the app does (live
//  Discogs and R2), show today's musician-first top three beside the
//  recommendation cards, follow the first direct card, and do it again, up to
//  three steps, never back to a page already opened.
//
//  Opt-in: `INDIGO_LIVE_JOURNEYS=1`. Works on a copy of this Mac's
//  Development stores. Report: `live-dig-journeys.txt` in the host's
//  temporary directory.
//

import XCTest
import SwiftData
import SwiftUI
@testable import Indigo

@MainActor
final class LiveDigJourneys: XCTestCase {
    override func tearDown() { MusicianFirst.override = nil }

    /// The cards as the phone draws them, to a PNG beside the report.
    private func render(_ cards: [DigRecommendation], named name: String) {
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(cards) { card in RecommendationCardView(card: card, open: {}, listen: {}) }
        }
        .padding(16)
        .frame(width: 390, alignment: .leading)
        .background(Color(red: 0.08, green: 0.1, blue: 0.09))
        .foregroundStyle(.white)
        .environment(\.isPhoneLayout, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        #if os(macOS)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        #else
        guard let png = renderer.uiImage?.pngData() else { return }
        #endif
        try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
    }

    private static let starts: [(family: String, name: String)] = [
        ("obscure jazz", "Eric Kloss"),
        ("experimental electronic", "Mattheis"),
        ("ambient", "Huerco S."),
        ("indie", "Duster"),
        ("hip-hop", "Quelle Chris")
    ]

    func testFollowTheCards() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_JOURNEYS"] == "1", "Live: set INDIGO_LIVE_JOURNEYS=1.")
        MusicianFirst.override = true
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Development")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Journeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = support.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                }
            }
        }
        let container = try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let client = DiscogsClient(transport: NetworkEnvironment.metadataSession, token: try XCTUnwrap(ObfuscatedSecret.reveal(bundled)))
        let dig = DigStore(context: context, discogsClient: client)
        dig.readStoredRelease = { id in
            guard let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))),
                  let (data, response) = try? await URLSession.shared.data(from: url) else { return .unavailable }
            if (response as? HTTPURLResponse)?.statusCode == 404 { return .missing }
            return (try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data)).map { .document($0) } ?? .unavailable
        }
        let source = DigRecommendationSource(context: context)
        let longTerm = source.longTerm(now: Date())

        var out: [String] = []
        var cardTimes: [Double] = []
        var verifyTimes: [Duration] = []
        DigRecommendations.override = true
        defer { DigRecommendations.override = nil }
        var tally = (pages: 0, todayCards: 0, todayHear: 0, cards: 0, hear: 0, fromRecord: 0, direct: 0, technicalToday: 0, steps: 0)

        func show(_ card: DigRecommendation) -> String {
            let record = card.evidence.map { " — \($0.title)\($0.year.map { " (\($0))" } ?? "")" } ?? ""
            switch card.listen {
            case .recording(_, let title)?: return "\(card.artist.title) [\(card.relationship.label)]\(record) ▶ \(title)"
            case .radio(let title, _, _, _)?: return "\(card.artist.title) [\(card.relationship.label)]\(record) ▶ radio: \(title)"
            case nil: return "\(card.artist.title) [\(card.relationship.label)]\(record)"
            }
        }

        for start in Self.starts {
            out.append("")
            out.append("== \(start.family): \(start.name)")
            var visited = Set<String>()
            var journeyNames: [String] = []
            var journeyTags: [String] = []
            var name = start.name, discogsID: Int? = nil
            for step in 0...3 {
                await dig.enrichArtist(name: name, mbid: nil, discogsID: discogsID)
                let page = dig.artistPage(ArtistReference(name: name, discogsID: discogsID))
                await dig.backfillReleaseCredits(forArtist: page.name)
                let verifying = ContinuousClock.now
                await dig.verifyRecommendationCandidates(forArtist: page.name, discogsID: page.discogsID)
                verifyTimes.append(ContinuousClock.now - verifying)
                let origin = MusicNode.artist(page.name, discogsID: page.discogsID)
                visited.insert(origin.id)
                visited.insert(MusicNode.artist(page.name).id)
                journeyNames.insert(page.name, at: 0)
                let pageTags = ListeningLog.foldTags(DiscogsEnricher(context: context, client: DiscogsClient()).cachedArtist(named: page.name).map { $0.styles + $0.genres } ?? [])
                journeyTags = pageTags + journeyTags.filter { !pageTags.contains($0) }

                // Today's musician-first top three: the page's routes by
                // musician-first value, as lanes order them.
                let lookups = source.lookups(for: page.name, shelf: dig.shelfEvidence[RecordingKey.normalizeArtist(page.name)] ?? [:])
                let edges = IdentityGraph(context: context).neighbourhood(of: origin).edges.all
                MusicianFirst.override = false
                let todayEdges = IdentityGraph(context: context).neighbourhood(of: origin).edges.all
                MusicianFirst.override = true
                let today = todayEdges.filter { $0.to.kind == .artist && $0.to.id != origin.id }
                    .sorted { ($0.weight * MusicianFirstRanker.worth($0), $1.to.title) > ($1.weight * MusicianFirstRanker.worth($1), $0.to.title) }
                    .reduce(into: [MusicEdge]()) { kept, edge in if !kept.contains(where: { $0.to.id == edge.to.id }) { kept.append(edge) } }
                    .prefix(3)
                let technical = today.filter { DigRecommender.role(in: $0.reason).map { CreditRole.contribution(of: $0) == .technical } ?? false }.count

                var listener = source.listener(now: Date(), opened: origin, longTerm: longTerm)
                listener.visited.formUnion(visited)
                listener.visitedNames += journeyNames
                listener.sessionTags = journeyTags + listener.sessionTags
                let started = ContinuousClock.now
                let cards = DigRecommender.recommend(from: edges, origin: origin, lookups: lookups, listener: listener)
                let spent = ContinuousClock.now - started
                cardTimes.append(Double(spent.components.attoseconds) / 1e15 + Double(spent.components.seconds) * 1000)

                tally.pages += 1
                tally.todayCards += today.count
                tally.technicalToday += technical
                tally.cards += cards.count
                tally.hear += cards.filter { $0.listen != nil }.count
                tally.fromRecord += cards.filter { $0.listen?.isFromTheEvidence == true }.count
                tally.direct += cards.filter { $0.relationship.isDirect }.count

                if step == 0, !cards.isEmpty { render(cards, named: "cards-\(start.family.replacingOccurrences(of: " ", with: "-"))") }
                out.append("\(step == 0 ? "start" : "step \(step)"): \(page.name)\(page.discogsID.map { " [\($0)]" } ?? "") — \(edges.count) routes")
                out.append("  today:  " + today.map { "\($0.to.title) (\($0.reason))" }.joined(separator: "; "))
                out.append("  cards:  " + (cards.isEmpty ? "none" : cards.map(show).joined(separator: "; ")))
                guard step < 3, let next = cards.first(where: { $0.relationship.isDirect }) else {
                    if step < 3 { out.append("  (stops: no direct card left that has not been visited)") }
                    break
                }
                tally.steps += 1
                name = next.artist.title
                discogsID = next.artist.discogsID
            }
        }
        cardTimes.sort()
        out.insert("Live journeys, \(Self.starts.count) starts, \(tally.pages) pages, \(tally.steps) steps followed. Today's top three: \(tally.todayCards) routes, \(tally.technicalToday) of them technical. Cards: \(tally.cards), direct \(tally.direct), something to hear \(tally.hear) (from the record \(tally.fromRecord)). Cards worked out in \(String(format: "%.0f", cardTimes.isEmpty ? 0 : cardTimes[cardTimes.count / 2])) ms median, \(String(format: "%.0f", cardTimes.last ?? 0)) ms slowest. Verifying the top unverified names took \(verifyTimes.sorted().dropFirst(verifyTimes.count / 2).first.map { "\($0)" } ?? "-") median.", at: 0)
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-dig-journeys.txt"),
                                               atomically: true, encoding: .utf8)
    }
}
