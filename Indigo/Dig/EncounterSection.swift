//
//  EncounterSection.swift
//  Indigo
//
//  "Why does this sound familiar?"
//
//  Every other block on a DIG page is about the music. This one is about the
//  listener: it answers a question a streaming library is peculiarly bad at,
//  which is where *you* have run into something before. Somebody who has heard
//  Suso Sáiz on four different stations over a year does not need to be told
//  he exists — they need to be told they already know him, and where from.
//
//  Read out of the local listening log and nothing else. It draws nothing at
//  all when the log has never met this thing, in the same way and for the same
//  reason as `ArtistRadioSection`: a page for something new should look like a
//  page without a history block, not like one whose history failed to load.
//

import SwiftUI
import SwiftData

struct EncounterSection: View {
    /// What the page is about, in the graph's terms. The section is the same
    /// for an artist, a track, a release and a label; only the sentence
    /// changes.
    let node: MusicNode

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig
    @Environment(CrateService.self) private var crate

    @State private var encounters: ListeningLog.Encounters?
    @State private var isExpanded = false

    /// Enough places to show a pattern without turning the page into a log.
    private static let collapsedPlaces = 5

    var body: some View {
        Group {
            if let encounters, encounters.hasSomethingToSay {
                DigSection(title: heading(encounters), trailing: trailing(encounters)) {
                    VStack(alignment: .leading, spacing: 20) {
                        DigTallies(entries: tallies(encounters))
                            .padding(.top, 4)
                        places(encounters)
                    }
                }
            }
        }
        // Re-read when the crate changes, since keeping something is one of
        // the encounters this block counts.
        .task(id: "\(node.id)|\(crate.revision)") { load() }
    }

    private func load() {
        encounters = ListeningLog(context: dig.context).encounters(with: node)
    }

    // MARK: What to call it

    /// "You've heard this artist", "You've come across this label".
    ///
    /// The verb follows the evidence. Saying somebody has *heard* a label is
    /// wrong — a label is not a sound — and saying they have come across a
    /// track they played nine times is a strange way to put it.
    private func heading(_ encounters: ListeningLog.Encounters) -> String {
        guard encounters.count > 0 else { return "You've come across this before" }
        switch node.kind {
        case .artist: return "You've heard this artist"
        case .recording, .unknownRecording: return "You've played this"
        case .broadcast: return "You've listened to this show"
        case .station: return "You listen to this station"
        case .release, .label, .catalogNumber, .selector, .style, .scene:
            return "You've come across this before"
        }
    }

    private func trailing(_ encounters: ListeningLog.Encounters) -> String? {
        encounters.count > 1 ? "\(encounters.count) times" : nil
    }

    private func tallies(_ encounters: ListeningLog.Encounters) -> [(label: String, value: String)] {
        var entries: [(label: String, value: String)] = []
        if let first = encounters.firstAt {
            entries.append(("First", Self.dayLabel(first)))
        }
        if let last = encounters.lastAt, encounters.count > 1 || encounters.firstAt != last {
            entries.append(("Latest", Self.dayLabel(last)))
        }
        if let heard = Self.durationLabel(encounters.secondsHeard) {
            entries.append(("Heard", heard))
        }
        if encounters.isSaved {
            entries.append(("Crate", "Kept"))
        }
        return entries
    }

    // MARK: Where

    /// The stations and shows it was met through, most recent first.
    ///
    /// The point of the whole block. A count on its own is trivia; "Noods —
    /// Endpapers, three weeks ago" is the thing somebody half-remembers and
    /// can go back to, so each line opens the broadcast where it can.
    @ViewBuilder
    private func places(_ encounters: ListeningLog.Encounters) -> some View {
        let all = encounters.places
        let shown = isExpanded ? all : Array(all.prefix(Self.collapsedPlaces))

        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { place in
                    DigLine(
                        text: place.line,
                        detail: Self.dayLabel(place.at),
                        action: place.destination.map { page in
                            { appState.open(page) }
                        }
                    )
                }
                if all.count > Self.collapsedPlaces {
                    Button(isExpanded ? "Show fewer" : "All \(all.count) places") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(Typeface.body(11, weight: .medium))
                    .foregroundStyle(Palette.inkFaint)
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: Dates

    /// "Today", "3 days ago", "12 March", "March 2025".
    ///
    /// Coarser the further back it goes, because that is how the memory being
    /// jogged actually works: last week is a number of days, and two years ago
    /// is a month and a year.
    static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return "\(days) days ago" }
        if days < 28 {
            let weeks = days / 7
            return weeks == 1 ? "Last week" : "\(weeks) weeks ago"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? "d MMMM"
            : "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// "4h 20m", "35m". Nil below a minute, where the number would be noise.
    static func durationLabel(_ seconds: Double) -> String? {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

extension ListeningLog.Encounters {
    /// Whether there is anything here worth a heading.
    ///
    /// A single page-open with nothing behind it is not a history, and drawing
    /// "You've come across this before / 1" over it tells somebody something
    /// they learned by arriving on the page.
    var hasSomethingToSay: Bool {
        count > 0 || isSaved || places.count > 1
    }
}
