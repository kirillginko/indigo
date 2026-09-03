//
//  CatalogDigView.swift
//  Indigo
//
//  A catalogue number as somewhere you can go.
//
//  ITLP09 is not a field on a release; it is a position in a run. Reading
//  along that run — ITLP08, ITLP10 — is how a record shop is actually browsed,
//  and it is how a promo, a reissue or a numbered pressing nobody wrote about
//  gets found. A search box cannot do this, because you would have to already
//  know what you were looking for.
//

import SwiftUI

struct CatalogDigView: View {
    let number: String

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    @State private var connections: [MusicGraph.Connection] = []
    @State private var hasLooked = false

    var body: some View {
        let _ = crate.revision
        let connections = connections
        let issued = connections.filter { $0.reasons.contains { $0.kind == .sameRelease } }
        let issuedIDs = Set(issued.map(\.to.id))
        let nearby = connections.filter { $0.to.kind == .release && !issuedIDs.contains($0.to.id) }
        let labels = connections.filter { $0.to.kind == .label }

        VStack(spacing: 0) {
            PageHeader(
                title: number.uppercased(),
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(issued: issued, nearby: nearby)
            )
            Rule(color: Palette.outline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !hasLooked {
                        DigSkeleton(hasImage: false, sections: 2)
                    } else if issued.isEmpty, nearby.isEmpty {
                        EmptyStateView(
                            headline: number.uppercased(),
                            message: "Indigo hasn't catalogued anything under this number yet. Dig into the label that issued it and it will fill in."
                        ) { EmptyView() }
                    }

                    if !issued.isEmpty {
                        DigSection(title: "Catalogued as \(number.uppercased())") {
                            releaseRows(issued)
                        }
                    }

                    if !labels.isEmpty {
                        DigSection(title: "Issued by") {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(labels) { label in
                                    DigLine(text: label.to.title) {
                                        if let page = label.to.destination { appState.open(page) }
                                    }
                                }
                            }
                        }
                    }

                    if !nearby.isEmpty {
                        // The run either side. This is the shelf.
                        DigSection(title: "Nearby on the shelf", trailing: "\(nearby.count)") {
                            releaseRows(nearby)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
                // One treatment for the whole page. See `LoadingVeil`.
                .loadingVeil(!hasLooked)
            }
            .scrollIndicators(.visible)
        }
        .task(id: number) {
            self.connections = await dig.connections(from: MusicNode.catalogNumber(number))
            hasLooked = true
        }
        .task(id: dig.revision) {
            self.connections = await dig.connections(from: MusicNode.catalogNumber(number))
        }
    }

    @ViewBuilder
    private func releaseRows(_ connections: [MusicGraph.Connection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(connections) { connection in
                DigLine(
                    text: connection.to.title,
                    detail: [connection.to.subtitle, connection.why?.headline]
                        .compactMap { $0 }.joined(separator: " · "),
                    action: connection.to.destination.map { page in { appState.open(page) } }
                )
                Rule()
            }
        }
    }

    private func subtitle(
        issued: [MusicGraph.Connection],
        nearby: [MusicGraph.Connection]
    ) -> String {
        guard let parts = CatalogNumber.split(number) else { return "Catalogue number" }
        var line = ["\(parts.prefix) \(parts.number)"]
        if !issued.isEmpty { line.append("\(issued.count) pressing\(issued.count == 1 ? "" : "s")") }
        if !nearby.isEmpty { line.append("\(nearby.count) nearby") }
        return line.joined(separator: " · ")
    }
}
