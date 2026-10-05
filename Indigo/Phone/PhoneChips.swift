//
//  PhoneChips.swift
//  Indigo
//
//  Words set in boxes, edge to edge, the way IDA's app sets them: a green box
//  to lead -- a city, a kind -- then dark ones, and now and then the
//  wordmark's moving sheen. A run of boxes wraps onto the next line rather
//  than cutting a long title short, and each line is centred.
//

import SwiftUI

enum ChipTone {
    /// Green, dark words: what the rest is about.
    case lead
    /// Near-black, light words.
    case plain
    /// The wordmark's metal, dark words.
    case sheen
}

struct Chip: View {
    let text: String
    var tone: ChipTone = .plain
    var size: CGFloat = 15
    var uppercase = false

    static let green = Color(red: 0.36, green: 0.49, blue: 0.36)
    static let black = Color(red: 0.11, green: 0.13, blue: 0.12)
    static let ink = Color(red: 0.06, green: 0.1, blue: 0.07)

    var body: some View {
        Text(uppercase ? text.uppercased() : text)
            .font(Typeface.mono(size))
            .tracking(uppercase ? 1.2 : 0.3)
            .foregroundStyle(tone == .plain ? Color.white.opacity(0.92) : Self.ink)
            .padding(.horizontal, size * 0.75)
            .padding(.vertical, size * 0.5)
            .background { background }
    }

    @ViewBuilder
    private var background: some View {
        switch tone {
        case .lead: Self.green
        case .plain: Self.black
        case .sheen: MineralSheenSurface()
        }
    }
}

/// What comes on next, on one line however long its title: [NEXT UP], the
/// title cut short if it must be, and the time, which never drops to a line
/// of its own.
struct NextUpStrip: View {
    let title: String
    let time: String?

    var body: some View {
        HStack(spacing: 0) {
            Chip(text: "Next up", size: 13, uppercase: true)
                .fixedSize()
            Text(title)
                .font(Typeface.mono(13))
                .tracking(0.3)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(Chip.black)
                .layoutPriority(-1)
            if let time {
                Chip(text: time, tone: .sheen, size: 13)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Boxes laid edge to edge, wrapped onto further lines, each line centred.
struct ChipFlow: Layout {
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            // A box wider than the line is given the line, and wraps its words.
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !line.indices.isEmpty, line.width + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.indices.append(index)
            line.width += size.width
            line.height = max(line.height, size.height)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
