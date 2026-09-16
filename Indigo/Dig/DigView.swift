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
        // A search replaces the page rather than filtering it. What is
        // underneath is a list of artists this listener already keeps, and
        // narrowing that would answer a much smaller question than the one
        // somebody typing a name is asking. See `DigSearchView`.
        let isSearching = !appState.searchText.trimmingCharacters(in: .whitespaces).isEmpty

        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(
                title: "Dig",
                subtitle: isSearching
                    ? "Your shelves, Indigo and Discogs"
                    : (entries.isEmpty ? "Follow the music" : "\(entries.count) artists to follow")
            ) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Artists, releases, labels",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)

            if isSearching {
                DigSearchView(query: appState.searchText)
            } else {
                landing(shown, hasSomething: hasSomething)
            }
        }
        .task(id: revision) { await refresh() }
    }

    /// The page as it is when nobody has typed anything: what this listener
    /// has been doing, and the artists worth following out of it.
    @ViewBuilder
    private func landing(_ shown: DigLanding, hasSomething: Bool) -> some View {
        let entries = shown.entries

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

    /// How long the page will stand still for radio, counted from when the
    /// request was made.
    private static let radioPatience = Duration.milliseconds(900)

    /// Local history first, then a moment for radio — and then the page,
    /// whether radio answered or not.
    ///
    /// The request is never cancelled by the deadline; it simply stops being
    /// something the page waits on. A backend having a slow morning must not
    /// be able to hold DIG shut, and a backend answering promptly should not
    /// make the page move twice.
    /// Traced because it was not.
    ///
    /// Every stage of an artist page is in the trace file and none of this
    /// was, so a session reading "the dig page is slow" had nothing in it
    /// about the dig page — the landing path does a whole-table read, a graph
    /// walk and a network wait, and not one of them was a line anybody could
    /// look at. `cold` is the load with nothing kept from last time.
    private func refresh() async {
        await Trace.stage("dig.landing", dig.landing == nil ? "cold" : "warm") {
            await refreshLanding()
        }
    }

    private func refreshLanding() async {
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
            entries = Trace.step("dig.startingPoints") { startingPoints() }
        }

        // Started here rather than after the history below.
        //
        // The two want nothing from each other — radio needs only the names
        // above — and the request used to be made only once the history had
        // finished, so the page paid for a local rebuild and a round trip one
        // after the other. On the cold landing that was 732ms of history and
        // then the whole of the radio wait. Begun here it runs underneath.
        let wantsRadio = crateChanged || radio == nil
        let radioStartedAt = ContinuousClock.now
        let radioLoad: Task<Void, Never>? = wantsRadio
            ? {
                let names = entries.prefix(60).map(\.name)
                return Task { await refreshRadio(for: names) }
            }()
            : nil

        // Always re-read: they have just been somewhere, and where they have
        // been is what this block is.
        await refreshMemory()

        if let radioLoad {
            await Trace.stage("dig.radioGate") {
                // The moment is counted from when the request was made, not
                // from when the page got round to waiting on it — otherwise
                // starting it earlier buys nothing, because the wait simply
                // begins later and runs just as long.
                let spent = ContinuousClock.now - radioStartedAt
                let remaining = Self.radioPatience - spent
                // Whichever lands first, and the other is abandoned rather
                // than awaited.
                //
                // This was a task group racing the load against a sleep, and
                // the deadline it describes above never once applied.
                // `withTaskGroup` does not return until every child has
                // returned; `group.cancelAll()` cancels the children, but a
                // child awaiting an *unstructured* task cannot be cancelled
                // out of that wait — `Task.value` on a non-throwing task is
                // not a cancellation point. So the group went on waiting for
                // the whole request and the page behind it did too. Measured
                // on a cold landing at 1956ms against a 900ms cap, which was
                // 72% of the page.
                //
                // A continuation resumed by whichever finishes first keeps
                // the promise the comment makes: the request is not
                // cancelled, it simply stops being something the page waits
                // on, and it fills `radio` — which is `@State` — whenever it
                // does land.
                await waitForFirst(radioLoad, orAfter: max(.zero, remaining))
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
        await Trace.stage("dig.memory") { await refreshMemoryBody() }
    }

    private func refreshMemoryBody() async {
        let history = DigHistory(context: dig.context)
        recentVisits = history.recent(limit: 4)
        frequentVisits = history.haunts()
        nextSteps = Dictionary(
            recentVisits.compactMap { visit in
                history.usualNextStep(from: visit.node).map { (visit.nodeID, $0.title) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Off the main actor: this one walks the graph, and the other three
        // are indexed fetches. See `DigStore.digSuggestions(limit:)`.
        trySuggestions = await dig.digSuggestions()
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
        // Split in two because they are two different costs: the crate is
        // small and asks the catalogue a question per row, the library is
        // large and asks nothing. One number could not say which was which.
        Trace.step("sp.crate") {
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

        }

        // Counted by the same rule the artist page uses, keyed on the
        // normalised name and displayed with the spelling the files use.
        var library: [String: Int] = [:]
        var display: [String: String] = [:]
        Trace.step("sp.library") {
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

/// Waits for `work` to finish, or for `deadline` to pass — whichever happens
/// first — and abandons the other.
///
/// `work` is deliberately neither cancelled nor awaited past the deadline: it
/// goes on running and writes what it found when it lands. What this bounds is
/// only how long the caller stands still for it.
///
/// Written as a continuation rather than a task group because a group cannot
/// express it. `withTaskGroup` does not return until every child returns, and
/// a child awaiting an unstructured `Task` cannot be cancelled out of that
/// wait — so the obvious spelling silently waits for the slow side every time.
/// See `DigViewRadioGateTests`.
@MainActor
func waitForFirst(_ work: Task<Void, Never>, orAfter deadline: Duration) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let gate = RadioGate(continuation)
        Task { await work.value; gate.open() }
        Task { try? await Task.sleep(for: deadline); gate.open() }
    }
}

/// Resumes once, for whichever of two waits finishes first.
///
/// One-shot because resuming a continuation twice is a crash, and both of the
/// waits in `refreshLanding` are expected to finish — the loser simply arrives
/// after nobody is listening. Main-actor isolated because that is where both
/// of them run and where `radio` is written.
@MainActor
private final class RadioGate {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func open() {
        continuation?.resume()
        continuation = nil
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
