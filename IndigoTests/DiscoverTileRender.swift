//
//  DiscoverTileRender.swift
//  IndigoTests
//
//  The Discover grid as the phone draws it, to a PNG (opt-in:
//  INDIGO_RENDER_DISCOVER=1), for looking at.
//

import XCTest
import SwiftUI
@testable import Indigo

@MainActor
final class DiscoverTileRender: XCTestCase {
    func testRenderTheGrid() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_RENDER_DISCOVER"] == "1")
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa"))
        let sc = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        let tracks = [
            DiscoveredTrack(artist: "Biosphere", artistDiscogsID: 1, title: "05. times when i know you'll be sad (substrata)",
                            source: .recording(url, channel: "Noka"), reason: "Played next to Aphex Twin in 3 radio episodes",
                            via: "Aphex Twin", playable: .yes, score: 1),
            DiscoveredTrack(artist: "Balil", artistDiscogsID: 2, title: "3/4 Heart", source: .recording(url, channel: "TheIDMMaster"),
                            reason: "With Black Dog Productions: Credited together", via: "Black Dog Productions", playable: .yes, score: 1),
            DiscoveredTrack(artist: "Burial", artistDiscogsID: 3, title: "Near Dark",
                            source: .episode(RadioListen(provider: "nts", episode: "a/b", episodeTitle: "Timetable", showTitle: "Timetable",
                                                         airedAt: nil, played: "Near Dark", offsetSeconds: 260, archiveURL: sc), at: 260),
                            reason: "Played next to Aphex Twin in 3 radio episodes", via: "Aphex Twin", playable: .yes, score: 1),
            DiscoveredTrack(artist: "Mark Van Hoen", artistDiscogsID: 4, title: "1967",
                            source: .episode(RadioListen(provider: "nts", episode: "c/d", episodeTitle: "Bridget Small", showTitle: "Bridget Small",
                                                         airedAt: nil, played: "1967", offsetSeconds: 2596, archiveURL: sc), at: 2596),
                            reason: "With Seefeel: Producer on Pure, Impure", via: "Seefeel", playable: .yes, score: 1)
        ]
        let view = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: 2), spacing: 12) {
            ForEach(tracks) { DiscoverTile(track: $0, play: {}, artist: {}, episode: {}) }
        }
        .frame(width: 390).padding(.vertical, 16)
        .background(Color(red: 0.08, green: 0.1, blue: 0.09)).environment(\.isPhoneLayout, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        #if os(macOS)
        let png = try XCTUnwrap(renderer.nsImage.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        #else
        let png = try XCTUnwrap(renderer.uiImage?.pngData())
        #endif
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("discover-grid.png"))
    }
}
