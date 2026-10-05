//
//  PhoneForYouView.swift
//  Indigo
//
//  The phone's For You tab: what to explore next, one suggestion to a screen,
//  in the same language as Live -- the picture full-bleed, a few words, one
//  button, swiped up to the next. Artists and the next steps from what was
//  kept, with a radio show every third slide; each says in one line why it is
//  here and in one what it was reached through.
//
//  The suggestions are DIG's own (`DigStore.exploreOffers`), refreshed when
//  the crate changes, as the Mac's For You page refreshes them. A suggestion
//  is opened, not played: an artist opens its DIG page, a show its page or
//  latest broadcast.
//

import SwiftUI

struct PhoneForYouView: View {
    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig
    @Environment(CrateService.self) private var crate
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @Environment(DublabBrowseStore.self) private var dublabBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(N10ASBrowseStore.self) private var n10asBrowse
    @Bindable private var feeds = PhoneFeeds.shared

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let slides = Self.slides(from: dig.exploreOffers)
            Group {
                if slides.isEmpty {
                    empty
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(slides) { suggestion in
                                PhoneForYouSlide(
                                    suggestion: suggestion,
                                    portrait: suggestion.node.kind == .artist
                                        ? dig.portraitURL(for: suggestion.node.title) : nil,
                                    insets: insets
                                ) { Task { await open(suggestion.node) } }
                                .containerRelativeFrame([.horizontal, .vertical])
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $feeds.forYouID)
                }
            }
            .ignoresSafeArea()
        }
        .task(id: crate.revision) { await dig.refreshExploreOffers(crateRevision: crate.revision) }
    }

    /// Artists and next steps, a show every third slide, nothing twice.
    static func slides(from offers: ExploreOffers) -> [ExploreSuggestion] {
        var seen = Set<String>()
        let main = (offers.next + offers.artists).filter { seen.insert($0.id).inserted }
        let shows = offers.shows.filter { seen.insert($0.id).inserted }
        var slides: [ExploreSuggestion] = []
        var showIndex = 0
        for (index, suggestion) in main.enumerated() {
            slides.append(suggestion)
            if index % 2 == 1, showIndex < shows.count {
                slides.append(shows[showIndex])
                showIndex += 1
            }
        }
        return slides + shows.dropFirst(showIndex)
    }

    private func open(_ node: MusicNode) async {
        let stations = KeptShow.Stations(nts: ntsBrowse, lot: lotBrowse, dublab: dublabBrowse,
                                         radio80000: radio80000Browse, n10as: n10asBrowse)
        switch await KeptShow.destination(for: node, stations: stations) {
        case .page(let page): appState.open(page)
        case .section(let route): appState.select(route)
        case nil: break
        }
    }

    private var empty: some View {
        // The picture behind, clipped, so a filled image cannot widen the
        // frame the words are centred in.
        VStack(spacing: 10) {
            Text("Nothing to suggest yet")
                .font(.system(size: 22, weight: .bold))
            Text("Crate a few records, artists or shows, and what they lead to turns up here.")
                .font(Typeface.mono(12))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Image("MineralGround").resizable().scaledToFill()
                .overlay(Color.black.opacity(0.35))
        }
        .clipped()
    }
}

private struct PhoneForYouSlide: View {
    let suggestion: ExploreSuggestion
    let portrait: URL?
    let insets: EdgeInsets
    let open: () -> Void

    private var isShow: Bool { suggestion.node.kind == .broadcast }
    private var picture: URL? { suggestion.node.artworkURL ?? portrait }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Group {
                    if let picture {
                        ArtworkView(remoteURL: picture, side: max(proxy.size.width, proxy.size.height), glyphScale: 0.3)
                    } else {
                        Image("MineralGround").resizable().scaledToFill()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                Text(isShow ? "Radio show" : kindLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                    .padding(.top, insets.top + 8)
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Button(action: open) {
                        VStack(spacing: 4) {
                            Text(suggestion.node.title)
                                .font(.system(size: 28, weight: .bold))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .minimumScaleFactor(0.7)
                            if let subtitle = suggestion.node.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(Typeface.mono(12))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                        }
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    }
                    .buttonStyle(.plain)
                    // Why it is here, then what it was reached through.
                    Text(suggestion.reason)
                        .font(Typeface.mono(12.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !suggestion.reason.contains(suggestion.via) {
                        Text("via \(suggestion.via)")
                            .font(Typeface.mono(11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Button(action: open) {
                        HStack(spacing: 10) {
                            Image(systemName: isShow ? "play.fill" : "arrow.down.right")
                            Text(isShow ? "LISTEN" : "DIG IN")
                                .font(Typeface.mono(16, weight: .medium))
                                .tracking(2)
                        }
                        .foregroundStyle(Color(red: 0.06, green: 0.1, blue: 0.07))
                        .frame(maxWidth: 260)
                        .frame(height: 54)
                        .background(Color(red: 0.36, green: 0.49, blue: 0.36))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, insets.bottom + 22)
            }
        }
        .foregroundStyle(.white)
    }

    private var kindLabel: String {
        switch suggestion.node.kind {
        case .artist: "Artist"
        case .label: "Label"
        case .release: "Release"
        case .recording: "Recording"
        default: "Suggestion"
        }
    }
}
