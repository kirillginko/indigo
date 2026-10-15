//
//  RecommendationCardView.swift
//  Indigo
//
//  One "Hear next" card: who, the record that connects them, why, and the
//  first thing to put on. On the phone in IDA's boxes, on the Mac as a row.
//

import SwiftUI

struct RecommendationCardView: View {
    let card: DigRecommendation
    let open: () -> Void
    let listen: () -> Void
    @Environment(\.isPhoneLayout) private var isPhone

    private var record: String? {
        card.evidence.map { evidence in [evidence.title, evidence.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
    }

    private var listenLabel: String? {
        switch card.listen {
        case .recording(_, let title)?: title
        case .radio(let episode)?: RecommendationCardView.radioLine(episode)
        case nil: nil
        }
    }

    var body: some View {
        if isPhone { phone } else { mac }
    }

    /// "“Track” on Show · 12 Mar 2025": what of theirs was played, where and
    /// when -- the appearance's own facts, not the record on the card.
    static func radioLine(_ episode: RadioListen) -> String {
        let show = episode.showTitle ?? episode.episodeTitle
        let date = episode.airedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) }
        let place = [show, date].compactMap { $0 }.joined(separator: " · ")
        guard let played = episode.played?.trimmingCharacters(in: .whitespaces), !played.isEmpty else { return "Played on \(place)" }
        return "“\(played)” on \(place)"
    }

    private var phone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    ChipFlow {
                        Chip(text: card.chip, tone: card.relationship.isDirect ? .lead : .plain, size: 11, uppercase: true)
                    }
                    ChipFlow { Chip(text: card.artist.title, size: 17) }
                    if let record { ChipFlow { Chip(text: record, size: 12.5) } }
                }
            }
            .buttonStyle(.plain)
            Text(card.reason)
                .font(Typeface.mono(11))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if let listenLabel {
                Button(action: listen) {
                    HStack(spacing: 8) {
                        Image(systemName: card.listen?.isFromTheEvidence == true ? "play.fill" : "dot.radiowaves.left.and.right")
                        Text(listenLabel).lineLimit(1)
                    }
                    .font(Typeface.mono(12, weight: .medium))
                    .foregroundStyle(Chip.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Chip.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.listen?.isFromTheEvidence == true ? "Play \(listenLabel)" : "Open \(listenLabel)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mac: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.chip.uppercased())
                    .microLabel(1.2, size: 8.5)
                    .foregroundStyle(card.relationship.isDirect ? Palette.accent : Palette.inkFaint)
                Button(action: open) {
                    Text(card.artist.title).font(Typeface.body(14, weight: .medium)).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                if let record {
                    Text(record).font(Typeface.mono(10)).foregroundStyle(Palette.inkMuted)
                }
                Text(card.reason).font(Typeface.body(11.5)).foregroundStyle(Palette.inkFaint)
            }
            Spacer(minLength: 8)
            if let listenLabel {
                Button(action: listen) {
                    Label(listenLabel, systemImage: card.listen?.isFromTheEvidence == true ? "play.fill" : "dot.radiowaves.left.and.right")
                        .font(Typeface.mono(10))
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 4)
    }
}
