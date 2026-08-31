//
//  ArtistDigView.swift
//  Indigo
//
//  One artist, and every way out of them. The point of the page is not the
//  biography — it's that every line is somewhere else you can go.
//

import AppKit
import SwiftUI
import SwiftData

struct ArtistDigView: View {
    let artistName: String
    let artistMBID: String?

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @Environment(PlaybackCoordinator.self) private var player

    @State private var artistScenes: [MusicScene] = []

    /// Held rather than computed in `body`.
    ///
    /// Building a profile walks the whole graph, and doing that during the
    /// render pass means a new page cannot draw until it finishes — which is
    /// exactly what navigation felt like. The shell paints first and fills in.
    @State private var profile: ArtistProfile?
    @State private var lanes = Connections()
    /// Set once the catalogues have actually been asked. "Nothing found"
    /// before that is a failure announced in advance.
    @State private var hasEnriched = false
    /// How much of the discography is on screen. Grows on request rather than
    /// rendering hundreds of sleeves nobody asked to see.
    @State private var releaseLimit = 24
    /// The first level of DEEP, worked out while the page loads rather than
    /// when somebody scrolls down to it.
    @State private var surfaceDescent: DeepEngine.Descent?

    /// True while there is genuinely nothing to show yet — no cached page from
    /// last time, and the catalogues not yet asked.
    private func isWaiting(_ profile: ArtistProfile) -> Bool {
        !hasEnriched && profile.isBare
    }

