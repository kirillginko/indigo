//
//  StatusVocabulary.swift
//  Indigo
//
//  The spec's status vocabulary, in one place so it stays a vocabulary rather
//  than becoming eight slightly different chips:
//
//      NTS/1   LIVE   MATCH ✓   LOCAL   FLAC   44.1/24   UNKNOWN   CRATED
//
//  Hard rectangles, uppercase mono, restrained colour. Tone carries meaning:
//  red is on-air, accent is a confirmed identity, faint is a plain fact.
//

import AVFoundation
import SwiftUI

enum StatusTone: Hashable {
    /// A plain technical fact — format, sample rate, source.
    case neutral
    /// On air.
    case live
    /// A confirmed identity.
    case affirmed
    /// Present but unresolved.
    case pending

    var foreground: Color {
        switch self {
        case .neutral: Palette.inkMuted
        case .live: Palette.live
        case .affirmed: Palette.accent
        case .pending: Palette.inkFaint
        }
    }

    var border: Color {
        switch self {
        case .neutral, .pending: Palette.outline
        case .live: Palette.live.opacity(0.55)
        case .affirmed: Palette.accent.opacity(0.55)
        }
    }
}

struct StatusItem: Identifiable, Hashable {
    let text: String
    let tone: StatusTone
    var id: String { "\(text)|\(tone)" }

    init(_ text: String, _ tone: StatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

/// One hard-edged chip. Deliberately not a pill — the whole app is square.
struct StatusChip: View {
    let item: StatusItem
    var size: CGFloat = 9

    var body: some View {
        Text(item.text)
            .microLabel(1.2, size: size)
            .foregroundStyle(item.tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(Rectangle().strokeBorder(item.tone.border, lineWidth: Metrics.hairline))
            .fixedSize()
            .accessibilityElement()
            .accessibilityLabel(item.text)
    }
}

struct StatusRow: View {
    let items: [StatusItem]
    var size: CGFloat = 9

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items) { StatusChip(item: $0, size: size) }
        }
    }
}

// MARK: - Format

/// Reads a local file's technical detail for the "LOCAL / FLAC 44.1/24" line.
/// Opening a file header is cheap, but doing it every render is not, so the
/// answers are kept.
/// Main-actor by design: these are view labels, and the only caller is a view.
final class AudioFormatProbe {
    static let shared = AudioFormatProbe()

    private var cache: [String: [StatusItem]] = [:]

    /// "FLAC", "44.1/24" — container first, then rate and depth when the file
    /// actually reports them.
    func chips(forPath path: String) -> [StatusItem] {
        if let cached = cache[path] { return cached }

        let url = URL(fileURLWithPath: path)
        var items: [StatusItem] = []
        let container = url.pathExtension.uppercased()
        if !container.isEmpty { items.append(StatusItem(container)) }

        if let file = try? AVAudioFile(forReading: url) {
            let format = file.fileFormat
            let rate = format.sampleRate / 1000
            let rateText = rate == rate.rounded()
                ? String(format: "%.0f", rate)
                : String(format: "%.1f", rate)
            // Bit depth is only meaningful where the container reports one;
            // a lossy file has no honest answer, so it doesn't get a number.
            if let depth = format.settings[AVLinearPCMBitDepthKey] as? Int, depth > 0 {
                items.append(StatusItem("\(rateText)/\(depth)"))
            } else {
                items.append(StatusItem(rateText))
            }
        }

        cache[path] = items
        return items
    }
}
