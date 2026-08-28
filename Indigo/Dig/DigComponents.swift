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

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: open) {
                    Text(artist.name)
                        .font(Typeface.body(12.5, weight: .medium))
                        .foregroundStyle(isHovering ? Palette.accent : Palette.ink)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Hide" : "Why?")
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inkFaint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Why this connection?")
            }
            .padding(.vertical, 5)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why this connection?")
                        .microLabel(1.4, size: 9)
                        .foregroundStyle(Palette.inkFaint)
                        .padding(.bottom, 2)
                    ForEach(artist.reasons) { reason in
                        HStack(spacing: 7) {
                            Rectangle()
                                .fill(Palette.accent)
                                .frame(width: 3, height: 3)
                            Text(reason.detail)
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkMuted)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 2)
                .padding(.bottom, 8)
            }
        }
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
