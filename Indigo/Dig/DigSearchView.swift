//
//  DigSearchView.swift
//  Indigo
//
//  What DIG shows once somebody types.
//
//  The landing page answers "where should I go tonight"; this answers "what do
//  you have on X", which is a different question and wants a different page.
//  It replaces the landing page rather than sitting beside it — a search field
//  with results in a drawer underneath the thing you were reading is two pages
//  fighting over one screen.
//
//  Three sources, drawn in one list, each row saying where it came from. The
//  local ones arrive in a frame and the networked ones fill in underneath, so
//  the list grows downwards while somebody is still reading the top of it and
//  nothing already on screen moves.
//

import SwiftUI

struct DigSearchView: View {
    let query: String

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    @State private var scope: DigSearchScope = .all
    @State private var results = DigSearchResults.none
    /// The query `results` actually answers. Kept so a stale answer is never
    /// drawn under a newer query — the local leg returns in a frame and the
    /// networked one in a second, and somebody typing fast outruns both.
    @State private var answered = ""
    @State private var isLooking = false

    /// Long enough that typing a name is one round of searches rather than
    /// four, short enough that stopping feels like an answer rather than a
    /// wait.
    ///
    /// Every round costs three Discogs requests out of sixty a minute, so this
    /// is a budget decision as much as a feel one. At 220ms a typed word was
    /// several rounds, and a couple of searches could spend the minute between
    /// them — see `DiscogsBudget`.
    private static let settle = Duration.milliseconds(400)

    var body: some View {
        // Last answer stays on screen while a newer one is worked out.
        // Blanking the list on every keystroke means somebody refining a name
        // watches their results vanish and come back for each letter, and for
        // the moment in between the page says there is nothing — which is a
        // failure announced before anybody has looked.
        let settled = answered == RecordingKey.normalize(query)
        let rows = results.merged(scope: scope)

        VStack(spacing: 0) {
            HStack {
                SegmentedTabs(
                    options: DigSearchScope.allCases.map { ($0, $0.title) },
                    selection: $scope
                )
                Spacer()
                if isLooking {
                    Text("Looking")
                        .microLabel(1.4)
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 14)
            .padding(.bottom, 14)

            Rule(color: Palette.outline)

            // Said plainly, above the results, whenever part of the answer is
            // missing for a reason that is nobody's fault and will pass.
            if results.discogsRefused {
                NoticeStrip(
                    text: "Discogs is busy — showing what Indigo already holds.",
                    tone: Palette.inkFaint
                )
                Rule()
            }

            content(rows: rows, settled: settled)
        }
        .task(id: query) { await look() }
    }

    @ViewBuilder
    private func content(rows: [DigSearchResult], settled: Bool) -> some View {
        if !DigSearchIndex.isSearchable(query) {
            EmptyStateView(
                headline: "Search everything Dig can reach",
                message: "An artist, a record, or a label — your own shelves first, then Indigo's catalogue and Discogs."
            ) { EmptyView() }
        } else if rows.isEmpty && (!settled || isLooking) {
            LoadingPane(label: "Searching")
        } else if rows.isEmpty, results.discogsRefused {
            // The one thing this page must never say is that a record does not
            // exist because the catalogue holding it declined to answer.
            EmptyStateView(
                headline: "Discogs is busy",
                message: "It allows sixty requests a minute and Indigo has just spent them. Nothing here holds “\(query)” either — try again in a moment."
            ) {
                Button("Try Again") { Task { await look() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if rows.isEmpty {
            EmptyStateView(
                headline: "Nothing under that name",
                message: emptyMessage
            ) {
                if scope != .all {
                    Button("Search everything") { scope = .all }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        DigSearchRow(result: row) { appState.open(row.destination) }
                        Rule()
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.visible)
        }
    }

    private var emptyMessage: String {
        let where_ = scope == .all ? "" : " under \(scope.title.lowercased())"
        return "Nothing in your library, Indigo's catalogue or Discogs answers to “\(query)”\(where_)."
    }

    /// Local first, then the two that need the network.
    ///
    /// Both halves are written into the same `results`, so the page never
    /// clears: what this machine holds is drawn immediately and stays put
    /// while Discogs is still answering. A cancelled task — somebody typed
    /// another letter — writes nothing at all.
    private func look() async {
        let key = RecordingKey.normalize(query)
        guard DigSearchIndex.isSearchable(query) else {
            results = .none
            answered = key
            isLooking = false
            return
        }

        // Said before the pause rather than after it, so the page admits it
        // is working the moment a key goes down.
        isLooking = true
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }

        let yours = await dig.searchYours(query)
        guard !Task.isCancelled else { return }
        results = DigSearchResults(yours: yours, catalogue: [], discogs: [])
        answered = key

        let elsewhere = await dig.searchElsewhere(query)
        guard !Task.isCancelled else { return }
        results = DigSearchResults(
            yours: yours,
            catalogue: elsewhere.catalogue,
            discogs: elsewhere.discogs,
            discogsRefused: elsewhere.discogsRefused
        )
        isLooking = false
    }
}

// MARK: - Row

private struct DigSearchRow: View {
    let result: DigSearchResult
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ArtworkView(
                    remoteURL: result.artworkURL,
                    side: 40,
                    placeholder: .glyph,
                    showsGround: result.artworkURL != nil
                )
                .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(result.kind.label)
                            .microLabel(1.1, size: 8.5)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(result.origin == .yours ? Palette.accent : Palette.inverse)

                        Text(result.title)
                            .font(Typeface.body(12.5, weight: .semibold))
                            .lineLimit(1)
                    }

                    if let detail = result.detail {
                        Text(detail)
                            .font(Typeface.body(11.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                // Where the row came from, said plainly. A name Indigo already
                // holds is a different offer from one Discogs has and nobody
                // here has ever opened, and the row should not pretend
                // otherwise.
                Text(result.origin.label)
                    .microLabel(0.9)
                    .foregroundStyle(Palette.inkFaint)

                Image(systemName: "arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint.opacity(0.5))
                    .frame(width: 12)
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: 58)
            .background(isHovering ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
