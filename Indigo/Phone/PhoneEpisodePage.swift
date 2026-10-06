//
//  PhoneEpisodePage.swift
//  Indigo
//
//  One episode on the phone, set out as its show's page is: the picture the
//  width of the screen with its words in boxes, the description and what is
//  known of it, a green play box beside its show and the crate, then the
//  tracklist -- each line's title over its artist, touching -- and more from
//  the same show as rows.
//
//  As with `PhoneShowPage`, each station's episode page loads its own and
//  hands the words over; this sets them out the same for all of them. NTS's
//  page keeps its own, for the tracks it can open.
//

import SwiftUI

/// A line of a tracklist.
struct PhoneTrackLine: Identifiable {
    let id: String
    /// Where it falls: a time where the station logs one, else its number.
    var marker: String?
    let title: String
    var artist: String?
    /// The station's crate button for the line.
    var crate: AnyView?
}

extension PhoneTrackLine {
    /// A line a station logs as one string, "Artist – Title": split at its
    /// first dash so it sets out as the others do, the title over the artist.
    /// A line with no dash is all title.
    static func logged(id: String, marker: String?, line: String, crate: AnyView?) -> PhoneTrackLine {
        for separator in [" – ", " — ", " - "] {
            if let range = line.range(of: separator) {
                let artist = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty {
                    return PhoneTrackLine(id: id, marker: marker, title: title, artist: artist, crate: crate)
                }
            }
        }
        return PhoneTrackLine(id: id, marker: marker, title: line, crate: crate)
    }
}

struct PhoneEpisodePage: View {
    /// The station or city, in the green box.
    let kind: String
    let title: String
    var subtitle: String?
    var imageURL: URL?
    var genres: [String] = []
    var summary: String?
    /// What is known of it, in a line: the date, the length, a repeat.
    var facts: String?
    /// The show it is an episode of, and the way to it.
    var show: (title: String, open: () -> Void)?
    /// Nil until the episode itself is in hand.
    var isLoaded = true
    var isPlayable = true
    var isPlaying = false
    var play: () -> Void = {}
    var crate: AnyView?
    var tracks: [PhoneTrackLine] = []
    /// Why there is no tracklist, where there is none; nil hides the section.
    var tracklistNote: String?
    var more: [PhoneEpisode] = []
    var moreTitle = "More from the show"
    var error: String?
    var retry: (() -> Void)?

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PhoneDetailHero(
                    kind: kind, title: title, subtitle: subtitle,
                    imageURL: imageURL, genres: genres, awaitingImage: !isLoaded
                )
                VStack(alignment: .leading, spacing: 18) {
                    if isLoaded {
                        intro
                        tracklist
                        if !more.isEmpty {
                            DigSection(title: moreTitle) {
                                VStack(spacing: 0) {
                                    ForEach(more.prefix(12)) { PhoneEpisodeRow(episode: $0) }
                                }
                                .padding(.horizontal, -16)
                            }
                        }
                    } else if let error {
                        Text(error)
                            .font(Typeface.mono(12))
                            .foregroundStyle(.white.opacity(0.6))
                        if let retry {
                            Button(action: retry) {
                                Chip(text: "Try again", tone: .lead, size: 12, uppercase: true)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("Loading the episode…")
                            .font(Typeface.mono(12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { PhoneDetailTopBar() }
        .foregroundStyle(.white)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(Typeface.mono(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let facts, !facts.isEmpty {
                Text(facts)
                    .font(Typeface.mono(11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if isPlayable {
                    Button(action: play) {
                        HStack(spacing: 8) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                            Text(isPlaying ? "Pause" : "Play episode")
                                .font(Typeface.mono(13))
                                .tracking(1.2)
                                .textCase(.uppercase)
                        }
                        .foregroundStyle(Chip.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Chip.green)
                    }
                    .buttonStyle(.plain)
                } else {
                    Chip(text: "No recording published", size: 12, uppercase: true)
                }
                if let show {
                    Button(action: show.open) {
                        Chip(text: show.title, size: 13)
                            .padding(.vertical, 1.5)
                    }
                    .buttonStyle(.plain)
                }
                if let crate {
                    crate.frame(height: 40)
                }
            }
        }
    }

    @ViewBuilder
    private var tracklist: some View {
        if !tracks.isEmpty {
            DigSection(title: "Tracklist", trailing: "\(tracks.count)") {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        line(track, green: Chip.green(at: index))
                    }
                }
                .padding(.horizontal, -16)
            }
        } else if let tracklistNote {
            DigSection(title: "Tracklist") {
                Text(tracklistNote)
                    .font(Typeface.mono(12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func line(_ track: PhoneTrackLine, green: Color) -> some View {
        HStack(spacing: 10) {
            if let marker = track.marker {
                Text(marker)
                    .font(Typeface.mono(11))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 0) {
                Chip(text: track.title, size: 13)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = track.artist, !artist.isEmpty {
                    Button { appState.open(.digArtist(mbid: nil, name: artist)) } label: {
                        Chip(text: artist, tone: .lead, size: 12, fill: green).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ArtistName.isRealArtist(artist))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let crate = track.crate { crate }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PhoneShowPage.rowGround)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
        }
    }
}
