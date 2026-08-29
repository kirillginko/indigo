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

/// The spec is explicit: never an opaque recommendation. Every related entry
/// can be expanded to show exactly what the connection rests on.
struct ConnectionExplainer: View {
    let artist: RelatedArtist
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle()
                    .fill(isHovering ? Palette.accent : Palette.outline)
                    .frame(width: 3, height: 30)
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

    private var connectionLine: String {
        let details = artist.reasons.prefix(3).map(\.detail)
        return details.isEmpty ? "Connected artist" : details.joined(separator: " · ")
    }
}

struct DigReleaseRow: View {
    let release: ArtistProfile.ReleaseLine
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ArtworkView(remoteURL: release.imageURL, side: 54, glyphScale: 0.23)
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
                    remoteURL: release.imageURL,
                    previewRemoteURL: release.thumbnailURL,
                    glyphScale: 0.22
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
