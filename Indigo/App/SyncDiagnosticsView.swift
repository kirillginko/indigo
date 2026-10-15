//
//  SyncDiagnosticsView.swift
//  Indigo
//
//  Development builds only. What a device's synced store holds and what its
//  mirroring is doing, in the same terms the Mac-side tools print -- counts,
//  distinct ids, and the id digest per entity -- so two devices and CloudKit
//  can be compared line by line. And the actions of the two-device test, all
//  on rows keyed with the harness marker, which
//  `-INDIGO_CLEAN_TEST_ROWS_DEV` removes afterwards.
//
//  Shows no titles, names or anything else the listener made.
//

#if DEBUG

import CloudKit
import SwiftData
import SwiftUI

struct SyncDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = Report()
    @State private var account = "…"
    /// The other device's For You code, pasted in.
    @State private var otherCode = ""
    private var explore = ExploreDiagnostics.shared
    /// The musician-first development switches, kept until turned off.
    @AppStorage(MusicianFirst.switchKey) private var digMusicianFirst = false
    @AppStorage(ForYouMusicianFirst.switchKey) private var forYouMusicianFirst = false
    @AppStorage(DigRecommendations.switchKey) private var digRecommendations = false

    /// The shared things both devices act on, so their actions meet.
    static let testArtist = MusicNode.artist("\(TwoDeviceSyncRunner.marker) shared artist")
    static let testOrigin = MusicNode.artist("\(TwoDeviceSyncRunner.marker) shared origin")
    static let testShow = "indigo-sync-test-shared"

    struct Report {
        var rows: [(String, Int, Int, String)] = []
        var writers: [(String, Int)] = []
        var testVisits = 0
        var testComponents: [(String, Int)] = []
        var testStep = 0
        var testCrated = false
        var markerRows = 0
    }

    private var context: ModelContext { Persistence.container.mainContext }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("DIG: musicians first", isOn: $digMusicianFirst)
                    Toggle("For You: musician-first ranking", isOn: $forYouMusicianFirst)
                    Toggle("DIG: Hear next cards", isOn: $digRecommendations)
                } header: {
                    Text("Musician-first (development)")
                } footer: {
                    Text("DIG leaves engineers off artist pages (release pages still list them). For You starts from what you are into now and over time, and brings DIG's setting with it. Hear next shows a few musicians on each artist page with the record behind them and something to put on, and brings DIG's setting with it. Relaunch Indigo to apply; the first look after a change rebuilds the graph and takes a few seconds.")
                }
                Section("Mirroring") {
                    row("iCloud account", account)
                    row("UserData syncs", Persistence.syncing ? "yes" : "NO")
                    row("This device", String(DeviceIdentity.current.prefix(8)))
                    if let failure = Persistence.openFailure { Text(failure.reason).font(.caption).foregroundStyle(.red) }
                    ForEach(Array(MirroringMonitor.recent.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                Section("Store (compare with Scripts/userdata-digest.py)") {
                    ForEach(report.rows, id: \.0) { name, rows, distinct, digest in
                        VStack(alignment: .leading) {
                            Text("CD_\(name): rows \(rows), distinct \(distinct)").font(.callout.monospaced())
                            Text("digest \(digest.prefix(16))").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(report.writers, id: \.0) { writer, count in
                        row("writer \(writer.prefix(8))", "\(count)")
                    }
                }
                Section("For You (paste the other device's code)") {
                    forYou
                }
                Section("For You shadow: backend knowledge (not shown)") {
                    shadow
                }
                Section("Two-device test") {
                    row("shared artist visits", "\(report.testVisits)")
                    ForEach(report.testComponents, id: \.0) { writer, count in row("  from \(writer.prefix(8))", "\(count)") }
                    row("shared step count", "\(report.testStep)")
                    row("shared crate item", report.testCrated ? "in the crate" : "not in the crate")
                    row("test rows in this store", "\(report.markerRows)")
                    Button("Visit the shared artist once") { visit() }
                    Button("Visit the shared artist three times") { for _ in 0..<3 { visit() } }
                    Button("Crate the shared item") { crate() }
                    Button("Remove the shared item") { uncrate() }
                    Button("Log a listen on this device") { listen() }
                }
            }
            .navigationTitle("Sync")
            .toolbar {
                ToolbarItem { Button("Refresh") { refresh() } }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await loadAccount(); refresh() }
            .refreshable { refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
    }

    /// What this device's last look at For You was worked out from, and the
    /// same for another device's, part by part. See `ExploreDiagnostics`.
    @ViewBuilder private var forYou: some View {
        if let entry = explore.latest {
            Text(entry.code).font(.caption.monospaced()).textSelection(.enabled)
            TextField("Other device's code", text: $otherCode)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
            if let rows = ExploreDiagnostics.compare(entry.code, otherCode) {
                ForEach(rows, id: \.input) { compared in
                    HStack {
                        Text(compared.input)
                        Spacer()
                        Text(compared.matches ? "Match" : "Differ")
                            .monospaced()
                            .foregroundStyle(compared.matches ? Color.secondary : Color.red)
                    }
                }
            }
            row("rebuilt", entry.report.rebuilt.isEmpty ? "nothing" : entry.report.rebuilt.joined(separator: ", "))
            ForEach(entry.report.bytes.sorted { $0.key < $1.key }, id: \.key) { part, bytes in
                row("\(part) size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            ForEach(entry.report.counts.sorted { $0.key < $1.key }, id: \.key) { part, count in
                row(part, "\(count)")
            }
        } else {
            Text("Open For You once to record a look.").foregroundStyle(.secondary)
        }
    }

    /// The backend's For You set beside the visible one. See `ShadowReport`.
    @ViewBuilder private var shadow: some View {
        if let report = explore.shadow {
            let c = report.comparison
            let coverage = report.coverage
            let found = coverage.startingPoints.values.filter { $0.hasPrefix("found") }.count
            row("source", "\(report.source) · \(report.fetch.generation.isEmpty ? "cached" : report.fetch.generation)")
            row("freshness", coverage.staleAnswers == 0 ? "current" : "\(coverage.staleAnswers) stale answers"
                + (coverage.oldestFetch.map { " · oldest \($0.formatted(.relative(presentation: .named)))" } ?? ""))
            if !report.fetch.errors.isEmpty {
                Text("\(report.fetch.errors.count) failed: \(report.fetch.errors.first ?? "")")
                    .font(.caption).foregroundStyle(.red)
            }
            row("top 12 overlap", "\(c.top12Overlap)/12")
            row("top 20 overlap", "\(c.top20Overlap)/20")
            row("visible depth", report.visibleDepth.line)
            ForEach(report.stages, id: \.use) { stage in
                VStack(alignment: .leading) {
                    row(stage.use.rawValue, "\(stage.top12Overlap)/12 · \(stage.top20Overlap)/20 · reaches \(stage.visibleReached)/20")
                    Text(stage.depth.line + (stage.missingKinds.isEmpty ? "" : " · lacks " + stage.missingKinds.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            row("bundles", "\(report.bundleFetch.reads) reads · "
                + ByteCountFormatter.string(fromByteCount: Int64(report.bundleFetch.bytes), countStyle: .file)
                + (report.bundleFetch.errors.isEmpty ? "" : " · \(report.bundleFetch.errors.count) failed"))
            ForEach(Array(report.bundles.enumerated()), id: \.offset) { _, bundle in
                VStack(alignment: .leading) {
                    row("  \(bundle.node.prefix(28))\(bundle.discogsID.map { " #\($0)" } ?? "")", bundle.status)
                    if bundle.status != "no-identity" {
                        Text(bundle.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            row("shows overlap", "\(c.showsOverlap)/\(c.showsCount)")
            row("direction", c.visibleDirection == c.backendDirection ? "same" : "\(c.visibleDirection) → \(c.backendDirection)")
            row("starting points known", "\(found)/\(coverage.startingPoints.count)")
            ForEach(coverage.startingPoints.filter { !$0.value.hasPrefix("found") }.sorted { $0.key < $1.key }, id: \.key) { id, status in
                row("  \(id.prefix(34))", status)
            }
            row("artists", "\(coverage.artistsFound) found · \(coverage.artistsUnknown) unknown · \(coverage.artistsMissing) missing")
            row("missing route kinds", c.missingKinds.isEmpty ? "none" : c.missingKinds.joined(separator: ", "))
            row("requests", "\(report.fetch.calls) · \(ByteCountFormatter.string(fromByteCount: Int64(report.fetch.bytes), countStyle: .file)) · "
                + report.fetch.milliseconds.map { "\(Int($0.rounded()))ms" }.joined(separator: " + "))
            row("kept answers", "\(report.fetch.nodesKept) points · \(report.fetch.artistsKept) artists")
            row("shared digest", report.visibleShared == report.backendShared ? "same" : "differs")
            ForEach(c.reworded.prefix(5), id: \.id) { change in
                VStack(alignment: .leading) {
                    Text(change.id).font(.caption.monospaced())
                    Text("\(change.visible) → \(change.backend)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(c.moves.prefix(20), id: \.id) { move in
                row(move.title, "\(move.visible.map { "#\($0)" } ?? "–") → \(move.backend.map { "#\($0)" } ?? "–")")
            }
        } else {
            Text(ExploreShadow.isEnabled ? "Waiting for For You's next look." : "Shadow is off in this build.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospaced().foregroundStyle(.secondary) }
    }

    // MARK: - Actions

    private func visit() {
        DigHistory(context: context, writable: true).record(Self.testArtist, from: Self.testOrigin)
        refresh()
    }

    private func crate() {
        CrateService(context: context, writable: true).add(
            broadcast: Self.testShow, providerID: TwoDeviceSyncRunner.provider, title: "INDIGO-SYNC-TEST shared",
            subtitle: nil, artworkURL: nil, playbackURL: nil, embedProvider: nil)
        refresh()
    }

    private func uncrate() {
        let service = CrateService(context: context, writable: true)
        if let item = service.item(forBroadcast: Self.testShow, providerID: TwoDeviceSyncRunner.provider) { service.remove(item) }
        refresh()
    }

    private func listen() {
        let device = String(DeviceIdentity.current.prefix(6)).lowercased()
        ListeningLog(context: context, writable: true).record(
            .artist("\(TwoDeviceSyncRunner.marker) listen \(device)"), action: .played, seconds: 30, completion: 0.25)
        refresh()
    }

    // MARK: - Reading

    private func loadAccount() async {
        let status = try? await CKContainer(identifier: UserDataSync.containerID).accountStatus()
        account = switch status {
        case .available: "available"
        case .noAccount: "NO ACCOUNT"
        case .restricted: "restricted"
        case .temporarilyUnavailable: "temporarily unavailable"
        default: "could not tell"
        }
    }

    private func refresh() {
        var next = Report()
        func ids<T: PersistentModel>(_ type: T.Type, _ id: (T) -> UUID?) -> [String] {
            ((try? context.fetch(FetchDescriptor<T>())) ?? []).compactMap { id($0)?.uuidString }
        }
        for (name, all) in [
            ("CrateItem", ids(CrateItem.self) { $0.id }), ("ListeningEvent", ids(ListeningEvent.self) { $0.id }),
            ("DigVisit", ids(DigVisit.self) { $0.id }), ("DigStep", ids(DigStep.self) { $0.id }),
            ("DigCounter", ids(DigCounter.self) { $0.id })
        ] {
            next.rows.append((name, all.count, Set(all).count, RowIDs.digest(Array(Set(all)))))
        }
        let counters = (try? context.fetch(FetchDescriptor<DigCounter>())) ?? []
        next.writers = Dictionary(grouping: counters, by: \.deviceID).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }

        let artistID = Self.testArtist.id
        next.testVisits = ((try? context.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == artistID }))) ?? [])
            .map(\.visits).reduce(0, +)
        next.testComponents = DigCounters(context: context).components(.visit, key: artistID)
            .map { ($0.deviceID, $0.count) }.sorted { $0.0 < $1.0 }
        let identity = DigStep.canonicalIdentity(from: Self.testOrigin.id, to: artistID)
        next.testStep = ((try? context.fetch(FetchDescriptor<DigStep>(predicate: #Predicate { $0.identity == identity }))) ?? [])
            .map(\.count).reduce(0, +)
        next.testCrated = CrateService(context: context, writable: true)
            .item(forBroadcast: Self.testShow, providerID: TwoDeviceSyncRunner.provider) != nil

        next.markerRows =
            ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.providerID ?? "") }.count
            + ((try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.nodeKey) }.count
            + ((try? context.fetch(FetchDescriptor<DigVisit>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.nodeID) }.count
            + ((try? context.fetch(FetchDescriptor<DigStep>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.identity) }.count
            + counters.filter { TwoDeviceSyncRunner.isMarker($0.key) }.count
        report = next
    }
}

/// Puts the panel's button in the screen's corner (Debug builds on iOS).
///
/// It used to fit the interface to the screen as well -- a GeometryReader and
/// a clip -- because the iPhone was given the Mac's layout, wider than the
/// screen. The phone has its own layout now, and the clip held every page to
/// the safe area: a full-screen slide or player stopped short of the status
/// bar and the home indicator, in Debug builds only.
struct ScreenCornerSyncButton: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) { SyncDiagnosticsButton() }
    }
}

/// How the panel is reached: a small corner button on iPhone, where the rest of
/// the interface is not yet laid out; a menu command on the Mac.
struct SyncDiagnosticsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .font(.title2)
                .padding(10)
                .background(.thinMaterial, in: Circle())
        }
        .padding()
        .sheet(isPresented: $showing) { SyncDiagnosticsView() }
    }
}

#endif
