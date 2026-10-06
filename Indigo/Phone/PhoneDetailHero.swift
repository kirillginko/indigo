//
//  PhoneDetailHero.swift
//  Indigo
//
//  The head of a DIG page on the phone -- an artist, a track -- set out as
//  the show pages are: the picture the width of the screen, what it is in a
//  green box, its name in a dark one, the genres in boxes; and over it, a
//  back button and the crate's.
//

import SwiftUI

struct PhoneDetailHero: View {
    /// What the page is about, in the green box: "Artist", "Track".
    let kind: String
    let title: String
    /// A second line in a box under the name: who made a track, where an
    /// artist is from.
    var subtitle: String? = nil
    var imageURL: URL? = nil
    var previewURL: URL? = nil
    var genres: [String] = []
    /// Whether the picture is still being looked for: the square stays dark
    /// rather than drawing the stand-in.
    var awaitingImage = false

    @State private var width: CGFloat = 393

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if imageURL != nil || previewURL != nil || awaitingImage {
                    ArtworkView(
                        remoteURL: imageURL, previewRemoteURL: previewURL,
                        side: width, glyphScale: 0.24, placeholder: .mosaic,
                        showsGround: false, awaitingAddress: awaitingImage, blursWhileLoading: true
                    )
                } else {
                    // Nothing to show: the player's moving field.
                    PlayerShaderBackdrop()
                }
            }
            .frame(width: width, height: width)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 10) {
                ChipFlow { Chip(text: kind, tone: .lead, size: 13, uppercase: true) }
                VStack(spacing: 0) {
                    ChipFlow { Chip(text: title, size: 20) }
                    if let subtitle, !subtitle.isEmpty, subtitle != title {
                        ChipFlow { Chip(text: subtitle, tone: .lead, size: 13) }
                    }
                }
                if !genres.isEmpty {
                    ChipFlow {
                        ForEach(genres.prefix(4), id: \.self) { Chip(text: $0, size: 12, uppercase: true) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .frame(height: width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .foregroundStyle(.white)
    }
}

/// Back, at the top left, and the page's crate button at the top right --
/// left of the Debug sync button's corner, which it would sit under.
struct PhoneDetailTopBar: View {
    var isCrated: Bool? = nil
    var toggleCrate: () -> Void = {}

    @Environment(AppState.self) private var appState

    #if DEBUG
    private static let syncButtonRoom: CGFloat = 56
    #else
    private static let syncButtonRoom: CGFloat = 0
    #endif

    var body: some View {
        HStack {
            Button { appState.popDetail() } label: { PhoneBackGlyph() }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            Spacer()
            if let isCrated {
                circle(isCrated ? "checkmark" : "plus",
                       label: isCrated ? "Remove from crate" : "Add to crate",
                       action: toggleCrate)
                    .padding(.trailing, Self.syncButtonRoom)
            }
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Chip.black, ignoresSafeAreaEdges: [])
                .overlay(Rectangle().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A DIG page's chrome on the phone: the page runs up under the status bar,
/// its picture to the top, and back and crate float over it. Off the phone,
/// nothing.
struct PhoneDetailChrome: ViewModifier {
    let isPhone: Bool
    var isCrated: Bool?
    var toggleCrate: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(edges: isPhone ? .top : [])
            .overlay(alignment: .top) {
                if isPhone {
                    PhoneDetailTopBar(isCrated: isCrated, toggleCrate: toggleCrate)
                }
            }
    }
}

extension AnyLayout {
    /// Columns side by side, or, on the phone, one under the other.
    static func columns(phone: Bool, spacing: CGFloat = 34) -> AnyLayout {
        phone
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
    }
}

enum PhoneLayout {
    /// The phone pages' side margin. Section titles undo it to sit against
    /// the screen's left edge.
    static let margin: CGFloat = 16
}

/// A page's side margin: the Mac's gutter, or the phone's narrower one.
struct PageGutter: ViewModifier {
    @Environment(\.isPhoneLayout) private var isPhone

    func body(content: Content) -> some View {
        content.padding(.horizontal, isPhone ? PhoneLayout.margin : Metrics.gutter)
    }
}

extension View {
    func pageGutter() -> some View { modifier(PageGutter()) }
}

/// The back button's face: a square of the wordmark's moving sheen with the
/// chevron on it, as the tab bar's Dig cell is -- the one thing on every page
/// that is always the same.
struct PhoneBackGlyph: View {
    var body: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Chip.ink)
            .frame(width: 46, height: 46)
            .background { MineralSheenSurface() }
            // Round, as the tab bar's search button is.
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2)))
            .contentShape(Circle())
    }
}
