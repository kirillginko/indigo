//
//  LabelDigView.swift
//  Indigo
//
//  Labels are first-class here, not a field on a release. Following a label is
//  how you find the next four artists worth hearing, which is the whole reason
//  people read run-out grooves.
//

import SwiftUI

struct LabelDigView: View {
    let labelMBID: String
    let labelName: String

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    var body: some View {
        let profile = dig.labelProfile(mbid: labelMBID, fallbackName: labelName)

        VStack(spacing: 0) {
            PageHeader(
                title: profile?.name ?? labelName,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            )
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if dig.isEnriching {
                        BufferingGlyph()
                            .accessibilityLabel("Loading")
                    }
                    if let error = dig.notice {
                        VStack(alignment: .leading, spacing: 10) {
                            NoticeStrip(text: error) { dig.notice = nil }
                            Button("Try Again") {
                                Task { await dig.retryLabel(mbid: labelMBID) }
                            }
                            .buttonStyle(OutlineButtonStyle())
                        }
                    }

                    if let profile {
                        DigTallies(entries: [
                            ("Catalogue", "\(profile.catalogueSize)"),
                            ("Your library", "\(profile.libraryTrackCount)"),
                            ("Your crate", "\(profile.crateCount)"),
                            ("Radio", "\(profile.radioAppearances)")
                        ])

                        HStack(alignment: .top, spacing: 34) {
                            DigSection(title: "Artists", trailing: "\(profile.artists.count)") {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(profile.artists.prefix(20)) { artist in
                                        DigLine(text: artist.name) {
                                            appState.open(.digArtist(mbid: artist.mbid, name: artist.name))
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            DigSection(title: "Releases", trailing: profile.catalogueSize > profile.releases.count
                                       ? "\(profile.releases.count) of \(profile.catalogueSize)" : nil) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(profile.releases.prefix(20), id: \.self) { title in
                                        DigLine(text: title)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
        .task(id: labelMBID) { await dig.enrichLabel(mbid: labelMBID) }
    }

    private func subtitle(_ profile: LabelProfile?) -> String {
        guard let profile else { return "Label" }
        return [profile.origin, profile.founded.map { "Since \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
