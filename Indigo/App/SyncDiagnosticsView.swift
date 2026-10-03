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

/// Fits the interface to the screen and puts the panel's button in the
/// screen's corner. On the iPhone the interface is not laid out yet and can be
/// wider than the screen; a button attached to it ended up off the edge.
struct ScreenCornerSyncButton: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { screen in
            content
                .frame(width: screen.size.width, height: screen.size.height)
                .clipped()
                .overlay(alignment: .topTrailing) { SyncDiagnosticsButton() }
        }
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
