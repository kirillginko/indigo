//
//  DeepSectionView.swift
//  Indigo
//
//  ↓ DEEPER, as a place on the page.
//
//  A descent, and the trail behind you stays put. Pressing DEEPER used to
//  replace the list with the next level's rows, so going deeper took away
//  what you had — and when a level held one record, a screen of finds became
//  a single line. Levels accumulate now: the button adds the next one under
//  the last, and what you have already been shown is never taken back.
//
//  The level is still named and numbered, because that is the whole
//  proposition — you are being told how far from the surface you have got,
//  and what is being withheld to keep you there.
//
//  No score is ever printed. Obscurity ranks the list; it does not label the
//  records in it.
//

import SwiftUI

struct DeepSectionView: View {
    let origin: MusicNode
    /// Whether the page has finished asking the catalogues. Until it has, an
    /// empty level is a level nobody has looked at yet — and saying "nothing
    /// at this depth" about it is a failure announced in advance.
    var isReady = true
    /// The first level, worked out by the page while it loaded.
    ///
    /// This section lives at the bottom of every page, so without it the walk
    /// happened at the moment somebody scrolled down to it — which is exactly
    /// when it must not. Lazy sections should render on appear, not compute.
    var initial: DeepEngine.Descent?
    /// What the page has already drawn above, by node id.
    ///
    /// DEEP is the graph with the obvious answers taken away, and the most
    /// obvious answer of all is the one printed six inches higher up the same
    /// page. Without this a release's descent opened on its own label and its
    /// own catalogue number. See `DeepEngine.results(from:distance:showing:)`.
    var showing: Set<String> = []
    let open: (DetailPage) -> Void

    @Environment(DigStore.self) private var dig
    // Each page gets a fresh view, so these start over on their own — see
    // the `.id(detail)` in RootView.
    /// The levels on the page, shallowest first. Pressing DEEPER appends;
    /// nothing here is ever replaced.
    @State private var reached: [DeepEngine.Descent] = []
    /// The level a walk is being awaited for, so the button can say so rather
    /// than appearing to have done nothing.
    @State private var pending: DeepLevel?

    /// The deepest level shown, which is what the section is headed with.
    private var level: DeepLevel { reached.last?.level ?? .surface }

