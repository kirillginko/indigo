import SwiftUI
import SwiftData

@MainActor @Observable
final class RadioDiscoverState {
    var picks: [RadioDiscoverPick] = []
    var working = false
    var message: String?
    var result: RadioDiscover.Result?
    private var loadedKey: String?
    private var loadedAt: Date?

    init() {
        guard RadioDiscoverFeature.isEnabled,
              let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("radio-curator-discover-v1.json"),
              let data = try? Data(contentsOf: file), let held = try? JSONDecoder().decode(RadioDiscover.Result.self, from: data),
              Date().timeIntervalSince(held.at) < 6 * 3600 else { return }
        picks = held.picks; result = held; loadedKey = held.key; loadedAt = held.at
    }

    func refresh(container: ModelContainer, force: Bool = false) async {
        guard RadioDiscoverFeature.isEnabled, !working else { return }
        working = true
        defer { working = false }
        message = nil
        let inputs = await Task.detached(priority: .utility) {
            RadioDiscover.inputs(context: ModelContext(container))
        }.value
        guard let inputs else {
            // A device with no listener profile must not show another
            // profile's cached recommendations as its own empty state.
            picks = []; result = nil; loadedKey = nil; loadedAt = nil
            message = nil
            return
        }
        if !force, loadedKey == inputs.key, let at = loadedAt, Date().timeIntervalSince(at) < (picks.isEmpty ? 600 : 6 * 3600) { return }
        if !force, let held = await RadioDiscoverCache.shared.load(key: inputs.key) {
            result = held; picks = held.picks; loadedKey = inputs.key; loadedAt = held.at
            return
        }
        do {
            let found = try await RadioDiscover(source: .live).discover(inputs) { [weak self] picks in
                await MainActor.run { self?.picks = picks }
            }
            result = found; picks = found.picks; loadedKey = inputs.key; loadedAt = found.at
            if found.picks.isEmpty { message = "No unfamiliar, playable tracks confirmed yet. Try again later." }
            await RadioDiscoverCache.shared.save(found)
        } catch {
            message = picks.isEmpty ? "Radio Discover couldn’t reach the tracklists. Try again." : "Showing the last confirmed tracks."
        }
    }
}

/// One recommendation per page, using exactly the same slide as the mix.
struct PhoneRadioDiscoverSlide: View {
    let pick: RadioDiscoverPick
    let insets: EdgeInsets
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let art = pick.track.sharpArtwork
        PhoneForYouSlide(card: .init(
            picture: art.full, kind: pick.track.isRecording ? "Track" : "In a radio show",
            title: pick.track.artist, subtitle: pick.track.title,
            reason: pick.track.reason, via: nil, heading: position,
            button: pick.track.isRecording ? "PLAY TRACK" : "HEAR IN RADIO SHOW",
            icon: pick.track.isRecording ? "play.fill" : "dot.radiowaves.left.and.right",
            preview: art.preview
        ), insets: insets) {
            pick.play(using: player)
        }
        .contextMenu { RadioDiscoverMenu(pick: pick) }
    }

    private var position: String {
        if case .episode(_, let at) = pick.track.source {
            return "Approx. start \(at / 60):\(String(format: "%02d", at % 60))"
        }
        return "Radio Discover"
    }
}

struct RadioDiscoverMenu: View {
    let pick: RadioDiscoverPick
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        Button { pick.play(using: player) } label: {
            Label(pick.track.playLabel, systemImage: "play.fill")
        }
        Button("Open \(pick.track.artist)") {
            appState.open(.digArtist(mbid: nil, name: pick.track.artist, discogsID: pick.track.artistDiscogsID))
        }
        if case .episode(let listen, _) = pick.track.source, let page = listen.page.destination {
            Button("Open \(pick.programme)") { appState.open(page) }
        }
        Text(pick.episode)
        Text(pick.timing.label)
    }
}

extension RadioDiscoverPick {
    @MainActor func play(using player: PlaybackCoordinator) {
        let (media, start) = track.mediaItem
        // Different recordings can share an episode ID: update the credit
        // and listening provenance as well as the seek position.
        player.play([media], from: ListeningSurface(screen: "foryou.radio-discover", via: programme, route: "curator-recording"))
        if let start { player.seekWhenReady(to: TimeInterval(start), in: media.id) }
    }
}