    var body: some View {
        let _ = crate.revision
        // The page it was last showing, drawn immediately, before anything is
        // recomputed. Coming back to a page you were reading seconds ago
        // should not put a loading bar in front of it.
        let profile = profile
            ?? dig.cachedArtistProfile(name: artistName, mbid: artistMBID)
            ?? ArtistProfile.placeholder(name: artistName, mbid: artistMBID)
        let crateProvider = profile.mbid == nil ? "dig.artist.name" : "dig.artist.mbid"
        let crateID = profile.mbid ?? RecordingKey.normalizeArtist(profile.name)
        let isCrated = crate.contains(dig: .artist, identifier: crateID, providerID: crateProvider)
        let collaborators = lanes.collaborators
        let projects = lanes.projects
        let labelArtists = lanes.labelArtists
        let soundArtists = lanes.soundArtists
        let personalArtists = lanes.personalArtists
        let eraArtists = lanes.eraArtists

        VStack(spacing: 0) {
            PageHeader(
                title: profile.name,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            ) {
                CrateButton(isCrated: isCrated) {
                    crate.toggle(
                        dig: .artist, identifier: crateID, providerID: crateProvider,
                        title: profile.name, subtitle: "Artist", artworkURL: profile.imageURL,
                        genres: profile.styles + profile.genres
                    )
                }
            }
            Rule(color: Palette.outline)

            ScrollView {
                // Lazy: the sections below the fold cost nothing until they
                // are scrolled to, so the page is usable while the rest of it
                // is still being worked out.
                LazyVStack(alignment: .leading, spacing: 26) {
                    // Nothing is drawn until there is something to draw. The
                    // page used to lay out its whole scaffolding around a
                    // placeholder sleeve and an empty column, announce that it
                    // had found nothing, and then fill in — which reads as a
                    // failure followed by a correction rather than as loading.
                    if isWaiting(profile) {
                        WorkingPane()
                    } else {
                    if dig.isEnriching { WorkingBar() }
                    HStack(alignment: .top, spacing: 26) {
                        // The name when there is no portrait. An empty
                        // bordered square says nothing at all — least of all
                        // that this is who the page is about.
                        ArtworkView(
                            remoteURL: profile.imageURL,
                            side: 220, glyphScale: 0.24,
                            mark: profile.imageURL == nil ? profile.name : nil
                        )
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        VStack(alignment: .leading, spacing: 20) {
                            DigTallies(entries: [
                                ("Your library", "\(profile.libraryTrackCount)"),
                                ("Your crate", "\(profile.crateCount)"),
                                ("Radio", "\(profile.radioAppearances.reduce(0) { $0 + $1.count })")
                            ])
                            VStack(alignment: .leading, spacing: 12) {
                                if let realName = profile.realName, realName != profile.name {
                                    DigSection(title: "Name") { DigLine(text: realName) }
                                }
                                if let biography = profile.biography, !biography.isEmpty {
                                    DigSection(title: "Profile") {
                                        Text(biography)
                                            .font(Typeface.body(12.5))
                                            .foregroundStyle(Palette.inkMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 5)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let discogsURL = profile.discogsURL {
                        Link(destination: discogsURL) {
                            HStack(spacing: 7) {
                                Text("Source")
                                    .microLabel(1.2, size: 9)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Palette.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }

                    if profile.aliases.count > 6 {
                        VStack(alignment: .leading, spacing: 26) {
                            genresSection(profile)
                            DigSection(title: "Aliases", trailing: "\(profile.aliases.count)") {
                                DigLinkGrid(items: profile.aliases) { alias in
                                    appState.open(.digArtist(mbid: nil, name: alias))
                                }
                            }
                        }
                    } else if !profile.styles.isEmpty || !profile.genres.isEmpty || !profile.aliases.isEmpty {
                        HStack(alignment: .top, spacing: 34) {
                            genresSection(profile)
                            if !profile.aliases.isEmpty {
                                DigSection(title: "Aliases") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.aliases, id: \.self) { alias in
                                            DigLine(text: alias) {
                                                appState.open(.digArtist(mbid: nil, name: alias))
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Only once the graph has actually been read. The shell
                    // draws from a placeholder so the page appears at once,
                    // and a placeholder is bare by definition — announcing
                    // "nothing found" before looking would be a lie told
                    // quickly.
                    if hasEnriched, profile.isBare {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing to dig into yet.")
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                            Text("Indigo knows this name but hasn't found releases or label connections yet.")
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    }

                    listen(profile)

                    if !profile.releases.isEmpty {
                        DigSection(
                            title: "Browse releases",
                            trailing: profile.releases.count > releaseLimit
                                ? "\(releaseLimit) of \(profile.releases.count)"
                                : "\(profile.releases.count)"
                        ) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 18, alignment: .top)],
                                alignment: .leading,
                                spacing: 22
                            ) {
                                ForEach(profile.releases.prefix(releaseLimit)) { release in
                                    DigReleaseTile(release: release) {
                                        openRelease(release)
                                    }
                                }
                            }
                            .padding(.top, 14)

                            if profile.releases.count > releaseLimit {
                                Button {
                                    releaseLimit += 24
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("More releases").microLabel(1.4, size: 9.5)
                                        Text("\(profile.releases.count - releaseLimit) left")
                                            .font(Typeface.mono(9))
                                            .foregroundStyle(Palette.inkFaint)
                                    }
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .overlay(Rectangle().strokeBorder(
                                        Palette.outline, lineWidth: Metrics.hairline
                                    ))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 16)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 26) {
                        if !profile.radioAppearances.isEmpty {
                            DigSection(title: "Radio appearances") {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(profile.radioAppearances) { appearance in
                                        DigLine(
                                            text: appearance.label,
                                            detail: appearance.count > 1 ? "×\(appearance.count)" : nil
                                        )
                                    }
                                }
                            }
                        }

                        if !profile.labels.isEmpty {
                            DigSection(title: "Labels", trailing: profile.labels.count > 6
                                       ? "\(profile.labels.count)" : nil) {
                                if profile.labels.count > 6 {
                                    DigLinkGrid(items: profile.labels.map(\.name)) { name in
                                        guard let label = profile.labels.first(where: { $0.name == name }) else { return }
                                        openLabel(label)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.labels) { label in
                                            DigLine(text: label.name) {
                                                openLabel(label)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !profile.related.isEmpty {
                        DigSection(title: "Continue digging", trailing: "\(profile.related.count) routes") {
                            VStack(alignment: .leading, spacing: 22) {
                                connectionLane("Collaborators", artists: collaborators)
                                connectionLane("Aliases & projects", artists: projects)
                                connectionLane("Label neighbours", artists: labelArtists)
                                connectionLane("Same frequency", artists: soundArtists)
                                connectionLane("Heard together", artists: personalArtists)
                                connectionLane("Same era", artists: eraArtists)
                            }
                            .padding(.top, 14)
                        }
                    }

                    scenes
                    }

                    DeepSectionView(
                        origin: .artist(profile.name, mbid: profile.mbid),
                        isReady: hasEnriched,
                        initial: surfaceDescent
                    ) { appState.open($0) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
        .task(id: dig.revision) { await readProfile() }
        .task(id: artistMBID ?? artistName) {
            await readProfile()
            artistScenes = await dig.scenes(forArtist: artistName)

            // The catalogue first: everything after it needs the artist's own
            // links, which is where the Bandcamp address comes from.
            await dig.enrichArtist(name: artistName, mbid: artistMBID)
            await readProfile()
            hasEnriched = true

            // Then both together. Bandcamp used to be queued behind the
            // artwork pass — two dozen releases of network — so on a page
            // anyone left inside ten seconds it simply never ran, which is
            // why none of it was reaching DIG.
            async let sleeves: Void = dig.fillMissingReleaseArtwork(
                forArtist: artistName, mbid: artistMBID
            )
            async let bandcamp: Void = dig.enrichBandcamp(forArtist: artistName)
            _ = await (sleeves, bandcamp)

            await readProfile()
            artistScenes = await dig.scenes(forArtist: artistName)
            surfaceDescent = await dig.descent(
                from: .artist(artistName, mbid: artistMBID), at: .surface
            )
            await dig.verifyListenable(
                releaseIDs: await dig.artistProfile(name: artistName, mbid: artistMBID)
                    .releases.compactMap(\.discogsID)
            )
        }
        // Runs once per launch and keeps going for as long as the app is
        // open, filling in the rows nobody has dug into.
        // Newly revealed rows get the same treatment the first ones did,
        // rather than being the only blank part of the page.
        .task(id: releaseLimit) {
            guard releaseLimit > 24, let shown = self.profile else { return }
            warmArtwork(shown)
            await dig.fillMissingReleaseArtwork(
                forArtist: artistName, mbid: artistMBID, limit: releaseLimit
            )
        }
    }

    private func readProfile() async {
        let found = await dig.artistProfile(name: artistName, mbid: artistMBID)
        profile = found
        lanes = Connections.split(found.related)
        warmArtwork(found)
        // The rows on this page go to the front of the portrait queue.
        dig.wantPortraits(for: found.related.prefix(18).filter { $0.imageURL == nil }.map(\.name))
    }

    /// Pulls the small cuts down before the tiles ask for them.
    ///
    /// A grid that starts every request only as each tile appears fills in
    /// raggedly; warming the thumbnails first means most of them are already
    /// in hand. Thumbnails only — the full sleeves are fetched by whichever
    /// tiles are actually on screen.
    @State private var warmed: Int = 0

    private func warmArtwork(_ profile: ArtistProfile) {
        // What is actually near the top of the page. Warming everything
        // competed with the requests that fill the tiles the listener can
        // see, which made the grid slower rather than faster.
        let thumbnails = profile.releases.prefix(releaseLimit)
            .compactMap { $0.thumbnailURL ?? $0.imageURL }
            + profile.related.prefix(12).compactMap(\.imageURL)
        guard !thumbnails.isEmpty else { return }
        // Only when the set has actually changed. The profile is re-read on
        // every write to the store — including each batch of background
        // portraits — and starting the same three dozen prefetches again each
        // time is work that competes with the requests still outstanding.
        var hasher = Hasher()
        for url in thumbnails { hasher.combine(url) }
        let signature = hasher.finalize()
        guard signature != warmed else { return }
        warmed = signature

        Task.detached(priority: .utility) {
            await RemoteArtworkStore.shared.prefetch(thumbnails)
        }
    }

    /// The connection lanes, worked out in a single pass.
    ///
    /// Each of these used to be a filter that scanned every lane before it, so
    /// a well-connected artist cost several thousand comparisons — on every
    /// redraw, including every hover. Claiming each artist once as it is
    /// placed does the same job in one walk.
    struct Connections {
        var collaborators: [RelatedArtist] = []
        var projects: [RelatedArtist] = []
        var labelArtists: [RelatedArtist] = []
        var soundArtists: [RelatedArtist] = []
        var personalArtists: [RelatedArtist] = []
        var eraArtists: [RelatedArtist] = []

        /// Ordered by how well the connection is explained: an alias or a
        /// credit is a fact, a shared decade is barely a hint, so an artist
        /// lands in the strongest lane that claims them.
        static func split(_ related: [RelatedArtist]) -> Connections {
            var lanes = Connections()
            for artist in related {
                let kinds = Set(artist.reasons.map(\.kind))
                if !kinds.isDisjoint(with: [.collaborator, .appearsOnRelease]) {
                    lanes.collaborators.append(artist)
                } else if kinds.contains(.aliasOrProject) {
                    lanes.projects.append(artist)
                } else if kinds.contains(.sharedLabel) {
                    lanes.labelArtists.append(artist)
                } else if kinds.contains(.sharedStyle) {
                    lanes.soundArtists.append(artist)
                } else if !kinds.isDisjoint(with: [.sharedBroadcast, .sharedCollection]) {
                    lanes.personalArtists.append(artist)
                } else {
                    lanes.eraArtists.append(artist)
                }
            }
            return lanes
        }
    }

    /// Hearing them, without leaving the page.
    ///
    /// Gathered from the releases already catalogued — somebody who was
    /// cataloguing that pressing linked these recordings to it, which beats
    /// searching for a name and hoping. Playback goes through YouTube's own
    /// player, which is what their terms permit; Indigo never resolves the
    /// underlying stream.
    @ViewBuilder
    private func listen(_ profile: ArtistProfile) -> some View {
        if !profile.listen.isEmpty {
            DigSection(title: "Listen", trailing: "\(profile.listen.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(profile.listen.prefix(12)) { line in
                        ListenRow(
                            title: line.title,
                            duration: line.durationLabel,
                            isCurrent: player.current?.playbackURL == line.url,
                            isPlaying: player.current?.playbackURL == line.url && player.isPlaying,
                            isCrated: crate.isCrated(listening: line.url),
                            play: { play(profile, from: line) },
                            keep: {
                                crate.toggle(
                                    listening: line.url, title: line.title,
                                    artist: profile.name, artworkURL: profile.imageURL
                                )
                            }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    /// Queues the artist's whole catalogue from whichever recording was
    /// pressed, so it keeps going.
    private func play(_ profile: ArtistProfile, from line: DigReleaseProfile.ListenLine) {
        let items = profile.listen.map { entry in
            MediaItem(
                id: "youtube.\(entry.url.absoluteString)",
                sourceID: "youtube",
                kind: .track,
                title: entry.title,
                subtitle: profile.name,
                detail: profile.name,
                remoteArtworkURL: profile.imageURL,
                playbackURL: entry.url,
                embedProvider: .youtube
            )
        }
        let index = profile.listen.firstIndex { $0.id == line.id } ?? 0
        player.play(items, startingAt: index)
    }

    /// Where this artist sits. More than one is normal — people move, and a
    /// Berlin record made by somebody from Manchester belongs to both stories.
    ///
    /// Worked out in a task rather than in `body`: gathering a scene reads
    /// most of the store, and doing that again on every hover is how a page
    /// that renders instantly starts to feel slow.
    @ViewBuilder
    private var scenes: some View {
        let found = artistScenes
        if !found.isEmpty {
            DigSection(title: "Scenes", trailing: found.count > 1 ? "\(found.count)" : nil) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(found) { scene in
                        DigLine(
                            text: "\(scene.title) / \(scene.eraLabel)",
                            detail: [
                                scene.artists.count > 1 ? "\(scene.artists.count) artists" : nil,
                                scene.tags.prefix(3).joined(separator: " · ").nilIfEmpty
                            ].compactMap { $0 }.joined(separator: "  ")
                        ) {
                            appState.open(.digScene(city: scene.city))
                        }
                        Rule()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func genresSection(_ profile: ArtistProfile) -> some View {
        if !profile.styles.isEmpty || !profile.genres.isEmpty {
            DigSection(title: "Genres / styles") {
                TagFlow(tags: uniqueTags(profile))
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openLabel(_ label: ArtistProfile.LabelRef) {
        if let mbid = label.mbid {
            appState.open(.digLabel(mbid: mbid, name: label.name))
        } else {
            appState.open(.digDiscogsLabel(name: label.name))
        }
    }

    /// Styles first, then any genre the styles did not already cover —
    /// Discogs lists "Electronic" alongside "Techno" constantly, and printing
    /// both says less than printing one.
    private func uniqueTags(_ profile: ArtistProfile) -> [String] {
        var seen = Set<String>()
        return (profile.styles + profile.genres).filter {
            !$0.isEmpty && seen.insert(RecordingKey.normalize($0)).inserted
        }
    }

    private func subtitle(_ profile: ArtistProfile) -> String {
        [profile.origin, profile.disambiguation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func openRelease(_ release: ArtistProfile.ReleaseLine) {
        if let id = release.discogsID {
            appState.open(.digRelease(id: id, title: release.title))
            return
        }
        // Opens immediately either way. This used to resolve first and go
        // nowhere at all when the search came back empty — so the records with
        // no catalogue entry, which are the interesting ones, were the only
        // ones that did nothing when clicked. The page does the lookup itself
        // now, and says so when there is nothing to find.
        appState.open(.digReleaseNamed(title: release.title, artist: artistName))
    }

    @ViewBuilder
    private func connectionLane(_ title: String, artists: [RelatedArtist]) -> some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .microLabel(1.4, size: 9)
                    .foregroundStyle(Palette.inkMuted)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(artists.prefix(12)) { peer in
                        ConnectionExplainer(artist: peer) {
                            appState.open(.digArtist(mbid: peer.mbid, name: peer.name))
                        }
                    }
                }
            }
        }
    }
}