    var body: some View {
        DigSection(title: "Deep", trailing: "\(level.rawValue) / \(level.title)") {
            VStack(alignment: .leading, spacing: 0) {
                let shown = reached.isEmpty ? [initial].compactMap { $0 } : reached
                if shown.isEmpty {
                    // DEEP is computed after the page around it has settled,
                    // so this is the last thing still arriving on an otherwise
                    // finished page. Veiled, so it reads as the same one thing
                    // happening rather than a second, different kind of wait.
                    DigSkeleton(hasImage: false, sections: 0)
                        .padding(.vertical, 14)
                        .loadingVeil(true)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.level) { index, descent in
                        // The first level's caption sits under the section
                        // heading, where a caption belongs. Every level after
                        // it needs naming where it starts, or the rows read as
                        // one undifferentiated list that happens to get more
                        // obscure.
                        levelHeading(descent.level, isFirst: index == 0)
                        if descent.results.isEmpty {
                            Text(emptyMessage(descent.level))
                                .font(Typeface.body(12))
                                .foregroundStyle(Palette.inkMuted)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(descent.results) { result in
                                DeepRow(result: result) {
                                    if let page = result.node.destination { open(page) }
                                }
                                Rule()
                            }
                        }
                    }
                    if let last = shown.last { controls(last) }
                }
            }
        }
        // Walked once when the page changes or a write lands, never during a
        // redraw. Descending the graph reads most of the store, and doing that
        // on every hover is what made opening an artist page crawl.
        //
        // A write re-walks every level already on the page rather than
        // dropping back to the first: somebody who has pressed DEEPER three
        // times should not be sent back to the top because a sleeve arrived.
        .task(id: TaskKey(origin: origin.id, revision: dig.revision)) {
            // Not until the page it belongs to has loaded, and not on every
            // write while it does. This walks the graph from a cache of its
            // own, and it is the last thing on the page — there is nothing to
            // be gained by doing it while somebody is waiting for the record.
            guard isReady else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    /// The identity a descent is recomputed for. Spelled out so a redraw that
    /// changes none of these does not trigger another walk. Deliberately not
    /// the level: descending adds one, and re-walking the whole section every
    /// time somebody presses DEEPER would throw away the levels above it.
    private struct TaskKey: Hashable {
        let origin: String
        let revision: Int
    }

    /// Walks the first level, or walks again every level already reached.
    private func reload() async {
        guard !reached.isEmpty else {
            let found = await dig.descent(from: origin, at: .surface, showing: showing)
            reached = [found]
            return
        }
        var rebuilt: [DeepEngine.Descent] = []
        for descent in reached {
            let found = await dig.descent(from: origin, at: descent.level, showing: showing)
            // A level that has emptied since it was drawn settles onto a
            // deeper one, which may be a level already below it. Kept unique
            // so a rebuild cannot print the same rows twice.
            guard !rebuilt.contains(where: { $0.level == found.level }) else { continue }
            rebuilt.append(found)
        }
        reached = rebuilt
    }

    /// Adds the next level with something in it, under the ones already shown.
    private func descend(to next: DeepLevel) async {
        pending = next
        let found = await dig.descent(from: origin, at: next, showing: showing)
        pending = nil
        guard !reached.contains(where: { $0.level == found.level }) else { return }
        reached.append(found)
    }

    /// The name of a level, where its rows begin.
    @ViewBuilder
    private func levelHeading(_ level: DeepLevel, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !isFirst {
                Text("\(level.rawValue) / \(level.title)")
                    .microLabel(1.4, size: 9)
                    .foregroundStyle(Palette.ink)
            }
            Text(level.caption)
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
        }
        .padding(.top, isFirst ? 0 : 22)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func controls(_ descent: DeepEngine.Descent) -> some View {
        HStack(spacing: 10) {
            if let next = descent.next {
                Button {
                    Task { await descend(to: next) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        // Named, so the button says what it will add rather
                        // than only that there is more. Pressing something
                        // called "Deeper" and receiving one record reads as a
                        // failure; being told it is going to UNKNOWN and
                        // receiving one white label is the find.
                        Text(pending == nil ? "Deeper · \(next.title)" : "Reading…")
                            .microLabel(1.4, size: 9.5)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pending != nil)
            } else if isReady {
                // Saying so is better than a button that does nothing — but
                // only once there is something to have reached the bottom of.
                // Announced before the page had loaded it read as a verdict
                // on an empty page.
                Text("Bottom of the dig")
                    .microLabel(1.2, size: 9)
                    .foregroundStyle(Palette.inkFaint)
            }

            // Nothing is taken away by descending, so the way back is to
            // fold the last level away again rather than to move between
            // them. Only offered once there is a level that was added.
            if reached.count > 1 {
                Button("Back up") { reached.removeLast() }
                    .buttonStyle(.plain)
                    .microLabel(1.0)
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private func emptyMessage(_ level: DeepLevel) -> String {
        switch level {
        case .unknown:
            "Nothing unidentified here yet. Unknown recordings appear once Indigo has heard something it can't name."
        default:
            "Nothing at this depth."
        }
    }
}

/// One result. Shows what it is, why it is here, and how much to believe it —
/// never how obscure it scored.
private struct DeepRow: View {
    let result: DeepResult
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        let content = HStack(alignment: .top, spacing: 12) {
            Text(result.node.kind.label)
                .font(Typeface.mono(8.5))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 76, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.node.title)
                    .font(Typeface.body(12.5, weight: .medium))
                    .foregroundStyle(isOpenable && isHovering ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                if let why = result.why {
                    Text(why.summary())
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ConfidenceMark(band: result.band)
                .padding(.top, 3)

            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isOpenable ? (isHovering ? Palette.accent : Palette.inkFaint)
                                            : Palette.inkFaint.opacity(0.25))
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        if isOpenable {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
        } else {
            // A style, a scene or an unnamed recording has no page yet. It is
            // still worth showing — it is the find — so it renders as a fact
            // rather than as a broken link.
            content
        }
    }

    private var isOpenable: Bool { result.node.destination != nil }
}
