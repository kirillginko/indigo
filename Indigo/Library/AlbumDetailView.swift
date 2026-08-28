//
//  AlbumDetailView.swift
//  Indigo
//

import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    @Query private var tracks: [Track]

    init(albumID: String) {
        _tracks = Query(
            filter: #Predicate<Track> { $0.albumKey == albumID },
            sort: [SortDescriptor(\Track.discNumber), SortDescriptor(\Track.trackNumber),
                   SortDescriptor(\Track.sortTitle)]
        )
    }

    var body: some View {
        let album = LibraryGrouping.albums(from: tracks).first

        VStack(spacing: 0) {
            PageHeader(
                title: album?.title ?? "Album",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(for: album)
            ) {
                Button("Play Album") { play(from: 0) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(tracks.isEmpty)
            }
            Rule(color: Palette.outline)

            if tracks.isEmpty {
                EmptyStateView(headline: "Album unavailable",
                               message: "These files are no longer in the library.") {
                    Button("Back to Albums") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 14) {
                            ArtworkView(localKey: album?.artworkKey, side: 216)
                                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                            if let genre = dominantGenre {
                                TagChip(text: genre)
                            }
                        }

                        VStack(spacing: 0) {
                            ColumnHeader(showArtist: hasVariedArtists, showAlbum: false,
                                         horizontalPadding: 0)
                            Rule()
                            ForEach(Array(tracks.enumerated()), id: \.element.persistentModelID) { offset, track in
                                TrackRow(
                                    track: track,
                                    index: track.trackNumber > 0 ? track.trackNumber : offset + 1,
                                    showArtist: hasVariedArtists,
                                    showAlbum: false,
                                    horizontalPadding: 0,
                                    isCurrent: player.isCurrent(track.path),
                                    isPlaying: player.isPlaying
                                ) {
                                    play(from: offset)
                                }
                                Rule()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var hasVariedArtists: Bool {
        Set(tracks.map { LibraryKey.normalize($0.artist) }).count > 1
    }

    private var dominantGenre: String? {
        let genres = tracks.map(\.genre).filter { !$0.isEmpty }
        guard let first = genres.first else { return nil }
        return first
    }

    private func subtitle(for album: AlbumGroup?) -> String? {
        guard let album else { return nil }
        let seconds = Int(album.duration)
        let minutes = seconds / 60
        var parts = [album.artist]
        if album.year > 0 { parts.append(String(album.year)) }
        parts.append("\(album.trackCount) \(album.trackCount == 1 ? "track" : "tracks")")
        parts.append("\(minutes) min")
        return parts.joined(separator: " · ")
    }

    private func play(from offset: Int) {
        if player.isCurrent(tracks[offset].path) {
            player.toggle()
        } else {
            player.play(tracks.mediaItems(), startingAt: offset)
        }
    }
}
