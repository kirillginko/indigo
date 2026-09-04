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
                        title: profile.name, subtitle: "Artist", artworkURL: profile.coverURL,
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
                    // The page draws itself while it is loading, rather than
                    // a drawing of itself.
                    //
                    // There was a scaffold here — a grey portrait, grey
                    // tallies, five grey tiles — and it was a second copy of
                    // this layout, so it drifted from it: different heights,
                    // a different number of tiles, boxes standing in for
                    // things that turned out not to exist. And because the
                    // two are different view trees, the switch between them
                    // is a teardown and a rebuild rather than a diff, paid at
                    // the exact moment the record lands and the page is
                    // busiest.
                    //
                    // Drawn from the placeholder profile it is the same tree
                    // throughout: sections appear as they gain something to
                    // say, and nothing on screen is ever a stand-in for
                    // something that never arrives.
                    // This page's own loading, not the store's.
                    //
                    // `isEnriching` is true whenever anything anywhere is
                    // asking a catalogue — a crate row resolving, a tracklist
                    // filling in — so a page that had finished would put the
                    // bar back up because something else had started. It
                    // belongs to the stage this page is waiting on.
                    // No bar above the portrait at all.
                    //
                    // It was asked for twice: first as "too many loading
                    // animations", then as "why keep the second loading bar
                    // above the image". Reserving its space answered neither
                    // — the page still had a moving thing on it saying what
                    // the empty portrait underneath already said.
                    HStack(alignment: .top, spacing: 26) {
                        // No name set into the square. The header above
                        // already says who this is, and a portrait that is
                        // briefly the artist's name in type is a third thing
                        // between the empty tile and the photograph.
                        // The small one first, drawn coarsely, then the
                        // photograph over it. The search that finds an artist
                        // already carries the thumbnail, so something real is
                        // there a round trip before the full picture — rather
                        // than an empty square sitting beside a biography,
                        // which reads as a load that failed.
                        ArtworkView(
                            remoteURL: profile.coverURL,
                            previewRemoteURL: profile.previewURL,
                            side: 220, glyphScale: 0.24,
                            showsGround: false
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

                    // Everything under the portrait arrives together.
                    //
                    // These used to appear one at a time as each gained
                    // something to say — the source link, the genres, the
                    // discography, the labels — and each one pushed
                    // everything below it further down. Five separate
                    // shifts while somebody is trying to read, for a page
                    // that ends up the same shape either way. One reveal
                    // moves the page once.
                    //
                    // The portrait and the tallies above are the fixed
                    // head: one size, drawn immediately, never moved. And
                    // a page that already has its record shows all of it
                    // at once, so returning to an artist is never made to
                    // wait for a catalogue it will not ask about.
                    // The same condition the veil uses, so one moment does
                    // both: the blur lifts and the page is there. Two
                    // conditions meant the sections appeared empty under a
                    // veil that had already gone.
                    if hasEnriched || !profile.releases.isEmpty || !profile.related.isEmpty {
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
                                ForEach(settled(profile.releases).prefix(releaseLimit)) { release in
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

                    // Outside the block above on purpose. Everything in it is
                    // gated on the catalogues having answered, and radio is
                    // the one thing here that can speak for an artist no
                    // catalogue has heard of — which is exactly the artist it
                    // is worth speaking for. Hiding it until Discogs replied
                    // meant it was hidden precisely when it was the only thing
                    // on the page with anything to say.
                    //
                    // It draws nothing when there is nothing, so it needs no
                    // condition of its own.
                    ArtistRadioSection(artistName: profile.name)

                    DeepSectionView(
                        origin: .artist(profile.name, mbid: profile.mbid),
                        isReady: hasEnriched,
                        initial: nil
                    ) { appState.open($0) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
                // One treatment for the whole page rather than a spinner per
                // section. See `LoadingVeil`.
                // Veiled until the record is actually there.
                //
                // `isBare` stops being true the moment the artist's name and
                // picture are written — one round trip before the
                // discography — so the veil lifted onto a page that was still
                // empty, which is precisely the "it failed" reading it exists
                // to prevent. The discography is what the page is for, so
                // that is what it waits for.
                .loadingVeil(
                    !hasEnriched && profile.releases.isEmpty && profile.related.isEmpty
                )
            }
            .scrollIndicators(.visible)
        }
        .task(id: dig.revision) {
            // Writes arrive in bursts — the catalogue, then the
            // neighbourhood, then the sleeves, then Bandcamp — and each one
            // invalidated the page and sent it back to walk the graph again.
            // The trace put that at four hundred walks in a session, three
            // quarters of a second each, for perhaps forty answers worth
            // having.
            //
            // A pause before reading collapses a burst into one read: each
            // new revision cancels the last task before it has run. Nothing
            // is skipped — the final state is always read — it is only the
            // intermediate ones nobody sees that are.
            //
            // 350ms when a read cost the better part of a second. It does not
            // any more, and the arithmetic changed with it: a cold artist's
            // writes land whole round trips apart — the name, then the
            // discography, then the neighbourhood — so the pause collapsed
            // nothing between them and simply added itself to each stage. A
            // third of a second, three times, in front of the listener. What
            // it is actually for is the writes that arrive together, and
            // those arrive within a frame or two of each other.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await readProfile()
        }
        .task(id: artistMBID ?? artistName) {
            releaseOrder = []
            await readProfile()
            artistScenes = await dig.scenes(forArtist: artistName)

            // The catalogue first: everything after it needs the artist's own
            // links, which is where the Bandcamp address comes from.
            //
            // Nothing re-reads the profile after these steps. Each of them
            // writes, every write moves `revision`, and the task above already
            // answers that by rebuilding the page. Asking again here meant
            // every write was paid for twice — two reads of the tables, two
            // walks of the graph, two rebuilds of the whole view — and all of
            // it after the top of the page was already on screen, which is
            // what the stutter was.
            await dig.enrichArtist(name: artistName, mbid: artistMBID)
            // The one exception, and it costs nothing: "nothing to dig into"
            // is held behind `hasEnriched`, so that flag must not be raised
            // over a profile from before the catalogue answered. Both this
            // and the revision task ask for the same answer at the same
            // revision, and the store now walks it once for both.
            await readProfile()
            hasEnriched = true

            // The sleeves the page is showing, and nothing else yet. Running
            // Bandcamp alongside doubled the request stream while somebody was
            // trying to read the page, and every batch that landed invalidated
            // what they were looking at.
            // Only what is above the fold to begin with. Two dozen releases
            // is up to four dozen requests before anything else on the page
            // gets a turn, for tiles most people never scroll to — and the
            // rest are fetched on demand when "More releases" reveals them.
            await dig.fillMissingReleaseArtwork(
                forArtist: artistName, mbid: artistMBID, limit: 12
            )
            artistScenes = await dig.scenes(forArtist: artistName)
            // The descent is not computed here any more.
            //
            // It walks the graph again, from a second cache of its own, for a
            // section at the very bottom of the page that most openings never
            // reach — and it did it while somebody was waiting for the
            // discography. `DeepSectionView` works it out when it is actually
            // on screen.
            // Playability is asked about on the release page, which asks
            // before it offers the list. Asking here checked two dozen
            // recordings on YouTube in four batches — four more writes, four
            // more rebuilds of a page that had finished loading — for an
            // answer this page never shows. An unverified recording is
            // offered anyway, so nothing was waiting on the verdict.

            // Last, once the page has settled. Bandcamp is read a page a
            // second, so it is both the longest-running of these and the least
            // urgent — the discography is on screen long before it finishes.
            await dig.enrichBandcamp(forArtist: artistName)
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

    /// The order the releases were first shown in.
    ///
    /// Years arrive during enrichment, and re-sorting as they land makes
    /// records slide past each other under the reader's eyes. Whatever order
    /// the first full answer produced is the order the page keeps; records
    /// found later join the end rather than pushing the rest around.
    @State private var releaseOrder: [String] = []

    private func settled(_ releases: [ArtistProfile.ReleaseLine]) -> [ArtistProfile.ReleaseLine] {
        guard !releaseOrder.isEmpty else { return releases }
        // Tolerant on purpose. The first appearance is the place the record
        // keeps, which is this function's whole intent — and a view must not
        // be able to bring the app down over a repeated key.
        let placed = Dictionary(
            releaseOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return releases.enumerated().sorted { lhs, rhs in
            let left = placed[lhs.element.id]
            let right = placed[rhs.element.id]
            switch (left, right) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func readProfile() async {
        let found = await dig.artistProfile(name: artistName, mbid: artistMBID)
        profile = found
        if releaseOrder.isEmpty, !found.releases.isEmpty {
            releaseOrder = found.releases.map(\.id)
        }
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
            .compactMap(\.previewURL)
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
                } else if kinds.contains(.sameEra) {
                    lanes.eraArtists.append(artist)
                }
                // Anything reached by nothing nameable is not offered. A
                // connection that cannot say what it rests on is the one thing
                // this app is not allowed to show.
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
                                    artist: profile.name, artworkURL: profile.coverURL
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
                remoteArtworkURL: profile.coverURL,
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
                        ConnectionExplainer(
                            artist: peer,
                            portrait: dig.portraitURL(for: peer.name)
                        ) {
                            appState.open(.digArtist(mbid: peer.mbid, name: peer.name))
                        }
                    }
                }
            }
        }
    }
}
