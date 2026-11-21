import SwiftUI
#if os(macOS)
import AppKit
#endif

// Explorateur des fichiers archivés dans Documents/RaceBoxStudio : parcourir, consulter, ouvrir, supprimer.

/// Visionneuse dans laquelle ouvrir un fichier.
enum ExplorerTarget {
    case csv, gpx, fusion, fgpx
}

nonisolated struct ArchivedFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isCSV: Bool { url.pathExtension.lowercased() == "csv" }
    /// « CSV », « GPX » ou « FGPX ».
    var kind: String { url.pathExtension.uppercased() }
}

/// Un vol : son CSV et son GPX (même nom, extension différente).
nonisolated struct ArchivedSession: Identifiable, Hashable, Sendable {
    let stem: String
    var files: [ArchivedFile]

    var id: String { stem }
    var csv: ArchivedFile? { files.first(where: \.isCSV) }
    var gpx: ArchivedFile? { files.first { $0.kind == "GPX" } }
    /// Fusion GNSS / IMU créée automatiquement après le téléchargement.
    var fgpx: ArchivedFile? { files.first { $0.kind == "FGPX" } }
    var totalSize: Int { files.reduce(0) { $0 + $1.size } }
    var modified: Date { files.map(\.modified).max() ?? .distantPast }

    /// Date de début lue dans le nom (« racebox-2026-11-21T080454 », en UTC) ; sinon nil.
    var startDate: Date? {
        guard stem.hasPrefix("racebox-") else { return nil }
        let text = String(stem.dropFirst("racebox-".count).prefix(17))
        let style = Date.ISO8601FormatStyle().year().month().day().dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted)
        return try? Date(text, strategy: style)
    }

    var title: String {
        startDate?.formatted(date: .abbreviated, time: .standard) ?? stem
    }
}

nonisolated enum ArchiveListing {
    /// CSV et GPX du dossier, regroupés par nom, du plus récent au plus ancien.
    static func scan() -> [ArchivedSession] {
        guard let folder = try? SessionArchive.folder() else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: .skipsHiddenFiles)) ?? []
        var groups: [String: [ArchivedFile]] = [:]
        for url in urls where ["csv", "gpx", "fgpx"].contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            groups[url.deletingPathExtension().lastPathComponent, default: []].append(
                ArchivedFile(url: url, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast))
        }
        return groups.map { ArchivedSession(stem: $0.key, files: $0.value.sorted { $0.name < $1.name }) }
            .sorted { ($0.startDate ?? $0.modified) > ($1.startDate ?? $1.modified) }
    }

    /// Trajectoire du vol, lue dans le CSV (plus riche) ou à défaut dans le GPX.
    static func loadTrack(_ session: ArchivedSession) -> FlightTrack? {
        if let csv = session.csv, let data = try? Data(contentsOf: csv.url),
           let result = try? CSVReader.read(String(decoding: data, as: UTF8.self), name: session.stem) {
            return result.track
        }
        if let gpx = session.gpx, let data = try? Data(contentsOf: gpx.url) {
            return try? GPXReader.read(data, name: session.stem)
        }
        // .fgpx seul (CSV et GPX supprimés ou jamais archivés) : on en relit la trace.
        if let fgpx = session.fgpx, let data = try? Data(contentsOf: fgpx.url) {
            return (try? FGPXReader.read(String(decoding: data, as: UTF8.self), name: session.stem))?.track
        }
        return nil
    }
}

struct ArchiveExplorerPane: View {
    /// Change à chaque archivage terminé : relance la lecture du dossier.
    let archiveRevision: Int
    let open: (URL, ExplorerTarget) -> Void

    @State private var sessions: [ArchivedSession] = []
    @State private var isLoading = true
    @State private var selection: String?
    @State private var pendingDeletion: ArchivedSession?
    @State private var errorMessage: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var selected: ArchivedSession? { sessions.first { $0.id == selection } }

