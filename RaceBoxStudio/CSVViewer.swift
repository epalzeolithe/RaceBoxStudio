import Charts
import MapKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Fichiers ouverts dans les visionneuses

/// Garde les fichiers chargés quand on change de volet.
@Observable
final class ViewerStore {
    struct LoadedCSV {
        /// nil quand la trajectoire vient d'une session téléchargée (pas de fichier brut).
        let table: CSVTable?
        let track: FlightTrack
        let charts: TrackChartData
    }

    private(set) var csv: LoadedCSV?
    private(set) var gpx: FlightTrack?
    private(set) var isLoading = false
    var errorMessage: String?

    enum Kind: String {
        case csv, gpx
        var bookmarkKey: String { "lastViewerFile.\(rawValue).bookmark" }
        var nameKey: String { "lastViewerFile.\(rawValue).name" }
    }

    /// Nom du dernier fichier ouvert (proposé à la réouverture), par type de visionneuse.
    private(set) var lastCSVName: String?
    private(set) var lastGPXName: String?

    init() {
        lastCSVName = UserDefaults.standard.string(forKey: Kind.csv.nameKey)
        lastGPXName = UserDefaults.standard.string(forKey: Kind.gpx.nameKey)
    }

    func openCSV(_ url: URL) async {
        await load(url, kind: .csv) { data, name in
            let text = String(decoding: data, as: UTF8.self)
            let result = try CSVReader.read(text, name: name)
            return LoadedCSV(table: result.table, track: result.track, charts: TrackChartData(track: result.track))
        } apply: { self.csv = $0 }
    }

    func openGPX(_ url: URL) async {
        await load(url, kind: .gpx) { data, name in try GPXReader.read(data, name: name) } apply: { self.gpx = $0 }
    }

    /// Recharge le dernier fichier ouvert dans cette visionneuse, via son signet.
    func reopenLast(_ kind: Kind) async {
        guard let bookmark = UserDefaults.standard.data(forKey: kind.bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: Self.resolutionOptions, bookmarkDataIsStale: &isStale)
            switch kind {
            case .csv: await openCSV(url)
            case .gpx: await openGPX(url)
            }
        } catch {
            forget(kind)
            errorMessage = "Impossible de rouvrir le dernier fichier : \(error.localizedDescription)"
        }
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Appelé pendant l'accès au fichier, tant que l'URL est encore utilisable.
    private func remember(_ url: URL, name: String, kind: Kind) {
        guard let bookmark = try? url.bookmarkData(options: Self.creationOptions) else { return }
        UserDefaults.standard.set(bookmark, forKey: kind.bookmarkKey)
        UserDefaults.standard.set(name, forKey: kind.nameKey)
        setLastName(name, kind)
    }

    private func forget(_ kind: Kind) {
        UserDefaults.standard.removeObject(forKey: kind.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: kind.nameKey)
        setLastName(nil, kind)
    }

    private func setLastName(_ name: String?, _ kind: Kind) {
        switch kind {
        case .csv: lastCSVName = name
        case .gpx: lastGPXName = name
        }
    }

    /// Affiche une trajectoire déjà construite dans les deux visionneuses (aperçus).
    func showInBoth(_ track: FlightTrack) {
        gpx = track
        csv = LoadedCSV(table: nil, track: track, charts: TrackChartData(track: track))
    }

    /// Affiche directement une session téléchargée, sans passer par un export.
    func show(_ session: RecordingSession, inGPX: Bool) {
        let track = session.track
        if inGPX {
            gpx = track
        } else {
            csv = LoadedCSV(table: nil, track: track, charts: TrackChartData(track: track))
        }
    }

