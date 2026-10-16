//
//  ForYouTracksRender.swift
//  IndigoTests
//
//  "Tracks to hear" as For You draws it -- the Mac's band on the cobalt page
//  and the phone's slide -- to PNGs for looking at (opt-in:
//  INDIGO_RENDER_FORYOU_TRACKS=1). The real views, over a DIG store holding
//  a list of the shape Discover finds.
//

import XCTest
import SwiftUI
import SwiftData
@testable import Indigo

@MainActor
final class ForYouTracksRender: XCTestCase {
    func testRenderTheSectionAndTheSlide() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_RENDER_FORYOU_TRACKS"] == "1")
        let container = try ModelContainer(for: Persistence.schema, configurations: ModelConfiguration(
            schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let dig = DigStore(context: context)
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa"))
        let sc = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        func episode(_ artist: String, _ id: Int, _ title: String, _ show: String, _ at: Int, via: String) -> DiscoveredTrack {
            DiscoveredTrack(artist: artist, artistDiscogsID: id, title: title,
                            source: .episode(RadioListen(provider: "nts", episode: "a/\(id)", episodeTitle: show, showTitle: show,
                                                         airedAt: nil, played: title, offsetSeconds: at, archiveURL: sc), at: at),
                            signal: .longTerm, knownArtist: false,
                            reason: "Played next to \(via) in 2 radio episodes", via: via, playable: .yes, score: 1)
        }
        dig.discover = DiscoverState(tracks: [
            DiscoveredTrack(artist: "Biosphere", artistDiscogsID: 1, title: "times when i know you'll be sad (substrata)",
                            source: .recording(url, channel: "Noka"), signal: .longTerm, knownArtist: false,
                            reason: "Played next to Aphex Twin in 3 radio episodes", via: "Aphex Twin", playable: .yes, score: 1),
            episode("Burial", 2, "Near Dark", "Timetable", 260, via: "Aphex Twin"),
            episode("feeo", 3, "Violet Flood", "Debt & Refuge", 8, via: "Dean Blunt"),
            DiscoveredTrack(artist: "Solma", artistDiscogsID: 4, title: "Porl Af (tor)", source: .recording(url, channel: "PARAĐIGMAS"),
                            signal: .longTerm, knownArtist: false, reason: "Played next to Purelink in 1 radio episode",
                            via: "Purelink", playable: .yes, score: 1),
            episode("bambinodj", 5, "Spellfall", "United In Flames w/ Malibu", 3015, via: "mu tate"),
            episode("Pontiac Streator", 6, "Petabyte", "Omriss w/ Carmen Villain", 2244, via: "Purelink"),
            episode("Car Culture", 7, "Is Love Knowing", "Last Resort", 882, via: "mu tate"),
        ], at: Date())
        func environment(_ view: some View) -> some View {
            view.environment(dig).environment(AppState()).environment(PlaybackCoordinator())
                .environment(CrateService(context: context, writable: false))
        }
        func write(_ view: some View, _ name: String) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            #if os(macOS)
            let png = try XCTUnwrap(renderer.nsImage.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
            #else
            let png = try XCTUnwrap(renderer.uiImage?.pngData())
            #endif
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        try write(environment(ForYouTracksSection().frame(width: 900).padding(.bottom, 24).background(MosaicColor.cobalt)),
                  "foryou-tracks-mac.png")
        try write(environment(PhoneForYouTracksSlide(insets: EdgeInsets(top: 44, leading: 0, bottom: 34, trailing: 0))
            .frame(width: 390, height: 844)), "foryou-tracks-phone.png")
    }
}
