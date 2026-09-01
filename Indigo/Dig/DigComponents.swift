//
//  DigComponents.swift
//  Indigo
//
//  Shared furniture for the DIG pages: the labelled column blocks the spec
//  lays out, and the connection explainer that replaces "you may also like".
//

import SwiftUI

/// A titled block of lines — the "RELEASES / LABELS / RELATED" columns.
struct DigSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .microLabel(1.8)
                    .foregroundStyle(Palette.inkFaint)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .microLabel(1.2)
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.bottom, 9)
            Rule(color: Palette.outline)
            content
                .padding(.top, 9)
        }
    }
}

/// A navigable line inside a DIG section.
struct DigLine: View {
    let text: String
    var detail: String?
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        let row = HStack(spacing: 10) {
            Text(text)
                .font(Typeface.body(12.5, weight: action == nil ? .regular : .medium))
                .foregroundStyle(action == nil ? Palette.ink : (isHovering ? Palette.accent : Palette.ink))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
            }
            if action != nil {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
        } else {
            row
        }
    }
}

/// Dense navigable names use the width of the page instead of turning one
/// half-column into a very long list. Short collections should keep `DigLine`;
/// this is for labels, aliases and other catalogue-sized sets.
struct DigLinkGrid: View {
    let items: [String]
    let open: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                DigLine(text: item) { open(item) }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 38)
                    .overlay(
                        Rectangle().strokeBorder(
                            Palette.outline,
                            lineWidth: Metrics.hairline
                        )
                    )
            }
        }
        .padding(.top, 4)
    }
}

/// The spec is explicit: never an opaque recommendation. Every related entry
/// can be expanded to show exactly what the connection rests on.
struct ConnectionExplainer: View {
    let artist: RelatedArtist
    /// Resolved by the page from `DigStore.portraits`, so a picture found in
    /// the background reaches this row without anything being rebuilt.
    var portrait: URL?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 11) {
                Rectangle()
                    .fill(isHovering ? Palette.accent : Palette.outline)
                    .frame(width: 3, height: 38)
                ArtworkView(remoteURL: artist.imageURL ?? portrait, side: 38, glyphScale: 0.3)
                    .overlay(Rectangle().strokeBorder(
                        isHovering ? Palette.accent : Palette.outline, lineWidth: Metrics.hairline
                    ))
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(Typeface.body(12.5, weight: .medium))
                        .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                        .lineLimit(1)
                    Text(connectionLine)
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let why {
                    ConfidenceMark(band: why.confidence)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint(connectionLine)
    }

    private var why: WhyThis? { WhyThis(reasons: artist.reasons) }

    /// Strongest evidence first. The order used to be whatever the builder
    /// happened to append in, so a row could lead with "catalogues overlap in
    /// the 2010s" while the shared label sat behind it.
    private var connectionLine: String {
        why?.summary(limit: 3) ?? "Connected artist"
    }
}

struct DigReleaseRow: View {
    let release: ArtistProfile.ReleaseLine
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ArtworkView(remoteURL: release.coverURL,
                            previewRemoteURL: release.previewURL,
                            side: 54, glyphScale: 0.23,
                            placeholder: .whiteLabel)
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                VStack(alignment: .leading, spacing: 4) {
                    Text(release.title)
                        .font(Typeface.body(12.5, weight: .medium))
                        .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                        .lineLimit(2)
                    Text([release.label, release.year].compactMap { $0 }.joined(separator: " · "))
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A sleeve-first release link. The intentionally square, tightly captioned
/// tile borrows the physical rhythm of browsing a record bin.
struct DigReleaseTile: View {
    let release: ArtistProfile.ReleaseLine
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(
                    remoteURL: release.coverURL,
                    previewRemoteURL: release.previewURL,
                    glyphScale: 0.22,
                    placeholder: .whiteLabel
                )
                    .overlay {
                        Rectangle().strokeBorder(
                            isHovering ? Palette.accent : Palette.outline,
                            lineWidth: isHovering ? 2 : Metrics.hairline
                        )
                    }
                Text(release.title)
                    .font(Typeface.body(12.5, weight: .medium))
                    .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                Text([release.label, release.year].compactMap { $0 }.joined(separator: " · "))
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint(release.discogsID == nil ? "Find and open release" : "Open release")
    }
}

/// "DIG →"
struct DigButton: View {
    var large = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("Dig").microLabel(1.4, size: large ? 11 : 9.5)
                Image(systemName: "arrow.right")
                    .font(.system(size: large ? 9 : 8, weight: .bold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, large ? 18 : 11)
            .padding(.vertical, large ? 11 : 7)
            .background(isHovering ? Palette.wash : Color.clear)
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Counts of the listener's own relationship to something — the block that
/// distinguishes DIG from a catalogue browser.
struct DigTallies: View {
    let entries: [(label: String, value: String)]

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(entries, id: \.label) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.label)
                        .microLabel(1.4, size: 9)
                        .foregroundStyle(Palette.inkFaint)
                    Text(entry.value)
                        .font(Typeface.body(15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            Spacer(minLength: 0)
        }
    }
}


/// How much of a connection to believe, as a band rather than a number —
/// a percentage would imply a precision none of these sources have.
///
/// The mark is three ticks with the unearned ones left hollow, so the answer
/// reads at a glance down a column without the row having to spend its width
/// on a word.
struct ConfidenceMark: View {
    let band: RelationshipConfidence

    private var filled: Int {
        switch band {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? Palette.ink : Palette.outline)
                    .frame(width: 3, height: 9)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Confidence \(band.label.lowercased())")
        .help("Confidence: \(band.label)")
    }
}

/// A catalogue number, set as a shelf label is: monospaced, boxed, and
/// clickable, because the number is the object rather than a note about one.
struct CatalogChip: View {
    let number: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(number.uppercased())
                .font(Typeface.mono(10))
                .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().strokeBorder(
                    isHovering ? Palette.accent : Palette.outline, lineWidth: Metrics.hairline
                ))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One playable recording, with the two things you can do with it.
///
/// The keep button sits beside the play button rather than inside it: a row
/// that starts playing because you tried to keep it is the kind of small
/// betrayal that makes people stop trusting a list.
struct ListenRow: View {
    let title: String
    var duration: String?
    /// Named only where it changes what the row is. A track is a track; which
    /// service happens to be carrying it is not the interesting part.
    var provider: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let isCrated: Bool
    let play: () -> Void
    let keep: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isCurrent ? Palette.accent
                                         : (isHovering ? Palette.ink : Palette.inkFaint))
                        .frame(width: 16)

                    Text(title)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let duration {
                        Text(duration)
                            .font(Typeface.mono(9.5))
                            .foregroundStyle(Palette.inkFaint)
                    }
                    if let provider {
                        Text(provider)
                            .microLabel(1.1, size: 8)
                            .foregroundStyle(Palette.inkFaint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            CrateGlyphButton(isCrated: isCrated, action: keep)
        }
        .padding(.vertical, 8)
    }
}

/// The shape of a page that has not arrived yet.
///
/// An empty pane with a bar in the middle tells the listener nothing about
/// where they are or what is coming. Drawing the page's own furniture — the
/// sleeve, the tallies, a run of tiles — says "this is an artist, their
/// records are on their way", and means nothing jumps when the real thing
/// lands in the same shape.
