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
/// The genre filter, everywhere.
///
/// One shape for every station: a header you open, and the tags inside it.
/// Some stations used to hide theirs behind a menu and others spent a third of
/// the page on it, which made the same control feel like three different
/// controls depending on where you had navigated from.
///
/// Closed by default, because the shows are what the page is for. Selection
/// never changes the accordion state; only its disclosure button does.
struct GenreFilterBar: View {
    let groups: [GenreFilterGroup]
    @Binding var selection: Set<String>

    @State private var isExpanded = false
    @State private var isHovering = false

    init(genres: [String], selection: Binding<Set<String>>) {
        groups = genres.isEmpty ? [] : [GenreFilterGroup(name: nil, genres: genres)]
        _selection = selection
    }

    /// For stations that publish their tags in named groups.
    init(groups: [GenreFilterGroup], selection: Binding<Set<String>>) {
        self.groups = groups.filter { !$0.genres.isEmpty }
        _selection = selection
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 9) {
                            Text("Genres").microLabel(1.5)

                            Text(selection.isEmpty ? "All" : "\(selection.count) selected")
                                .microLabel(0.9)
                                .foregroundStyle(selection.isEmpty ? Palette.inkFaint : Palette.accent)

                            Spacer(minLength: 12)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(isHovering ? Palette.accent : Palette.inkFaint)
                                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
                    .accessibilityLabel(isExpanded ? "Hide genres" : "Show genres")

                    if !selection.isEmpty {
                        VRule().frame(height: 38)
                        Button("Clear") { selection.removeAll() }
                            .buttonStyle(.plain)
                            .microLabel(1.0)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                    }
                }
                .frame(height: 38)

                if isExpanded {
                    Rule()
                    // Capped and scrollable. A station with a couple of
                    // hundred tags was pushing every show off the screen,
                    // which turns a filter into a wall — and the shows are
                    // what the page is for. Short lists still size to their
                    // own content and never scroll.
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                if let name = group.name {
                                    Text(name)
                                        .microLabel(1.4, size: 8.5)
                                        .foregroundStyle(Palette.inkFaint)
                                }
                                FlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(group.genres, id: \.self) { genre in
                                        GenreFilterChip(
                                            text: genre,
                                            isSelected: selection.contains(genre)
                                        ) {
                                            if selection.contains(genre) {
                                                selection.remove(genre)
                                            } else {
                                                selection.insert(genre)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .background(Palette.paperChrome)
        }
    }
}

/// A named set of tags, for stations that publish theirs grouped.
nonisolated struct GenreFilterGroup: Identifiable, Hashable, Sendable {
    let name: String?
    let genres: [String]
    var id: String { name ?? "all" }
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

// MARK: - Tiles

/// The one useful thing to say about a broadcast at a glance: how many tracks
/// were logged in it, or failing that what it sounds like. Every station's
/// grid says it in the same corner, so a listener learns to read it once —
/// and a station that publishes neither says nothing rather than filling the
/// space with something it happens to know, like a duration or a format.
nonisolated enum BroadcastBadge {
    static func text(tracks: Int, genres: [String]) -> String? {
        if tracks > 0 { return tracks == 1 ? "1 track" : "\(tracks) tracks" }
        return genres.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
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

nonisolated extension String {
    /// Nil rather than an empty string, so an absent value can be dropped from
    /// a joined line instead of leaving a stray separator behind.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Lays subviews left to right, wrapping when the line runs out, each at its
/// own natural width.
///
/// A grid cannot do this. `LazyVGrid(.adaptive:)` gives every column the same
/// width, so "PUNK" gets as much room as "PSYCHEDELIC ROCK" and the long ones
/// break mid-word anyway — which is exactly what a row of tags must not do.
/// Tags are words, and words are the width they are.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, within: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A row of tags, each the width of its own word.
struct TagFlow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(tags, id: \.self) { tag in
                TagChip(text: tag)
            }
        }
    }
}

nonisolated extension Array {
    /// Fixed-size batches. Used to keep a burst of network work to a size a
    /// service will actually accept.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Work in progress, without words.
///
/// A sweeping bar rather than a spinner: it belongs to the same drawing as
/// the rules and the progress track, and it says the one thing a label was
/// being used to say. Text asks to be read; this doesn't.
///
/// Animated by Core Animation rather than by `TimelineView`.
///
/// A timeline on the `.animation` schedule asks SwiftUI to re-evaluate this
/// view every single frame for as long as it is on screen — main-thread work
/// competing with a scroll. A repeating animation on one offset is handed to
/// the render server and costs the main thread nothing once started.
struct WorkingBar: View {
    var width: CGFloat = 120
    /// One sweep, in seconds.
    var period: Double = 1.1

    @State private var sweeping = false

    var body: some View {
        let travel = width * 0.72
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Palette.outline)
                .frame(width: width, height: Metrics.hairline)
            Rectangle()
                .fill(Palette.ink)
                .frame(width: width * 0.28, height: 2)
                .offset(x: sweeping ? travel : 0)
        }
        .frame(width: width, height: 2, alignment: .leading)
        // Started explicitly, a beat after the view exists.
        //
        // An implicit `.animation(value:)` driven from `onAppear` sets the
        // value in the same pass that creates the view, and SwiftUI has
        // nothing to animate from — so the bar simply sat still, which reads
        // as the app being stuck rather than busy.
        .task {
            guard !sweeping else { return }
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                sweeping = true
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// The whole-pane version, for a page that has nothing to show yet.
struct WorkingPane: View {
    var body: some View {
        WorkingBar()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 60)
    }
}
