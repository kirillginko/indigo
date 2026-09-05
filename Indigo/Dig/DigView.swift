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

/// Everything the Dig landing page draws, in one piece.
///
/// Held by `DigStore` rather than by the view. `@State` dies when the view
/// leaves the hierarchy, so going to a release and coming back was rebuilding
/// the page from the library — half a second of scanning to redraw something
/// that had not changed, with the veil over it saying so.
struct DigLanding {
    var crateRevision: Int
    var entries: [DigView.StartingPoint]
    var recent: [DigVisit]
    var haunts: [DigVisit]
    var suggestions: [DigHistory.Suggestion]
    var nextSteps: [String: String]
    var radio: Catalog.DigRadio?
}

struct DigView: View {
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    // Worked out in a task, not in `body`. Suggestions walk the graph out of
    // every place the listener keeps returning to, and doing that on each
    // redraw made opening DIG feel like loading it.
    @State private var recentVisits: [DigVisit] = []
    @State private var frequentVisits: [DigVisit] = []
    @State private var trySuggestions: [DigHistory.Suggestion] = []
    @State private var nextSteps: [String: String] = [:]
    /// What radio knows about the artists this listener keeps. The only part
    /// of this page that asks the backend anything.
    @State private var radio: Catalog.DigRadio?
    /// The page appears once, whole. Everything above the list arrives from a
    /// task, so drawing before it lands meant showing the artists and then
    /// shoving them down a moment later.
    ///
    /// Set once and never cleared. A later refresh updates what is on screen
    /// without veiling it again — enrichment writes constantly, and a page
    /// that went soft every time one landed would spend the evening blurring
    /// at somebody trying to read it.
    @State private var isReady = false
    /// Held rather than computed in `body`.
    ///
    /// Working these out reads every crate item and every track in the
    /// library, and it was happening on each redraw — which on this page means
    /// every hover, and every time enrichment wrote a row anywhere. Once per
    /// change is the same answer for a fraction of the work.
    @State private var entries: [StartingPoint] = []

    /// What the page is a function of. Reading both here is also what
    /// subscribes `body` to them, so a change still redraws.
    private var revision: String { "\(crate.revision)-\(dig.revision)" }

    var body: some View {
        // What to draw this frame: what this view has worked out, or failing
        // that whatever the store still holds. `.task` cannot run before the
        // first render, so without this a return to DIG shows a skeleton for a
        // frame to somebody who was reading the page a moment ago.
        let shown = shown
        let entries = shown.entries
        let hasSomething = isReady || dig.landing != nil

        VStack(spacing: 0) {
            PageHeader(
                title: "Dig",
                subtitle: entries.isEmpty ? "Follow the music" : "\(entries.count) artists to follow"
            )
            Rule(color: Palette.outline)

            // "Nothing to dig into" is only true once we have looked. Said
            // while still looking it is a failure announced in advance, and
            // this page opens on it every single time.
            if hasSomething && entries.isEmpty {
                EmptyStateView(
                    headline: "Nothing to dig into yet",
                    message: "Crate something, or index a music folder. Dig follows artists into their labels, and labels into everyone else on them."
                ) {
                    Button("Open Crate") { appState.select(.crate) }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    // Only until the library has been read, which is the one
                    // stretch where there is genuinely nothing to soften. The
                    // veil needs something to breathe on or the page reads as
                    // stopped rather than arriving.
                    if entries.isEmpty {
                        DigSkeleton(hasImage: false, sections: 3)
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.top, 22)
                    }

                    memory(shown)

                    if !entries.isEmpty {
                        HStack {
                            Text("Start from").microLabel(1.8).foregroundStyle(Palette.inkFaint)
                            Spacer()
                            Text("\(entries.count)").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 9)
                        Rule(color: Palette.outline)

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
                }
                .scrollIndicators(.visible)
                // One treatment for the whole page. See `LoadingVeil`.
                //
                // The list arrives before the blocks above it do, so it moves
                // once while it is still soft — and the moment the veil lifts
                // is the moment the page is finished. One reveal, and nothing
                // rearranging itself in front of somebody reading it.
                .loadingVeil(!hasSomething)
            }
        }
        .task(id: revision) { await refresh() }
    }

