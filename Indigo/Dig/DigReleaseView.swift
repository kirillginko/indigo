//
//  DigReleaseView.swift
//  Indigo
//

import SwiftUI

struct DigReleaseView: View {
    /// Nil for a record no catalogue has claimed yet. That is a real state,
    /// not a failure: the artist's own listing names releases Discogs has no
    /// entry for, and a page that refuses to open for those is a page that
    /// refuses to open for exactly the obscure records this app is about.
    let releaseID: Int?
    let fallbackTitle: String
    /// Whose record it is, when we arrived from their page. Needed to look it
    /// up, and worth showing while we do.
    var artistName: String?

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @Environment(PlaybackCoordinator.self) private var player

    /// Filled in if the record turns out to be catalogued after all.
    @State private var resolvedID: Int?
    @State private var hasLookedUp = false

    private var identifier: Int? { releaseID ?? resolvedID }

    /// Empty means we arrived without knowing whose record it is — off a
    /// label page, say — which is a reason not to guess rather than a reason
    /// to search for nobody.
    private var credit: String? {
        guard let artistName, !artistName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return artistName
    }

    /// Held rather than read in `body` — see `ArtistDigView`. Building it
    /// reads the release, its label and every artist on it, and doing that in
    /// the render pass is why opening a record felt slow.
    @State private var profile: DigReleaseProfile?

