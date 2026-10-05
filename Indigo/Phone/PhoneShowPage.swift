//
//  PhoneShowPage.swift
//  Indigo
//
//  One show on the phone, the way IDA's app sets one out: the show's picture
//  full-width with its words in boxes over it, one button for the latest
//  episode, then every episode as a row -- a square picture with a play box
//  on it, the title and the date, who was on, the genres in boxes -- rows
//  alternating dark and darker. The back button and the show's name stay at
//  the top as the page scrolls.
//
//  Every station publishes its shows its own way, so each station's show page
//  loads its own and hands this the words; this sets them out the same for
//  all of them. Off the phone, the station's own page is shown instead.
//

import SwiftUI

extension EnvironmentValues {
    /// Whether the page is in the phone's layout: `PhoneRootView` sets it.
    @Entry var isPhoneLayout = false
}

/// One episode, as a show page lists it.
struct PhoneEpisode: Identifiable {
    let id: String
    let title: String
    /// Who was on, where the station says; the show's own name is not repeated.
    var subtitle: String? = nil
    var date: Date? = nil
    var genres: [String] = []
    var imageURL: URL? = nil
    /// A picture kept on this device, for a track from the library.
    var localArtworkKey: String? = nil
    var isPlayable = true
    /// Whether a row that cannot play is drawn faded: an episode without
    /// audio, yes; a kept artist or label, no.
    var fadesUnplayable = true
    var isCurrent = false
    var isPlaying = false
    let play: () -> Void
    let open: () -> Void
    /// The station's own crate button for it, compact.
    var crate: AnyView? = nil
    /// Where to dig from it, offered on a long press.
    var dig: (() -> Void)? = nil
}

struct PhoneShowPage: View {
    let title: String
    /// The station, in the green box.
    let station: String
    var host: String? = nil
    var imageURL: URL? = nil
    var markURL: URL? = nil
    var genres: [String] = []
    var summary: String? = nil
    let episodes: [PhoneEpisode]
    var isLoading = false
    var emptyMessage = "Nothing archived for this show."
    /// Between the show and its episodes: an archive's playlists, say.
    var accessory: AnyView? = nil
    /// The next page of episodes, for a station that pages them; asked for
    /// when the end of the list comes into view.
    var loadMore: (@MainActor () async -> Void)? = nil

    @Environment(AppState.self) private var appState
    @State private var width: CGFloat = 393
    /// Whether the picture has scrolled up under the top bar, which then takes
    /// a ground and the show's name.
    @State private var scrolledPast = false

    /// The rows' one ground, see-through: the page's moving ground shows
    /// under the list.
    static let rowGround = Color.black.opacity(0.28)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                if let accessory { accessory }
                list
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > width - 110
        } action: { _, past in
            scrolledPast = past
        }
        .overlay(alignment: .top) { topBar }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: scrolledPast)
    }

    // MARK: The show

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                picture
                    .frame(width: width, height: width)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(spacing: 10) {
                    ChipFlow {
                        Chip(text: station, tone: .lead, size: 13, uppercase: true)
                        if let host, !host.isEmpty, host != title {
                            Chip(text: host, size: 13)
                        }
                    }
                    ChipFlow { Chip(text: title, size: 20) }
                    if !genres.isEmpty {
                        ChipFlow {
                            ForEach(genres.prefix(4), id: \.self) { Chip(text: $0, size: 12, uppercase: true) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .frame(width: width, height: width)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(Typeface.mono(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let imageURL {
            ArtworkView(remoteURL: imageURL, side: width, glyphScale: 0.3, markURL: markURL)
        } else {
            ZStack {
                PlayerShaderBackdrop()
                ArtworkView(side: 120, glyphScale: 0.3, markURL: markURL, showsGround: false)
                    .offset(y: -width * 0.15)
            }
        }
    }

    // MARK: The episodes

    @ViewBuilder
    private var list: some View {
        if episodes.isEmpty {
            Text(isLoading ? "Loading episodes…" : emptyMessage)
                .font(Typeface.mono(12))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Self.rowGround)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { episode in
                    PhoneEpisodeRow(episode: episode)
                }
                if let loadMore {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .task(id: episodes.count) { await loadMore() }
                }
            }
        }
    }

    // MARK: The top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { appState.popDetail() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .opacity(scrolledPast ? 1 : 0)
            // Balances the back button, so the name is centred.
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea(edges: .top)
                .opacity(scrolledPast ? 1 : 0)
        }
    }
}

/// An episode's row: the picture; the title and who was on in boxes, the
/// date, the genres; play and crate on the right. One dark ground, a line
/// under each. The crate page's rows are these too.
struct PhoneEpisodeRow: View {
    let episode: PhoneEpisode

    private static let side: CGFloat = 104
    /// Day first, as IDA writes it: 02.10.2026.
    private static let dateFormat = Date.VerbatimFormatStyle(
        format: "\(day: .twoDigits).\(month: .twoDigits).\(year: .defaultDigits)",
        timeZone: .current,
        calendar: .current
    )

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ArtworkView(localKey: episode.localArtworkKey, remoteURL: episode.imageURL, side: Self.side, glyphScale: 0.3)
                .frame(width: Self.side, height: Self.side)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    // Playing, the title takes the wordmark's sheen.
                    Chip(text: episode.title, tone: episode.isCurrent ? .sheen : .plain, size: 13)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let date = episode.date {
                        Text(date.formatted(Self.dateFormat))
                            .font(Typeface.mono(12))
                            .foregroundStyle(.white.opacity(0.6))
                            .monospacedDigit()
                            .fixedSize()
                            .padding(.top, 6)
                    }
                }
                if let subtitle = episode.subtitle, !subtitle.isEmpty {
                    Chip(text: subtitle, tone: .lead, size: 12)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ViewThatFits(in: .horizontal) {
                    genreBoxes(3)
                    genreBoxes(2)
                    genreBoxes(1)
                    Color.clear.frame(height: 1)
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: Self.side, alignment: .leading)

            HStack(spacing: 6) {
                Button(action: episode.play) {
                    Image(systemName: episode.isCurrent && episode.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Chip.ink)
                        .frame(width: 32, height: 32)
                        .background(Chip.green)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!episode.isPlayable)
                .opacity(episode.isPlayable ? 1 : 0)
                .accessibilityLabel(episode.isCurrent && episode.isPlaying ? "Pause \(episode.title)" : "Play \(episode.title)")
                if let crate = episode.crate { crate }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: Self.side)
        }
        .opacity(episode.isPlayable || !episode.fadesUnplayable ? 1 : 0.55)
        .background(PhoneShowPage.rowGround)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: episode.open)
        .contextMenu {
            if let dig = episode.dig {
                Button("Dig", systemImage: "arrow.right", action: dig)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func genreBoxes(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(episode.genres.prefix(count), id: \.self) { genre in
                Chip(text: genre, size: 11, uppercase: true).fixedSize()
            }
        }
    }
}
