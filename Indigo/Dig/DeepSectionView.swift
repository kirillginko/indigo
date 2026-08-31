//
//  DeepSectionView.swift
//  Indigo
//
//  ↓ DEEPER, as a place on the page.
//
//  The control is deliberately one-way-ish and stateful: DEEP is a descent,
//  not a filter dropdown. The level is named and numbered because that is the
//  whole proposition — you are being told how far from the surface you have
//  got, and what is being withheld to keep you there.
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
    let open: (DetailPage) -> Void

    @Environment(DigStore.self) private var dig
    // Each page gets a fresh view, so these start over on their own — see
    // the `.id(detail)` in RootView.
    @State private var level: DeepLevel = .surface
    @State private var descent: DeepEngine.Descent?

    var body: some View {
        DigSection(title: "Deep", trailing: "\(level.rawValue) / \(level.title)") {
            VStack(alignment: .leading, spacing: 0) {
                Text(level.caption)
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(Palette.inkFaint)
                    .padding(.bottom, 12)

                if let descent = descent ?? dig.cachedDescent(from: origin, at: level) {
                    if descent.results.isEmpty, self.descent == nil || !isReady {
                        // A cached descent for a different level is not an
                        // answer about this one, and neither is an empty walk
                        // over a store nothing has been fetched into yet.
                        WorkingBar().padding(.vertical, 14)
                    } else if descent.results.isEmpty {
                        Text(emptyMessage)
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
                    controls(descent)
                } else {
                    WorkingBar()
                        .padding(.vertical, 14)
                }
            }
        }
        // Walked once when the page or the level changes, never during a
        // redraw. Descending the graph reads most of the store, and doing
        // that on every hover is what made opening an artist page crawl.
        .task(id: TaskKey(origin: origin.id, level: level, revision: dig.revision)) {
            descent = dig.descent(from: origin, at: level)
        }
    }

    /// The identity a descent is recomputed for. Spelled out so a redraw that
    /// changes none of these does not trigger another walk.
    private struct TaskKey: Hashable {
        let origin: String
        let level: DeepLevel
        let revision: Int
    }

    @ViewBuilder
    private func controls(_ descent: DeepEngine.Descent) -> some View {
        HStack(spacing: 10) {
            if let next = descent.next {
                Button {
                    level = next
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        Text("Deeper").microLabel(1.4, size: 9.5)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Saying so is better than a button that does nothing.
                Text("Bottom of the dig")
                    .microLabel(1.2, size: 9)
                    .foregroundStyle(Palette.inkFaint)
            }

            if level != .surface {
                Button("Back up") { level = level.shallower ?? .surface }
                    .buttonStyle(.plain)
                    .microLabel(1.0)
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private var emptyMessage: String {
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