    var body: some View {
        let _ = crate.revision
        let profile = self.profile ?? identifier.flatMap { dig.cachedReleaseProfile(id: $0) }
        let crateID = String(identifier ?? 0)
        let isCrated = crate.contains(dig: .release, identifier: crateID, providerID: "dig.release.discogs")

        VStack(spacing: 0) {
            PageHeader(
                title: profile?.title ?? fallbackTitle,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            ) {
                CrateButton(isCrated: isCrated) {
                    crate.toggle(
                        dig: .release, identifier: crateID, providerID: "dig.release.discogs",
                        title: profile?.title ?? fallbackTitle,
                        subtitle: releaseSubtitle(profile), artworkURL: profile?.coverURL,
                        genres: (profile?.styles ?? []) + (profile?.genres ?? [])
                    )
                }
            }
            Rule(color: Palette.outline)

            ScrollView {
                // Lazy, so the tracklist and everything under it cost nothing
                // until they are scrolled to.
                LazyVStack(alignment: .leading, spacing: 26) {
                    if profile == nil, !hasLookedUp {
                        DigSkeleton(sections: 2)
                    }
                    if profile == nil, hasLookedUp {
                        unclaimed
                    }
                    if let profile {
                        HStack(alignment: .top, spacing: 26) {
                            ArtworkView(remoteURL: profile.coverURL,
                                        previewRemoteURL: profile.previewURL,
                                        side: 240, glyphScale: 0.23,
                                        placeholder: .whiteLabel)
                                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                            VStack(alignment: .leading, spacing: 24) {
                                if !profile.artists.isEmpty {
                                    DigSection(title: "Artists") {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(credited(profile), id: \.self) { artist in
                                                DigLine(text: artist) {
                                                    appState.open(.digArtist(mbid: nil, name: artist))
                                                }
                                            }
                                        }
                                    }
                                }
                                if !profile.labels.isEmpty {
                                    DigSection(title: "Labels") {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(Array(profile.labels.enumerated()), id: \.offset) { _, label in
                                                DigLine(text: label.name, detail: label.catalogNumber) {
                                                    appState.open(.digDiscogsLabel(name: label.name))
                                                }
                                            }
                                        }
                                    }
                                }
                                pressing(profile)
                                if !profile.genres.isEmpty || !profile.styles.isEmpty {
                                    DigSection(title: "Genres / styles") {
                                        // Set the same way the artist page and
                                        // the radio pages set them. They are
                                        // the same kind of thing.
                                        TagFlow(tags: uniqueTags(profile))
                                            .padding(.top, 6)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        listen(profile)

                        if !profile.tracks.isEmpty {
                            DigSection(title: "Tracklist", trailing: "\(profile.tracks.count)") {
                                VStack(spacing: 0) {
                                    ForEach(profile.tracks) { track in
                                        HStack(spacing: 14) {
                                            Text(track.position.isEmpty ? "—" : track.position)
                                                .font(Typeface.mono(9.5))
                                                .foregroundStyle(Palette.inkFaint)
                                                .frame(width: 34, alignment: .leading)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(track.title)
                                                    .font(Typeface.body(12.5))
                                                    .foregroundStyle(Palette.ink)
                                                // Named only where the record
                                                // itself is credited to
                                                // nobody, which is the case
                                                // it matters in.
                                                if let artist = track.artist {
                                                    Text(artist)
                                                        .font(Typeface.mono(9.5))
                                                        .foregroundStyle(Palette.inkMuted)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                            if let duration = track.duration {
                                                Text(duration)
                                                    .font(Typeface.mono(9.5))
                                                    .foregroundStyle(Palette.inkFaint)
                                            }
                                        }
                                        .padding(.vertical, 7)
                                        Rule(color: Palette.outline.opacity(0.55))
                                    }
                                }
                            }
                        }

                        if let notes = profile.notes, !notes.isEmpty {
                            DigSection(title: "Release notes") {
                                Text(notes)
                                    .font(Typeface.body(12.5))
                                    .foregroundStyle(Palette.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 5)
                            }
                        }

                        if !profile.related.isEmpty {
                            DigSection(title: "Continue digging", trailing: "\(profile.related.count) connections") {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                                    alignment: .leading,
                                    spacing: 12
                                ) {
                                    ForEach(profile.related.prefix(16)) { artist in
                                        ConnectionExplainer(artist: artist) {
                                            appState.open(.digArtist(mbid: artist.mbid, name: artist.name))
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }

                        if let sourceURL = profile.sourceURL {
                            Link("Data provided by Discogs", destination: sourceURL)
                                .font(Typeface.mono(9))
                                .foregroundStyle(Palette.inkFaint)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
                // One treatment for the whole page rather than a bar above it
                // and a pane inside it. See `LoadingVeil`.
                //
                // Waits on the record itself, not on `isEnriching`: a page
                // that already has the release should not soften again every
                // time a later write lands. And once the lookup has finished
                // with nothing, `unclaimed` is the answer — veiling that would
                // promise something still coming.
                .loadingVeil(profile == nil && !hasLookedUp)
            }
            .scrollIndicators(.visible)
        }
        .task(id: fallbackTitle) {
            // Only for a record with no identifier. One that has an id is
            // looked up by the task below, and saying "no catalogue has this"
            // before that has run announces a failure in advance.
            guard releaseID == nil else { return }
            guard let credit else { hasLookedUp = true; return }
            resolvedID = await dig.resolveRelease(title: fallbackTitle, artist: credit)
            hasLookedUp = true
        }
        .task(id: dig.revision) {
            guard let identifier else { return }
            self.profile = await dig.releaseProfile(id: identifier)
        }
        .task(id: identifier) {
            guard let identifier else { return }
            self.profile = await dig.releaseProfile(id: identifier)
            await dig.enrichRelease(id: identifier)
            self.profile = await dig.releaseProfile(id: identifier)
            hasLookedUp = true
            // Asked before the list is offered, so nothing that will refuse
            // ever appears in it.
            await dig.verifyListenable(releaseIDs: [identifier])
        }
    }

    /// Hearing it.
    ///
    /// These are the recordings whoever catalogued this pressing linked to it,
    /// which is a far better match than asking a search engine for the track's
    /// name and hoping. They play in Indigo's own transport through YouTube's
    /// official player — Indigo does not resolve the underlying stream, which
    /// their terms prohibit and which would break the moment they changed it.
    @ViewBuilder
    private func listen(_ profile: DigReleaseProfile) -> some View {
        if !profile.listen.isEmpty {
            DigSection(title: "Listen", trailing: "\(profile.listen.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(profile.listen) { line in
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
                                    artist: profile.artists.first { ArtistName.isRealArtist($0) },
                                    release: profile.title, artworkURL: profile.coverURL
                                )
                            }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    /// Queues the whole record from whichever recording was pressed, so it
    /// keeps going the way a side of vinyl does.
    private func play(_ profile: DigReleaseProfile, from line: DigReleaseProfile.ListenLine) {
        let items = profile.listen.map { entry in
            MediaItem(
                id: "youtube.\(entry.url.absoluteString)",
                sourceID: "youtube",
                kind: .track,
                title: entry.title,
                subtitle: profile.artists.first { ArtistName.isRealArtist($0) } ?? profile.title,
                detail: profile.title,
                remoteArtworkURL: profile.coverURL,
                playbackURL: entry.url,
                embedProvider: .youtube
            )
        }
        let index = profile.listen.firstIndex { $0.id == line.id } ?? 0
        player.play(items, startingAt: index)
    }

    /// Who is actually on the record.
    ///
    /// A compilation is credited to "Various", which is nobody — so the names
    /// worth offering are the ones on the tracks. That is what a compilation
    /// *is*: the place several artists appear together, and the reason it is
    /// worth digging into at all.
    private func credited(_ profile: DigReleaseProfile) -> [String] {
        let stated = profile.artists.filter { ArtistName.isRealArtist($0) }
        guard stated.isEmpty else { return stated }

        var seen = Set<String>()
        return profile.tracks
            .compactMap(\.artist)
            .filter { ArtistName.isRealArtist($0)
                && seen.insert(RecordingKey.normalizeArtist($0)).inserted }
    }

    /// What can be said about a record no catalogue has an entry for.
    ///
    /// Which is not nothing: it has a name, somebody made it, and the fact
    /// that no catalogue holds it is itself the most interesting thing on the
    /// page. Saying so is the whole of §3 — incomplete metadata is valid.
    @ViewBuilder
    private var unclaimed: some View {
        let known = bandcamp
        // The same ladder every other surface uses, rather than Bandcamp
        // alone. A record reached from an artist's discography already had a
        // sleeve on the tile that was clicked; asking only Bandcamp for it
        // here is what made that picture disappear on the way in.
        let sleeve = DigArtwork(context: dig.context).release(title: fallbackTitle, artist: credit)
        HStack(alignment: .top, spacing: 26) {
            ArtworkView(
                remoteURL: sleeve.full ?? sleeve.thumbnail
                    ?? BandcampImage.sized(known?.imageURL, BandcampImage.cover),
                previewRemoteURL: sleeve.thumbnail ?? sleeve.full
                    ?? BandcampImage.sized(known?.imageURL, BandcampImage.thumbnail),
                side: 240, glyphScale: 0.23, placeholder: .whiteLabel
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 18) {
                DigSection(title: "Pressing") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            if let year = known?.year {
                                Text(year)
                                    .font(Typeface.mono(9.5))
                                    .foregroundStyle(Palette.inkFaint)
                            }
                            Spacer(minLength: 0)
                        }
                        Text("No catalogue has an entry for this record. It is named in \(credit.map { "\($0)'s" } ?? "the artist's") own listing and nowhere else Indigo can reach.")
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 5)
                }

                if let known {
                    if let label = known.labelName, LabelName.isRealLabel(label) {
                        DigSection(title: "Label") {
                            DigLine(text: label) { appState.open(.digDiscogsLabel(name: label)) }
                        }
                    }
                    if !known.trackTitles.isEmpty {
                        DigSection(title: "Tracklist", trailing: "\(known.trackTitles.count)") {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(known.trackTitles.enumerated()), id: \.offset) { index, title in
                                    DigLine(text: title, detail: "\(index + 1)")
                                    Rule(color: Palette.outline.opacity(0.55))
                                }
                            }
                        }
                    }
                    // The way out, once — rather than every tile in the grid
                    // being one.
                    if let page = URL(string: known.urlString) {
                        Link(destination: page) {
                            HStack(spacing: 7) {
                                Text("Open on Bandcamp").microLabel(1.2, size: 9)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Palette.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let credit {
                    DigSection(title: "Artist") {
                        DigLine(text: credit) {
                            appState.open(.digArtist(mbid: nil, name: credit))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What Bandcamp knows about this record, when no catalogue has it.
    ///
    /// A record only its maker has published is not a gap to apologise for —
    /// it is most of the point — so the page shows the sleeve, the year, the
    /// imprint and the tracks rather than a shrug.
    private var bandcamp: BandcampRelease? {
        guard let credit else { return nil }
        return BandcampEnricher(context: dig.context)
            .cachedReleases(forArtist: credit)
            .first { RecordingKey.normalizeTitle($0.title) == RecordingKey.normalizeTitle(fallbackTitle) }
    }

    /// Styles first, then any genre the styles did not already cover.
    private func uniqueTags(_ profile: DigReleaseProfile) -> [String] {
        var seen = Set<String>()
        return (profile.styles + profile.genres).filter {
            !$0.isEmpty && seen.insert(RecordingKey.normalize($0)).inserted
        }
    }

    /// What kind of object this is, and the numbers that lead back to the
    /// shelf it came off.
    ///
    /// A release with almost no metadata is a valid release rather than a
    /// broken one, so missing fields are stated as unknown rather than hidden
    /// — a white label with no artist and no title is exactly the thing worth
    /// keeping, and a page that quietly omits both makes it look like a bug.
    @ViewBuilder
    private func pressing(_ profile: DigReleaseProfile) -> some View {
        let numbers = profile.labels.compactMap(\.catalogNumber).filter { !$0.isEmpty }
        let kind = ReleaseClassifier.classify(
            title: profile.title, notes: profile.notes, catalogNumber: numbers.first,
            artistNames: profile.artists
        )
        DigSection(title: "Pressing") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    // Only when the record actually says what it is. Almost
                    // nothing carries a marker, so labelling every ordinary
                    // release "UNKNOWN RELEASE" told the listener nothing and
                    // made the whole catalogue look broken. The kinds worth
                    // naming — white label, dubplate, test press — still are.
                    if kind != .unknown {
                        Text(kind.label)
                            .microLabel(1.4, size: 9)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                    }
                    if let year = profile.year {
                        Text(String(year))
                            .font(Typeface.mono(9.5))
                            .foregroundStyle(Palette.inkFaint)
                    }
                    Spacer(minLength: 0)
                }
                if numbers.isEmpty {
                    Text("No catalogue number")
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 116), spacing: 10)],
                        alignment: .leading, spacing: 10
                    ) {
                        ForEach(numbers, id: \.self) { number in
                            CatalogChip(number: number) {
                                appState.open(.digCatalog(number: number))
                            }
                        }
                    }
                }
            }
            .padding(.top, 5)
        }
    }

    private func subtitle(_ profile: DigReleaseProfile?) -> String? {
        guard let profile else { return "Release" }
        var parts = profile.artists
        if let year = profile.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private func releaseSubtitle(_ profile: DigReleaseProfile?) -> String {
        guard let profile else { return "Release" }
        var parts = profile.artists
        if let year = profile.year { parts.append(String(year)) }
        return parts.isEmpty ? "Release" : parts.joined(separator: " · ")
    }
}
