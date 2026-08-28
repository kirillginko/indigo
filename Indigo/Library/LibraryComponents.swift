//
//  LibraryComponents.swift
//  Indigo
//
//  Shared furniture for the three library sections: the page header and the
//  track row used by Tracks, Album and Artist pages.
//

import SwiftUI

// MARK: - Page header

struct PageHeader<Trailing: View>: View {
    let title: String
    var breadcrumb: String?
    var onBack: (() -> Void)?
    var subtitle: String?
    var accessory: AnyView?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let breadcrumb, let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(breadcrumb).microLabel(1.5)
                    }
                    .foregroundStyle(Palette.inkFaint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(Typeface.display(30))
                        .tracking(-0.8)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typeface.mono(10.5))
                            .foregroundStyle(Palette.inkMuted)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            if let accessory {
                accessory.padding(.top, 14)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.titleBarInset + 20)
        .padding(.bottom, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, breadcrumb: String? = nil, onBack: (() -> Void)? = nil,
         subtitle: String? = nil, accessory: AnyView? = nil) {
        self.init(title: title, breadcrumb: breadcrumb, onBack: onBack,
                  subtitle: subtitle, accessory: accessory) { EmptyView() }
    }
}

// MARK: - Column header

struct ColumnHeader: View {
    var showArtist = true
    var showAlbum = true
    var showGenre = false
    var horizontalPadding: CGFloat = Metrics.gutter

    var body: some View {
        HStack(spacing: 12) {
            Text("#").microLabel(1.0).frame(width: 26, alignment: .trailing)
            Text("Title").microLabel(1.4).frame(maxWidth: .infinity, alignment: .leading)
            if showArtist {
                Text("Artist").microLabel(1.4).frame(width: 190, alignment: .leading)
            }
            if showAlbum {
                Text("Album").microLabel(1.4).frame(width: 190, alignment: .leading)
            }
            if showGenre {
                Text("Genre").microLabel(1.4).frame(width: 120, alignment: .leading)
            }
            Text("Time").microLabel(1.0).frame(width: 52, alignment: .trailing)
        }
        .foregroundStyle(Palette.inkFaint)
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 7)
    }
}

// MARK: - Track row

struct TrackRow: View {
    let track: Track
    var index: Int?
    var showArtist = true
    var showAlbum = true
    var showGenre = false
    var horizontalPadding: CGFloat = Metrics.gutter
    var isCurrent: Bool
    var isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .frame(width: 26, alignment: .trailing)

                Text(track.title)
                    .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showArtist {
                    Text(track.artist)
                        .font(Typeface.body(12))
                        .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }
                if showAlbum {
                    Text(track.album)
                        .font(Typeface.body(12))
                        .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }
                if showGenre {
                    Text(track.genre.isEmpty ? "—" : track.genre)
                        .microLabel(0.8, size: 9)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                        .frame(width: 120, alignment: .leading)
                }
                Text(TimeFormat.clock(track.duration))
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: 52, alignment: .trailing)
            }
            .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
            .padding(.horizontal, horizontalPadding)
            .frame(height: Metrics.rowHeight)
            .background(isHovering ? Palette.wash : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 2)
                    .opacity(isCurrent ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else if isHovering {
            Image(systemName: "play.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.ink)
        } else if let index {
            Text("\(index)")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

// MARK: - Grid tile

struct AlbumTile: View {
    let album: AlbumGroup
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(localKey: album.artworkKey)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    .overlay(alignment: .bottomTrailing) {
                        if isHovering {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inverseInk)
                                .frame(width: 26, height: 26)
                                .background(Palette.inverse)
                                .padding(7)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(Typeface.body(12, weight: .semibold))
                        .lineLimit(1)
                    Text(album.artist)
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Empty library

struct NoLibraryView: View {
    @Environment(LibraryStore.self) private var library
    var context: String = "Your library is empty."

    var body: some View {
        EmptyStateView(headline: "No music yet", message: context) {
            Button("Choose Music Folder") { library.chooseFolder() }
                .buttonStyle(OutlineButtonStyle())
        }
    }
}
