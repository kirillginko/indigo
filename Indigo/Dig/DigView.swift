//
//  DigView.swift
//  Indigo
//
//  The way in. DIG has no meaning on its own — it is always about something —
//  so this page is the list of things worth digging into: the artists already
//  in your crate, your library and your listening.
//

import SwiftUI
import SwiftData

struct DigView: View {
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    var body: some View {
        let _ = crate.revision
        let _ = dig.revision
        let entries = startingPoints()

        VStack(spacing: 0) {
            PageHeader(
                title: "Dig",
                subtitle: entries.isEmpty ? "Follow the music" : "\(entries.count) artists to follow"
            )
            Rule(color: Palette.outline)

            if entries.isEmpty {
                EmptyStateView(
                    headline: "Nothing to dig into yet",
                    message: "Crate something, or index a music folder. Dig follows artists into their labels, and labels into everyone else on them."
                ) {
                    Button("Open Crate") { appState.select(.crate) }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            DigStartRow(entry: entry) {
                                appState.open(.digArtist(mbid: entry.mbid, name: entry.name))
                            }
                            Rule()
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    struct StartingPoint: Identifiable, Hashable {
        let name: String
        let mbid: String?
        let crateCount: Int
        let libraryCount: Int
        var id: String { mbid ?? name }

        /// "3 crated · 12 in library"
        var detail: String {
            var parts: [String] = []
            if crateCount > 0 { parts.append("\(crateCount) crated") }
            if libraryCount > 0 { parts.append("\(libraryCount) in library") }
            return parts.joined(separator: " · ")
        }
    }

    /// Crated artists first — those are the ones the listener chose — then
    /// whatever else the library is deepest in.
    private func startingPoints() -> [StartingPoint] {
        let engine = DigEngine(context: dig.context)
        let context = dig.context

        var names: [String: (crate: Int, mbid: String?)] = [:]
        for item in (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [] {
            guard let artist = item.recording?.artistName, !artist.isEmpty else { continue }
            let mbid = item.recording.flatMap { engine.metadata(for: $0.id)?.artistMBID }
            let existing = names[artist]
            names[artist] = ((existing?.crate ?? 0) + 1, existing?.mbid ?? mbid)
        }

        // Counted by the same rule the artist page uses, keyed on the
        // normalised name and displayed with the spelling the files use.
        var library: [String: Int] = [:]
        var display: [String: String] = [:]
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            for key in DigEngine.artistKeys(for: track) {
                library[key, default: 0] += 1
                if display[key] == nil {
                    display[key] = RecordingKey.normalizeArtist(track.artist) == key
                        ? track.artist
                        : track.albumArtist
                }
            }
        }
        for (key, _) in library {
            guard let name = display[key], !name.isEmpty else { continue }
            if names[name] == nil { names[name] = (0, nil) }
        }

        return names
            .map {
                StartingPoint(
                    name: $0.key,
                    mbid: $0.value.mbid,
                    crateCount: $0.value.crate,
                    libraryCount: library[RecordingKey.normalizeArtist($0.key)] ?? 0
                )
            }
            .sorted {
                if $0.crateCount != $1.crateCount { return $0.crateCount > $1.crateCount }
                if $0.libraryCount != $1.libraryCount { return $0.libraryCount > $1.libraryCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

private struct DigStartRow: View {
    let entry: DigView.StartingPoint
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(entry.name)
                    .font(Typeface.body(12.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.detail)
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
            }
            .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight + 4)
            .background(isHovering ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
