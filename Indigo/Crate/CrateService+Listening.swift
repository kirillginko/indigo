//
//  CrateService+Listening.swift
//  Indigo
//
//  Keeping a track heard through a provider's own player.
//
//  Crated as a canonical recording rather than as a link, because that is what
//  it is: a piece of music with an artist and a title, which happens to be
//  reachable through YouTube today. Filed that way it joins the graph, can be
//  dug into, and will quietly gain a better source the day the listener buys
//  the record or hears it on air.
//

import Foundation
import SwiftData

extension CrateService {
    /// The identity a kept link is filed under — the address itself, so the
    /// same upload crated from two different pages is one recording.
    private static func identity(_ url: URL) -> String { url.absoluteString }

    func recording(forListening url: URL) -> Recording? {
        let identity = Self.identity(url)
        var descriptor = FetchDescriptor<RecordingSource>(predicate: #Predicate {
            $0.identifier == identity && $0.kindRaw == "streamingLink"
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recording
    }

    func isCrated(listening url: URL) -> Bool {
        guard let recording = recording(forListening: url) else { return false }
        return contains(recording: recording)
    }

    /// Keeps, or lets go of, a track heard through a provider's player.
    @discardableResult
    func toggle(
        listening url: URL,
        title: String,
        artist: String?,
        release: String? = nil,
        artworkURL: URL? = nil,
        provider: EmbedProvider = .youtube
    ) -> Recording? {
        if let existing = recording(forListening: url) {
            let wasCrated = contains(recording: existing)
            toggle(recording: existing)
            return wasCrated ? nil : existing
        }

        // Titles on these uploads are written by whoever posted them —
        // "Skee Mask - Rev8617" — so the same credit recovery a radio
        // tracklist gets applies here.
        let credit = TrackCredit.resolve(artist: artist, title: title)
        let store = RecordingStore(context: context)
        guard let recording = try? store.upsert(
            title: credit.title,
            artistName: credit.artist,
            status: credit.artist == nil ? .probable : .identified
        ) else {
            notice = "Couldn't add \(title) to your crate."
            return nil
        }
        if let release, recording.albumTitle?.isEmpty ?? true { recording.albumTitle = release }

        let link = RecordingSource(
            kind: .streamingLink,
            identifier: Self.identity(url),
            providerID: provider.rawValue
        )
        context.insert(link)
        link.recording = recording

        add(recording: recording)
        if let artworkURL {
            let identifier = recording.id
            var descriptor = FetchDescriptor<CrateItem>(
                predicate: #Predicate { $0.recording?.id == identifier }
            )
            descriptor.fetchLimit = 1
            if let item = (try? context.fetch(descriptor))?.first, item.artworkURLString == nil {
                item.artworkURLString = artworkURL.absoluteString
            }
        }
        try? context.save()
        return recording
    }
}
