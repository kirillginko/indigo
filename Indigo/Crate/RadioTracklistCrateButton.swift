import SwiftUI
import SwiftData

nonisolated struct RadioTracklistItem: Hashable, Sendable {
    let providerID: String
    let showID: String
    let showTitle: String
    let airedAt: Date?
    let entryID: String
    let title: String
    let artist: String?
    let offsetSeconds: Double?

    var rowIdentity: String { "\(providerID)|\(showID)|\(entryID)" }

    /// Some providers expose tracklists as display strings instead of fields.
    /// Recover the common `Artist — Title` shape before creating a canonical
    /// recording so DIG has an artist node it can enrich.
    var resolvedCredit: (artist: String?, title: String) {
        TrackCredit.resolve(artist: artist, title: title)
    }
}

struct RadioTracklistCrateButton: View {
    let item: RadioTracklistItem
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    var body: some View {
        let _ = crate.revision
        CrateGlyphButton(isCrated: crate.isCrated(radioTracklistItem: item)) {
            if let recording = crate.toggle(radioTracklistItem: item) {
                Task { await dig.enrichCratedRecording(recording) }
            }
        }
        .help(crate.isCrated(radioTracklistItem: item)
              ? "Remove \(item.title) from crate"
              : "Add \(item.title) to crate")
    }
}

extension CrateService {
    func isCrated(radioTracklistItem item: RadioTracklistItem) -> Bool {
        guard let recording = radioTracklistRecording(item) else { return false }
        return contains(recording: recording)
    }

    @discardableResult
    func toggle(radioTracklistItem item: RadioTracklistItem) -> Recording? {
        if let recording = radioTracklistRecording(item) {
            let wasCrated = contains(recording: recording)
            toggle(recording: recording)
            return wasCrated ? nil : recording
        }
        let credit = item.resolvedCredit
        let recording = Recording(title: credit.title, artistName: credit.artist, status: .probable)
        context.insert(recording)
        let heardAt = (item.airedAt ?? Date()).addingTimeInterval(item.offsetSeconds ?? 0)
        RecordingStore(context: context).note(
            appearance: MediaAppearance(
                providerID: item.providerID, showTitle: item.showTitle, showID: item.showID,
                heardAt: heardAt, offsetSeconds: item.offsetSeconds, isLive: false,
                method: .providerTracklist,
                originalMetadata: [item.artist, item.title].compactMap { $0 }.joined(separator: " — ")
            ),
            on: recording
        )
        let identity = RecordingSource(
            kind: .broadcastAppearance, identifier: item.rowIdentity,
            providerID: "radio.tracklist.row", offsetSeconds: item.offsetSeconds
        )
        context.insert(identity)
        identity.recording = recording
        add(recording: recording)
        return recording
    }

    func radioTracklistRecording(_ item: RadioTracklistItem) -> Recording? {
        let identity = item.rowIdentity
        var descriptor = FetchDescriptor<RecordingSource>(predicate: #Predicate {
            $0.identifier == identity && $0.providerID == "radio.tracklist.row"
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recording
    }
}
