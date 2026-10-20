//
//  RadioDiscoverCardRender.swift
//  IndigoTests
//
//  Radio Discover's cards with their curator evidence, as the phone slide and
//  the Mac map label draw them, to PNGs (opt-in: INDIGO_RENDER_RADIO_CARDS=1),
//  for looking at.
//

#if os(macOS)
import XCTest
import SwiftUI
@testable import Indigo

@MainActor
final class RadioDiscoverCardRender: XCTestCase {
    private func pick(curated: Bool) throws -> RadioDiscoverPick {
        let archive = try XCTUnwrap(URL(string: "https://soundcloud.com/x/beach-noir"))
        let listen = RadioListen(provider: "nts", episode: "beach-noir/ep", episodeTitle: "BEACH NOIR W/ NICK LEÓN & DJ Relax",
                                 showTitle: "BEACH NOIR W/ NICK LEÓN", airedAt: nil, played: "Sidewinder", offsetSeconds: 2270, archiveURL: archive)
        let reason = curated
            ? "Selected by 2 programmes, ZULI and BEACH NOIR W/ NICK LEÓN, that between them also play Ciro Vitiello, Purelink, mu tate from your ambient / experimental / abstract listening."
            : "Post-Geography played this next to The Roger Webb Sound — Moon Bird."
        let track = DiscoveredTrack(artist: curated ? "Alex Zhang Hungtai" : "Manual", artistDiscogsID: 1, title: curated ? "Sidewinder" : "Tomorrow",
                                    source: .episode(listen, at: 2270), knownArtist: false, reason: reason, via: "BEACH NOIR", playable: .yes, score: 1)
        return RadioDiscoverPick(track: track, artistRow: UUID(), cluster: 0, clusterLabel: "ambient / experimental / abstract",
                                 programme: curated ? "BEACH NOIR W/ NICK LEÓN" : "Post-Geography", episode: listen.episodeTitle, curator: nil,
                                 timing: .publisherEstimated, supportEpisodes: 3, nearest: "Ciro Vitiello, Purelink, mu tate", distance: curated ? 0 : 1, styles: [],
                                 evidence: curated
                                    ? .init(programmes: ["ZULI", "BEACH NOIR W/ NICK LEÓN"], bridges: ["Ciro Vitiello", "Purelink", "mu tate"], episodes: 3, curators: 2, curated: true)
                                    : .init(programmes: ["Post-Geography"], bridges: ["The Roger Webb Sound"], episodes: 1, curators: 1, curated: false))
    }

    private func write(_ view: some View, _ name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("RENDERED=\(url.path)")
    }

    func testRenderTheCards() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_RENDER_RADIO_CARDS"] == "1")
        let player = PlaybackCoordinator()
        for curated in [true, false] {
            let p = try pick(curated: curated)
            try write(PhoneRadioDiscoverSlide(pick: p, insets: EdgeInsets(top: 59, leading: 0, bottom: 112, trailing: 0))
                        .frame(width: 393, height: 852).environment(player).environment(\.isPhoneLayout, true)
                        .environment(\.colorScheme, .dark).background(Color.black),
                      "radio-card-phone-\(curated ? "curated" : "adjacent")")
            try write(MapLabel(p.track.artist, p.track.title, MosaicColor.lavender, nil, p.track.artistDiscogsID, 260, connection: p.connection)
                        .padding(20).background(Color(white: 0.95)),
                      "radio-card-mac-\(curated ? "curated" : "adjacent")")
        }
    }
}
#endif
