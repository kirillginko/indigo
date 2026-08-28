//
//  ArtistDetailView.swift
//  Indigo
//

import SwiftUI
import SwiftData

struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    @Query private var tracks: [Track]

    private let columns = BrowseGrid.columns

    init(artistID: String) {
        _tracks = Query(
            filter: #Predicate<Track> { $0.artistKey == artistID },
            sort: [SortDescriptor(\Track.albumKey), SortDescriptor(\Track.discNumber),
                   SortDescriptor(\Track.trackNumber)]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: name,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle
            ) {
                Button("Play All") { play(from: 0) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(tracks.isEmpty)
            }
            Rule(color: Palette.outline)

            if tracks.isEmpty {
                EmptyStateView(headline: "Artist unavailable",
                               message: "These files are no longer in the library.") {
                    Button("Back to Artists") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MicroLabel(text: "Albums")
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.top, 20)
                            .padding(.bottom, 12)

                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(albums) { album in
                                AlbumTile(album: album) { appState.open(.album(album.id)) }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)

                        MicroLabel(text: "All Tracks")
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.top, 32)
                            .padding(.bottom, 10)
                        Rule()

                        ForEach(Array(tracks.enumerated()), id: \.element.persistentModelID) { offset, track in
                            TrackRow(
                                track: track,
                                index: offset + 1,
                                showArtist: false,
                                isCurrent: player.isCurrent(track.path),
                                isPlaying: player.isPlaying
                            ) {
                                play(from: offset)
                            }
                            Rule()
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var name: String {
        tracks.first?.displayAlbumArtist ?? "Artist"
    }

    private var albums: [AlbumGroup] {
        LibraryGrouping.albums(from: tracks)
    }

    private var subtitle: String {
        let albumCount = albums.count
        return "\(albumCount) \(albumCount == 1 ? "album" : "albums") · \(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
    }

    private func play(from offset: Int) {
        if player.isCurrent(tracks[offset].path) {
            player.toggle()
        } else {
            player.play(tracks.mediaItems(), startingAt: offset)
        }
    }
}
