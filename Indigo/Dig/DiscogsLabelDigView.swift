import SwiftUI

nonisolated struct DiscogsLabelProfile: Sendable {
    let name: String
    let releases: [ArtistProfile.ReleaseLine]
    let artists: [String]
    let relatedLabels: [String]
    let styles: [String]

    init(name: String, results: [DiscogsSearchResult]) {
        self.name = name
        var seenArtists = Set<String>()
        artists = results.compactMap { result in
            guard let divider = result.title.range(of: " - ") else { return nil }
            let value = String(result.title[..<divider.lowerBound])
            let key = RecordingKey.normalizeArtist(value)
            return !key.isEmpty && seenArtists.insert(key).inserted ? value : nil
        }
        releases = results.compactMap { result in
            guard let id = result.id else { return nil }
            let title = result.title.split(separator: " - ", maxSplits: 1).last.map(String.init) ?? result.title
            return ArtistProfile.ReleaseLine(
                title: title, year: result.year, discogsID: id,
                imageURL: result.coverImage.flatMap(URL.init(string:)),
                thumbnailURL: result.thumbnail.flatMap(URL.init(string:)),
                label: result.label?.first
            )
        }
        var seenLabels = Set<String>()
        relatedLabels = results.flatMap { $0.label ?? [] }.filter {
            let key = RecordingKey.normalizeArtist($0)
            return key != RecordingKey.normalizeArtist(name) && seenLabels.insert(key).inserted
        }
        var seenStyles = Set<String>()
        styles = results.flatMap { ($0.style ?? []) + ($0.genre ?? []) }.filter {
            seenStyles.insert($0.lowercased()).inserted
        }
    }
}

struct DiscogsLabelDigView: View {
    let labelName: String
    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    var body: some View {
        let profile = dig.discogsLabelProfile(named: labelName)
        VStack(spacing: 0) {
            PageHeader(title: labelName, breadcrumb: appState.breadcrumbTitle,
                       onBack: { appState.popDetail() }, subtitle: "Label")
            Rule(color: Palette.outline)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if dig.isEnriching { BufferingGlyph().accessibilityLabel("Loading label") }
                    if let profile {
                        DigTallies(entries: [("Catalogue", "\(profile.releases.count)"),
                                             ("Artists", "\(profile.artists.count)"),
                                             ("Related labels", "\(profile.relatedLabels.count)")])
                        if !profile.styles.isEmpty {
                            DigSection(title: "Sound") {
                                Text(profile.styles.prefix(12).joined(separator: " · "))
                                    .font(Typeface.mono(10)).foregroundStyle(Palette.inkMuted)
                                    .padding(.top, 6)
                            }
                        }
                        DigSection(title: "Browse catalogue", trailing: "\(profile.releases.count)") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 18)], spacing: 22) {
                                ForEach(profile.releases) { release in
                                    DigReleaseTile(release: release) {
                                        guard let id = release.discogsID else { return }
                                        appState.open(.digRelease(id: id, title: release.title))
                                    }
                                }
                            }.padding(.top, 14)
                        }
                        HStack(alignment: .top, spacing: 34) {
                            DigSection(title: "Artists", trailing: "\(profile.artists.count)") {
                                ForEach(profile.artists, id: \.self) { artist in
                                    DigLine(text: artist) { appState.open(.digArtist(mbid: nil, name: artist)) }
                                }
                            }
                            DigSection(title: "Related labels", trailing: "\(profile.relatedLabels.count)") {
                                ForEach(profile.relatedLabels, id: \.self) { label in
                                    DigLine(text: label) { appState.open(.digDiscogsLabel(name: label)) }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, Metrics.gutter).padding(.vertical, 22)
            }
        }.task(id: labelName) { await dig.enrichDiscogsLabel(named: labelName) }
    }
}
