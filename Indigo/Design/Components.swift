//
//  Components.swift
//  Indigo
//
//  Small, square, hairline-ruled building blocks shared across the app.
//

import SwiftUI

// MARK: - Rules

struct Rule: View {
    var color: Color = Palette.rule
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: Metrics.hairline)
            .accessibilityHidden(true)
    }
}

struct VRule: View {
    var color: Color = Palette.rule
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: Metrics.hairline)
            .accessibilityHidden(true)
    }
}

// MARK: - Labels

struct MicroLabel: View {
    let text: String
    var color: Color = Palette.inkFaint
    var body: some View {
        Text(text)
            .microLabel()
            .foregroundStyle(color)
    }
}

/// Bordered uppercase pill used for genres, moods and formats.
struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .microLabel(1.1, size: 9)
            .foregroundStyle(Palette.inkMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }
}

/// Blinking red dot plus "LIVE".
struct LiveBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                Circle()
                    .fill(Palette.live)
                    .frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.25)
            }
            if !compact {
                Text("Live")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.live)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live")
    }
}

// MARK: - Marquee

/// Single-line text that scrolls horizontally only when it overflows.
struct MarqueeText: View {
    let text: String
    var font: Font = Typeface.body(13, weight: .semibold)
    var speed: CGFloat = 26
    var gap: CGFloat = 44

    @State private var textWidth: CGFloat = 0

    var body: some View {
        Text(" ")
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let overflow = textWidth > geo.size.width + 1
                    Group {
                        if overflow {
                            let period = Double((textWidth + gap) / speed)
                            TimelineView(.animation) { context in
                                let t = context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: period)
                                HStack(spacing: gap) {
                                    label
                                    label
                                }
                                .offset(x: -CGFloat(t) * speed)
                            }
                        } else {
                            label
                        }
                    }
                    .frame(height: geo.size.height, alignment: .leading)
                }
            }
            .clipped()
            .background(alignment: .leading) { measuringGhost }
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var measuringGhost: some View {
        label
            .hidden()
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: g.size.width) { _, new in textWidth = new }
                }
            }
            .frame(width: 0, height: 0, alignment: .leading)
            .clipped()
    }
}

// MARK: - Buttons

/// Borderless glyph button (previous / next / small utilities).
struct GlyphButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .foregroundStyle(Palette.ink)
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}

/// Solid inverted square — the primary transport action.
struct SolidSquareButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.inverseInk)
            .frame(width: size, height: size)
            .background(Palette.inverse.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

/// Hairline-outlined rectangular button used for actions in body copy.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .microLabel(1.3, size: 10.5)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Palette.wash : Color.clear)
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
    }
}

// MARK: - Search

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    /// Increment from outside (⌘F) to pull focus into the field.
    var focusSignal: Int = 0

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFocused ? Palette.ink : Palette.inkFaint)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.mono(11))
                .foregroundStyle(Palette.ink)
                .focused($isFocused)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .overlay(
            Rectangle().strokeBorder(
                isFocused ? Palette.accent : Palette.outline,
                lineWidth: isFocused ? 1.5 : Metrics.hairline
            )
        )
        // A plain TextField only hit-tests the glyph run it actually occupies —
        // a sliver of the bordered box. Without this the field looks clickable
        // everywhere and focuses almost nowhere.
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .frame(width: 220)
        .onChange(of: focusSignal) { _, _ in isFocused = true }
        #if os(macOS)
        .onExitCommand {
            if text.isEmpty {
                isFocused = false
            } else {
                text = ""
            }
        }
        #endif
    }
}

// MARK: - States

struct EmptyStateView<Actions: View>: View {
    let headline: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Text(headline)
                .microLabel(2.0, size: 11)
                .foregroundStyle(Palette.ink)
            Text(message)
                .font(Typeface.body(12.5))
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            actions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline error strip — never modal, never fatal.
struct NoticeStrip: View {
    let text: String
    var tone: Color = Palette.live
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tone).frame(width: 5, height: 5)
            Text(text)
                .font(Typeface.mono(10.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .background(Palette.wash)
    }
}

// MARK: - Media filtering

/// Provider-neutral multi-select genre picker used by local and saved media.
/// Matching is intentionally inclusive: selecting Ambient and Jazz shows
/// either, which remains useful for files carrying one conventional ID3 tag.
struct GenreFilterBar: View {
    let genres: [String]
    @Binding var selection: Set<String>
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Text("Genres").microLabel(1.5)

                            if selection.isEmpty {
                                Text("All")
                                    .microLabel(0.9)
                                    .foregroundStyle(Palette.inkFaint)
                            } else {
                                Text(selection.count == 1
                                     ? selection.sorted().first ?? "1 selected"
                                     : "\(selection.count) selected")
                                    .microLabel(0.9)
                                    .foregroundStyle(Palette.accent)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 12)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Palette.inkMuted)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse genre filters" : "Expand genre filters")

                    if !selection.isEmpty {
                        VRule()
                        Button("Clear") { selection.removeAll() }
                            .buttonStyle(.plain)
                            .microLabel(1.0)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                    }
                }

                if isExpanded {
                    Rule()
                    ScrollView {
                        WrapLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(genres, id: \.self) { genre in
                                GenreFilterChip(
                                    text: genre,
                                    isSelected: selection.contains(genre)
                                ) {
                                    if selection.contains(genre) { selection.remove(genre) }
                                    else { selection.insert(genre) }
                                }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 12)
                    }
                    .frame(height: drawerHeight)
                    .scrollIndicators(.visible)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(Palette.paperChrome)
            .clipped()
        }
    }

    private var drawerHeight: CGFloat {
        // A bounded drawer preserves the result viewport even for a catalogue
        // with dozens of tags. Short lists do not receive dead space.
        min(176, max(48, CGFloat((genres.count + 4) / 5) * 31 + 18))
    }
}

private struct GenreFilterChip: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .microLabel(1.1, size: 9)
                .foregroundStyle(isSelected ? Palette.inverseInk : Palette.inkMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isSelected ? Palette.inverse : (isHovering ? Palette.wash : Color.clear))
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

nonisolated enum GenreTags {
    static func available<S: Sequence>(in values: S) -> [String] where S.Element == String {
        var display: [String: String] = [:]
        for value in values {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            display[LibraryKey.normalize(clean), default: clean] = clean
        }
        return display.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func matches(_ values: [String], selection: Set<String>) -> Bool {
        guard !selection.isEmpty else { return true }
        let selected = Set(selection.map(LibraryKey.normalize))
        return values.contains { selected.contains(LibraryKey.normalize($0)) }
    }
}

// MARK: - Formatting

nonisolated enum TimeFormat {
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