    /// Local history first, then a moment for radio — and then the page,
    /// whether radio answered or not.
    ///
    /// The request is never cancelled by the deadline; it simply stops being
    /// something the page waits on. A backend having a slow morning must not
    /// be able to hold DIG shut, and a backend answering promptly should not
    /// make the page move twice.
    private func refresh() async {
        // What the page looked like last time, put straight back. Returning to
        // DIG is then a redraw rather than a rebuild — nothing to scan, nothing
        // to wait for, and no veil over a page that is already complete.
        let cached = dig.landing
        if let cached {
            apply(cached)
            isReady = true
        }

        // Starting points come from the crate and the library, and the page
        // also redraws on the dig revision — which every enrichment write
        // bumps. Scanning again for that would be half a second spent
        // confirming nothing had changed.
        let crateChanged = cached?.crateRevision != crate.revision
        if crateChanged {
            entries = Trace.slowStep("dig.startingPoints") { startingPoints() }
        }

        // Always re-read: they have just been somewhere, and where they have
        // been is what this block is.
        await refreshMemory()

        if crateChanged || radio == nil {
            let names = entries.prefix(60).map(\.name)
            let radioLoad = Task { await refreshRadio(for: names) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await radioLoad.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(900)) }
                await group.next()
                group.cancelAll()
            }
        }

        isReady = true
        dig.landing = DigLanding(
            crateRevision: crate.revision,
            entries: entries,
            recent: recentVisits,
            haunts: frequentVisits,
            suggestions: trySuggestions,
            nextSteps: nextSteps,
            radio: radio
        )
    }

    /// This view's own answer once it has one, and the store's until then.
    private var shown: DigLanding {
        if isReady || !entries.isEmpty {
            return DigLanding(
                crateRevision: crate.revision,
                entries: entries,
                recent: recentVisits,
                haunts: frequentVisits,
                suggestions: trySuggestions,
                nextSteps: nextSteps,
                radio: radio
            )
        }
        return dig.landing ?? DigLanding(
            crateRevision: -1, entries: [], recent: [], haunts: [],
            suggestions: [], nextSteps: [:], radio: nil
        )
    }

    private func apply(_ landing: DigLanding) {
        entries = landing.entries
        recentVisits = landing.recent
        frequentVisits = landing.haunts
        trySuggestions = landing.suggestions
        nextSteps = landing.nextSteps
        radio = landing.radio
    }

    /// Asked about the names already worked out, not about the library again.
    /// Sending all of it would be a large request to answer a question about
    /// the top of a list.
    private func refreshRadio(for names: some Sequence<String>) async {
        guard SupabaseService.isConfigured else { return }
        radio = try? await RadioRepository.shared.digRadio(forArtists: Array(names))
    }

    private func refreshMemory() async {
        let history = DigHistory(context: dig.context)
        recentVisits = history.recent(limit: 4)
        frequentVisits = history.haunts()
        nextSteps = Dictionary(
            recentVisits.compactMap { visit in
                history.usualNextStep(from: visit.node).map { (visit.nodeID, $0.title) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        trySuggestions = history.suggestions()
    }

    /// What this listener has actually been doing. Their own history first,
    /// before any catalogue or aggregate — it is better evidence about them
    /// than anything else available, and it needs nobody's data but theirs.
    @ViewBuilder
    private func memory(_ shown: DigLanding) -> some View {
        let recent = shown.recent
        let haunts = shown.haunts
        let suggestions = shown.suggestions
        let radio = shown.radio ?? Catalog.DigRadio(onRadio: [], alongside: [])

        if !recent.isEmpty || !haunts.isEmpty || !suggestions.isEmpty || !radio.isEmpty {
            VStack(alignment: .leading, spacing: 26) {
                if !recent.isEmpty {
                    DigSection(title: "Continue digging") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(recent, id: \.nodeID) { visit in
                                DigLine(
                                    text: continueLine(visit, in: shown),
                                    detail: visit.kind.label
                                ) {
                                    if let page = visit.node.destination { appState.open(page) }
                                }
                                Rule()
                            }
                        }
                    }
                }

                if !haunts.isEmpty {
                    DigSection(title: "You often dig through") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(haunts, id: \.nodeID) { visit in
                                DigLine(
                                    text: visit.title,
                                    detail: "\(visit.visits) visits"
                                ) {
                                    if let page = visit.node.destination { appState.open(page) }
                                }
                                Rule()
                            }
                        }
                    }
                }

                // Radio, about the artists they actually keep. This is the
                // only thing on the page that knows something the listener's
                // own history cannot: what happened on air while they were
                // not listening.
                if !radio.alongside.isEmpty {
                    DigSection(title: "Played next to yours") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(radio.alongside) { neighbour in
                                DigLine(text: neighbour.name, detail: neighbour.reason) {
                                    appState.open(.digArtist(mbid: nil, name: neighbour.name))
                                }
                                Rule()
                            }
                        }
                    }
                }

                if !radio.onRadio.isEmpty {
                    DigSection(title: "Yours, on radio") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(radio.onRadio) { play in
                                DigLine(text: play.line, detail: play.dateLabel) {
                                    if let page = broadcast(play) { appState.open(page) }
                                }
                                Rule()
                            }
                        }
                    }
                }

                if !suggestions.isEmpty {
                    DigSection(title: "Try") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions) { suggestion in
                                DigLine(
                                    text: suggestion.node.title,
                                    detail: [suggestion.why?.headline, "via \(suggestion.via.title)"]
                                        .compactMap { $0 }.joined(separator: " · ")
                                ) {
                                    if let page = suggestion.node.destination { appState.open(page) }
                                }
                                Rule()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 22)
            .padding(.bottom, 6)
        }
    }

    /// The broadcast a play refers to, when Indigo has a page for it.
    private func broadcast(_ play: Catalog.DigRadio.Play) -> DetailPage? {
        guard play.provider == "nts", let external = play.episodeExternalID else { return nil }
        let parts = external.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return .ntsEpisode(show: parts[0], episode: parts[1])
    }

    /// "Ilian Tape → Stenny" when there is a step they usually take from
    /// there, and just the place when there isn't.
    private func continueLine(_ visit: DigVisit, in shown: DigLanding) -> String {
        guard let next = shown.nextSteps[visit.nodeID] else { return visit.title }
        return "\(visit.title) → \(next)"
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
            let artist = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            // "Various" is where a catalogue files a compilation, not somebody
            // to go and dig into.
            guard let artist, ArtistName.isRealArtist(artist) else { continue }
            let mbid = item.recording.flatMap { engine.metadata(for: $0.id)?.artistMBID }
                ?? (item.providerID == "dig.artist.mbid" ? item.showID : nil)
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
            guard let name = display[key], ArtistName.isRealArtist(name) else { continue }
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