    /// Lecture et analyse hors de l'acteur principal : un CSV d'une heure à 25 Hz fait 90 000 lignes.
    private func load<T: Sendable>(_ url: URL, kind: Kind, parse: @escaping @Sendable (Data, String) throws -> T,
                                   apply: (T) -> Void) async {
        isLoading = true
        defer { isLoading = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            let value = try await Task.detached(priority: .userInitiated) { try parse(data, name) }.value
            apply(value)
            remember(url, name: url.lastPathComponent, kind: kind)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Séries prêtes à tracer, calculées une seule fois par fichier.
nonisolated struct TrackChartData: Sendable {
    let speed: [SeriesPoint]
    let altitude: [SeriesPoint]
    let loadFactor: [SeriesPoint]
    let accelerations: [SeriesPoint]
    let rotations: [SeriesPoint]
    let satellites: [SeriesPoint]
    /// Nuage vitesse / facteur de charge.
    let envelope: [TrackPoint]
    let route: [TrackPoint]

    static let accelerationSeries = ["X avant", "Y latéral", "Z vertical"]
    static let rotationSeries = ["Roulis", "Tangage", "Lacet"]

    init(track: FlightTrack) {
        let p = track.points
        speed = Downsample.extremes(p, series: "Vitesse") { $0.speedKmh }
        altitude = Downsample.extremes(p, series: "Altitude") { $0.altitude }
        loadFactor = Downsample.extremes(p, series: "Facteur de charge") { $0.gZ }
        let a = Self.accelerationSeries
        accelerations = Downsample.extremes(p, maxCount: 800, series: a[0]) { $0.gX }
            + Downsample.extremes(p, maxCount: 800, series: a[1]) { $0.gY }
            + Downsample.extremes(p, maxCount: 800, series: a[2]) { $0.gZ }
        let r = Self.rotationSeries
        rotations = Downsample.extremes(p, maxCount: 800, series: r[0]) { $0.rollRate }
            + Downsample.extremes(p, maxCount: 800, series: r[1]) { $0.pitchRate }
            + Downsample.extremes(p, maxCount: 800, series: r[2]) { $0.yawRate }
        satellites = Downsample.extremes(p, maxCount: 400, series: "Satellites") { $0.satellites }
        envelope = Downsample.stride(p.filter { $0.speed.isFinite && $0.gZ.isFinite }, maxCount: 2000)
        route = Downsample.stride(p.filter(\.hasPosition), maxCount: 2000)
    }
}

// MARK: - Volet CSV

struct CSVViewerPane: View {
    let store: ViewerStore
    let sessions: [RecordingSession]

    private enum Page: String, CaseIterable, Identifiable {
        case summary = "Résumé", charts = "Graphiques", table = "Tableau"
        var id: Self { self }
    }

    @State private var page = Page.summary
    @State private var showImporter = false

    var body: some View {
        Group {
            if let csv = store.csv {
                VStack(spacing: 0) {
                    Picker("Vue", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top])
                    .padding(.bottom, 8)

                    switch page {
                    case .summary: TrackSummaryView(track: csv.track, route: csv.charts.route)
                    case .charts: TrackChartsView(track: csv.track, data: csv.charts)
                    case .table: rawTable(csv)
                    }
                }
                .navigationSubtitleIfAvailable(csv.track.name)
            } else {
                TrackEmptyState(kind: "CSV", isLoading: store.isLoading, lastFile: store.lastCSVName,
                                reopenLast: { Task { await store.reopenLast(.csv) } }) { showImporter = true }
            }
        }
        .toolbar { TrackOpenToolbar(sessions: sessions, open: { showImporter = true },
                                    show: { store.show($0, inGPX: false) }) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: TrackFileType.csv) { result in
            if case .success(let url) = result { Task { await store.openCSV(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.openCSV(url) }
            return true
        }
    }

    @ViewBuilder private func rawTable(_ csv: ViewerStore.LoadedCSV) -> some View {
        if let table = csv.table {
            CSVTableView(table: table)
        } else {
            ContentUnavailableView("Pas de fichier brut", systemImage: "tablecells",
                                   description: Text("Cette session vient de la mémoire du boîtier : exporte-la en CSV pour voir les colonnes."))
        }
    }
}


// MARK: - Éléments communs aux deux visionneuses

struct TrackEmptyState: View {
    let kind: String
    let isLoading: Bool
    /// Nom du dernier fichier ouvert : s'il existe, on propose de le recharger.
    var lastFile: String?
    var reopenLast: () -> Void = {}
    let open: () -> Void

    var body: some View {
        if isLoading {
            ProgressView("Lecture du fichier…")
        } else {
            ContentUnavailableView {
                Label("Aucun fichier \(kind)", systemImage: kind == "GPX" ? "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath" : "chart.xyaxis.line")
            } description: {
                Text("Ouvre un fichier \(kind) ou glisse-le ici. Tu peux aussi afficher une session téléchargée.")
            } actions: {
                if let lastFile {
                    Button("Rouvrir « \(lastFile) »", systemImage: "arrow.counterclockwise", action: reopenLast)
                        .buttonStyle(.borderedProminent)
                    Button("Ouvrir un autre fichier \(kind)…", action: open)
                } else {
                    Button("Ouvrir un fichier \(kind)…", action: open)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct TrackOpenToolbar: ToolbarContent {
    let sessions: [RecordingSession]
    let open: () -> Void
    let show: (RecordingSession) -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if !sessions.isEmpty {
                Menu("Sessions", systemImage: "tray.full") {
                    ForEach(sessions) { session in
                        Button(session.title) { show(session) }
                    }
                }
                .help("Afficher une session téléchargée du boîtier")
            }
            Button("Ouvrir…", systemImage: "folder", action: open)
        }
    }
}

// MARK: - Résumé

struct TrackSummaryView: View {
    let track: FlightTrack
    let route: [TrackPoint]

    var body: some View {
        // La carte occupe toute la hauteur restante, jusqu'à la console, et suit le redimensionnement.
        // Fenêtre trop basse : on bascule sur une page défilante avec une carte de hauteur fixe.
        ViewThatFits(in: .vertical) {
            content(mapHeight: nil)
            ScrollView { content(mapHeight: 320) }
        }
    }

    private func content(mapHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(tiles, id: \.title) { tile in StatTile(tile: tile) }
                }
            }
            .padding([.horizontal, .top])
            if route.count >= 2 {
                TrackMapView(route: route)
                    .frame(minHeight: mapHeight ?? 220, maxHeight: mapHeight ?? .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                    .padding(.horizontal)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: mapHeight == nil ? .infinity : nil, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.name).font(.title2.bold())
            Text([track.startDate?.formatted(date: .abbreviated, time: .standard),
                  "\(track.points.count.formatted()) points"].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tiles: [StatTile.Model] {
        let s = track.stats
        var out: [StatTile.Model] = [
            .init(title: "Durée", value: TrackFormat.clock(s.duration), symbol: "clock"),
        ]
        if track.hasPosition {
            out.append(.init(title: "Distance", value: s.distance >= 1000 ? TrackFormat.number(s.distance / 1000, 2, unit: "km")
                                                                          : TrackFormat.number(s.distance, unit: "m"),
                             symbol: "point.topleft.down.to.point.bottomright.curvepath"))
        }
        if track.hasSpeed {
            out.append(.init(title: "Vitesse max", value: TrackFormat.number(s.maxSpeed * 3.6, unit: "km/h"), symbol: "gauge.with.dots.needle.100percent"))
            out.append(.init(title: "Vitesse moyenne", value: TrackFormat.number(s.averageSpeed * 3.6, unit: "km/h"), symbol: "gauge.with.dots.needle.50percent"))
        }
        if track.hasAltitude {
            out.append(.init(title: "Altitude max", value: TrackFormat.number(s.maxAltitude, unit: "m"), symbol: "arrow.up.to.line"))
            out.append(.init(title: "Altitude min", value: TrackFormat.number(s.minAltitude, unit: "m"), symbol: "arrow.down.to.line"))
            out.append(.init(title: "Dénivelé +", value: TrackFormat.number(s.climb, unit: "m"), symbol: "chart.line.uptrend.xyaxis"))
        }
        if track.hasAcceleration {
            out.append(.init(title: "Facteur de charge max", value: TrackFormat.number(s.maxG, 1, unit: "g"), symbol: "arrow.up.circle"))
            out.append(.init(title: "Facteur de charge min", value: TrackFormat.number(s.minG, 1, unit: "g"), symbol: "arrow.down.circle"))
        }
        if track.hasRotation {
            out.append(.init(title: "Rotation max", value: TrackFormat.number(s.maxRotation, unit: "°/s"), symbol: "arrow.triangle.2.circlepath"))
        }
        if track.hasSatellites {
            out.append(.init(title: "Satellites (moy.)", value: TrackFormat.number(s.averageSatellites, 1), symbol: "antenna.radiowaves.left.and.right"))
        }
        return out
    }
}

/// Chiffre clé : libellé discret au-dessus, valeur en gros.
struct StatTile: View {
    struct Model {
        let title: String
        let value: String
        let symbol: String
    }

    let tile: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tile.title, systemImage: tile.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tile.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

/// Trace vue du dessus, sur photo aérienne.
struct TrackMapView: View {
    let route: [TrackPoint]

    var body: some View {
        let coordinates = route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: coordinates)
                .stroke(VizPalette.series1, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if let first = coordinates.first {
                Annotation("Départ", coordinate: first) { MapPin(symbol: "flag.fill") }
            }
            if let last = coordinates.last {
                Annotation("Arrivée", coordinate: last) { MapPin(symbol: "flag.checkered") }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
    }

    private struct MapPin: View {
        let symbol: String
        var body: some View {
            Image(systemName: symbol)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.7), in: .circle)
        }
    }
}

// MARK: - Graphiques

struct TrackChartsView: View {
    let track: FlightTrack
    let data: TrackChartData
    /// Curseur partagé : survoler un graphique place le même instant sur tous les autres.
    @State private var selectedTime: Double?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if track.hasSpeed {
                    TimeChartCard(title: "Vitesse", unit: "km/h", digits: 0, points: data.speed, selection: $selectedTime)
                }
                if track.hasAltitude {
                    TimeChartCard(title: "Altitude", unit: "m", digits: 0, points: data.altitude, includesZero: false,
                                  selection: $selectedTime)
                }
                if track.hasAcceleration {
                    TimeChartCard(title: "Facteur de charge (Z)", unit: "g", digits: 2, points: data.loadFactor,
                                  references: [0, 1], selection: $selectedTime)
                    TimeChartCard(title: "Accélérations", unit: "g", digits: 2, points: data.accelerations,
                                  series: TrackChartData.accelerationSeries, selection: $selectedTime)
                }
                if track.hasRotation {
                    TimeChartCard(title: "Vitesses de rotation", unit: "°/s", digits: 0, points: data.rotations,
                                  series: TrackChartData.rotationSeries, references: [0], selection: $selectedTime)
                }
                if track.hasSpeed, track.hasAcceleration {
                    EnvelopeChartCard(points: data.envelope)
                }
                if track.hasSatellites {
                    TimeChartCard(title: "Satellites", unit: "", digits: 0, points: data.satellites, includesZero: false,
                                  selection: $selectedTime)
                }
            }
            .padding()
        }
    }
}

/// Courbe en fonction du temps : un seul axe Y, une à trois séries, curseur au survol.
struct TimeChartCard: View {
    let title: String
    let unit: String
    let digits: Int
    let points: [SeriesPoint]
    var series: [String] = []
    /// Lignes de repère horizontales (0 g, 1 g…).
    var references: [Double] = []
    /// Faux pour l'altitude : l'axe part de la valeur la plus basse, pas de 0 m.
    var includesZero = true
    @Binding var selection: Double?

    private var seriesNames: [String] { series.isEmpty ? [points.first?.series ?? title] : series }
    private var colors: [Color] { Array([VizPalette.series1, VizPalette.series2, VizPalette.series3].prefix(seriesNames.count)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(readout).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Chart {
                ForEach(references, id: \.self) { y in
                    RuleMark(y: .value("Repère", y))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Temps", p.time), y: .value(title, p.value))
                        .foregroundStyle(by: .value("Série", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let selection {
                    RuleMark(x: .value("Curseur", selection))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: seriesNames, range: colors)
            .chartLegend(seriesNames.count > 1 ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading)
            .chartXSelection(value: $selection)
            .chartXScale(domain: timeDomain)
            .chartYScale(domain: .automatic(includesZero: includesZero))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { Text(TrackFormat.clock(value.as(Double.self) ?? 0)) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .frame(height: 190)
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    /// L'axe du temps s'arrête à la fin des données (pas d'arrondi qui laisserait un blanc à droite).
    private var timeDomain: ClosedRange<Double> {
        let times = points.map(\.time)
        guard let first = times.min(), let last = times.max(), last > first else { return 0...1 }
        return first...last
    }

    /// « 2:14 · 182 km/h » ou « 2:14 · X +0,12  Y −0,03  Z 3,80 ».
    private var readout: String {
        guard let selection else { return "Survole pour lire les valeurs" }
        let values = seriesNames.compactMap { name -> String? in
            guard let point = nearest(in: points.filter { $0.series == name }, to: selection) else { return nil }
            let text = TrackFormat.number(point.value, digits)
            return seriesNames.count > 1 ? "\(name.prefix(1)) \(text)" : text + (unit.isEmpty ? "" : " " + unit)
        }
        return ([TrackFormat.clock(selection)] + values).joined(separator: " · ")
    }

    private func nearest(in points: [SeriesPoint], to time: Double) -> SeriesPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(points[low - 1].time - time) < abs(points[low].time - time) { return points[low - 1] }
        return points[low]
    }
}

/// Diagramme V-n : chaque point est un instant du vol (vitesse, facteur de charge).
struct EnvelopeChartCard: View {
    let points: [TrackPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Domaine de vol (V-n)").font(.headline)
                Text("facteur de charge selon la vitesse").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                RuleMark(y: .value("Repère", 1))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(y: .value("Repère", 0))
                    .foregroundStyle(.secondary.opacity(0.5))
                ForEach(points) { p in
                    PointMark(x: .value("Vitesse (km/h)", p.speedKmh), y: .value("Facteur de charge (g)", p.gZ))
                        .symbolSize(10)
                        .foregroundStyle(VizPalette.series1.opacity(0.45))
                }
            }
            .chartXAxisLabel("km/h")
            .chartYAxisLabel("g")
            .frame(height: 260)
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Tableau

struct CSVTableView: View {
    let table: CSVTable
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [(index: Int, name: String)] {
        table.header.enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        if sizeClass == .compact {
            compactGrid
        } else {
            Table(table.rows) {
                TableColumnForEach(columns, id: \.index) { column in
                    TableColumn(column.name) { row in
                        Text(field(row, column.index)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 110)
                }
            }
        }
    }

    /// iPhone : Table n'y affiche qu'une colonne, on fait donc une grille défilante dans les deux sens.
    private var compactGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(table.rows) { row in
                        line(columns.map { field(row, $0.index) }, isHeader: false)
                    }
                } header: {
                    line(columns.map(\.name), isHeader: true)
                        .background(.bar)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func line(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
    }

    private func field(_ row: CSVTable.Row, _ index: Int) -> String {
        let fields = table.fields(of: row)
        return index < fields.count ? String(fields[index]) : ""
    }
}

// MARK: - Aperçu : vol synthétique

#Preview("Graphiques") {
    let points = (0..<6000).map { i -> TrackPoint in
        let t = Double(i) / 25
        var p = TrackPoint(id: i, time: t)
        p.latitude = 44.0 + 0.004 * sin(t / 20)
        p.longitude = 1.0 + 0.006 * sin(t / 10)
        p.altitude = 900 + 200 * sin(t / 15)
        p.speed = (180 + 70 * cos(t / 15)) / 3.6
        p.gZ = 1 + 3.5 * sin(t / 4) * sin(t / 31)
        p.gX = 0.3 * sin(t / 7)
        p.gY = 0.5 * cos(t / 5)
        p.rollRate = 180 * sin(t / 3)
        p.pitchRate = 60 * cos(t / 6)
        p.yawRate = 20 * sin(t / 9)
        p.satellites = 14 + (i % 300 == 0 ? -2 : 0)
        return p
    }
    let track = FlightTrack(name: "Vol d'essai", startDate: .now, points: points)
    TrackChartsView(track: track, data: TrackChartData(track: track))
        .frame(width: 800, height: 1400)
}

#Preview("Résumé") {
    let points = (0..<3000).map { i -> TrackPoint in
        let t = Double(i) / 25
        var p = TrackPoint(id: i, time: t)
        p.latitude = 44.0 + 0.004 * sin(t / 20)
        p.longitude = 1.0 + 0.006 * sin(t / 10)
        p.altitude = 900 + 200 * sin(t / 15)
        p.speed = (180 + 70 * cos(t / 15)) / 3.6
        p.gZ = 1 + 3.5 * sin(t / 4)
        return p
    }
    let track = FlightTrack(name: "Vol d'essai", startDate: .now, points: points)
    TrackSummaryView(track: track, route: Downsample.stride(points, maxCount: 2000))
        .frame(width: 900, height: 750)
}