    var body: some View {
        Group {
            if isLoading, sessions.isEmpty {
                ProgressView("Lecture du dossier…")
            } else if sessions.isEmpty {
                ContentUnavailableView {
                    Label("Aucun fichier archivé", systemImage: "folder")
                } description: {
                    Text("Les sessions téléchargées depuis le boîtier sont archivées automatiquement (CSV, GPX et fusion FGPX) dans Documents/RaceBoxStudio.")
                } actions: {
                    Button("Actualiser", systemImage: "arrow.clockwise") { Task { await reload() } }
                }
            } else if sizeClass == .compact {
                VStack(spacing: 0) {
                    list
                    Divider()
                    detail.frame(height: 320)
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 340)
                    Divider()
                    detail.frame(maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await reload() } }
                #if os(macOS)
                Button("Ouvrir le dossier", systemImage: "folder") {
                    if let folder = try? SessionArchive.folder() { NSWorkspace.shared.open(folder) }
                }
                #endif
            }
        }
        .task(id: archiveRevision) { await reload() }
        .confirmationDialog("Supprimer ce vol ?", isPresented: Binding(get: { pendingDeletion != nil },
                                                                       set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { session in
            Button("Supprimer \(session.files.count) fichier(s)", role: .destructive) { delete(session) }
        } message: { session in
            #if os(macOS)
            Text("Les fichiers de « \(session.title) » (CSV, GPX, FGPX) seront mis à la corbeille.")
            #else
            Text("Les fichiers de « \(session.title) » (CSV, GPX, FGPX) seront supprimés définitivement.")
            #endif
        }
        .alert("Erreur", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    // MARK: Liste

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu { actions(for: session) }
                    }
                } footer: {
                    Text("\(sessions.count) vol(s) · \(ByteCountFormatter.string(fromByteCount: Int64(sessions.reduce(0) { $0 + $1.totalSize }), countStyle: .file))")
                }
            }
            .onDeleteCommand { if let selected { pendingDeletion = selected } }
        }
    }

    @ViewBuilder private func actions(for session: ArchivedSession) -> some View {
        if let csv = session.csv {
            Button("Ouvrir dans la visionneuse CSV", systemImage: "chart.xyaxis.line") { open(csv.url, .csv) }
            Button("Recalculer la fusion GNSS / IMU", systemImage: "airplane") { open(csv.url, .fusion) }
        }
        if let fgpx = session.fgpx {
            Button("Ouvrir la fusion (.fgpx)", systemImage: "airplane") { open(fgpx.url, .fgpx) }
        }
        if let gpx = session.gpx {
            Button("Ouvrir la trajectoire GPX", systemImage: "rotate.3d") { open(gpx.url, .gpx) }
        }
        #if os(macOS)
        Button("Afficher dans le Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting(session.files.map(\.url))
        }
        #endif
        Divider()
        Button("Supprimer…", systemImage: "trash", role: .destructive) { pendingDeletion = session }
    }

    // MARK: Détail

    @ViewBuilder private var detail: some View {
        if let selected {
            SessionDetail(session: selected, open: open, delete: { pendingDeletion = selected })
                .id(selected.id)
        } else {
            ContentUnavailableView("Sélectionne un vol", systemImage: "airplane.departure",
                                   description: Text("Ses statistiques et sa trajectoire s'affichent ici."))
        }
    }

    // MARK: Données

    private func reload() async {
        let found = await Task.detached(priority: .userInitiated) { ArchiveListing.scan() }.value
        sessions = found
        isLoading = false
        if let selection, !found.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = found.first?.id }
    }

    private func delete(_ session: ArchivedSession) {
        for file in session.files {
            do {
                #if os(macOS)
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                #else
                try FileManager.default.removeItem(at: file.url)
                #endif
            } catch {
                errorMessage = "\(file.name) : \(error.localizedDescription)"
            }
        }
        Task { await reload() }
    }
}

private struct SessionRow: View {
    let session: ArchivedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title).font(.headline)
            HStack(spacing: 8) {
                ForEach(session.files) { file in
                    Text("\(file.kind) \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Détail d'un vol : fichiers, actions, puis le résumé (statistiques et carte) calculé à la demande.
private struct SessionDetail: View {
    let session: ArchivedSession
    let open: (URL, ExplorerTarget) -> Void
    let delete: () -> Void

    @State private var track: FlightTrack?
    @State private var route: [TrackPoint] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let track {
                TrackSummaryView(track: track, route: route)
            } else if isLoading {
                ProgressView("Analyse du vol…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Fichier illisible", systemImage: "exclamationmark.triangle",
                                       description: Text("Ni le CSV ni le GPX de ce vol n'ont pu être lus."))
            }
        }
        .task {
            let session = session
            let loaded = await Task.detached(priority: .userInitiated) { () -> (FlightTrack, [TrackPoint])? in
                guard let track = ArchiveListing.loadTrack(session) else { return nil }
                return (track, Downsample.stride(track.points.filter(\.hasPosition), maxCount: 2000))
            }.value
            track = loaded?.0
            route = loaded?.1 ?? []
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(session.files) { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.isCSV ? "tablecells" : file.kind == "FGPX" ? "airplane" : "point.topleft.down.to.point.bottomright.curvepath")
                            .foregroundStyle(.secondary)
                        Text(file.name).textSelection(.enabled)
                        Text("· \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) · modifié \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
    }

    @ViewBuilder private var buttons: some View {
        if let csv = session.csv {
            Button("Visionneuse CSV", systemImage: "chart.xyaxis.line") { open(csv.url, .csv) }
            Button("Recalculer la fusion", systemImage: "airplane") { open(csv.url, .fusion) }
        }
        if let fgpx = session.fgpx {
            Button("Fusion (.fgpx)", systemImage: "airplane") { open(fgpx.url, .fgpx) }
                .buttonStyle(.borderedProminent)
        }
        if let gpx = session.gpx {
            Button("Trajectoire GPX", systemImage: "rotate.3d") { open(gpx.url, .gpx) }
        }
        #if os(macOS)
        Button("Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting(session.files.map(\.url))
        }
        #endif
        Button("Supprimer…", systemImage: "trash", role: .destructive, action: delete)
    }
}
