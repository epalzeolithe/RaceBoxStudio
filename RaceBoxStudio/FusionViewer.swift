import MapKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - Volet Fusion GNSS / IMU

/// Troisième visionneuse : rejoue un vol avec la trajectoire GNSS brute et celle de la fusion ESKF,
/// et un avion 3D orienté par l'attitude estimée.
struct FusionViewerPane: View {
    let store: ViewerStore
    let sessions: [RecordingSession]

    private struct RunKey: Hashable {
        let name: String
        let count: Int
        let speedIsThreeD: Bool
        let lateralConstraint: Bool
        /// Identifiant du .fgpx importé, s'il y en a un.
        let fgpx: UUID?
    }

    private struct Routes {
        var raw: [CLLocationCoordinate2D] = []
        var filtered: [CLLocationCoordinate2D] = []
        var smoothed: [CLLocationCoordinate2D] = []
    }

    @State private var showImporter = false
    @State private var result: FusionResult?
    @State private var routes = Routes()
    @State private var isComputing = false
    @State private var failure: String?

    @State private var useSmoother = true
    @State private var speedIsThreeD = true
    @State private var lateralConstraint = true

    @State private var time = 0.0
    @State private var isPlaying = false
    @State private var playbackRate = 1.0
    /// Caméra de poursuite (comme dans iABView) au lieu de la vue orbitale autour de l'avion.
    @State private var chase = true
    /// Vol dont le curseur a déjà été placé au décollage : un changement de réglage ne le déplace pas.
    @State private var positionedKey: String?
    /// Part de la largeur (ou de la hauteur sur iPhone) donnée à la carte ; réglée par la poignée centrale.
    @AppStorage("fusionSplitFraction") private var splitFraction = 0.5
    @State private var worldFrame: LocalFrame?
    @State private var satelliteSpec: SatelliteSpec?
    /// Réglages utilisés par le dernier calcul (écrits dans l'export .fgpx).
    @State private var fusionConfig = FusionConfig()
    @State private var exportFile = ExportFile(text: "")
    @State private var exportName = "fusion"
    @State private var showExporter = false
    @State private var isExporting = false
    @AppStorage("fusionSatellite") private var showsSatellite = true
    @State private var groundAltitude = 0.0
    /// Montage du boîtier, calé au premier passage à 100 km/h (avion à plat).
    @State private var mounting: MountingCalibration?

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Trajectoire affichée : celle du .fgpx importé, sinon celle du CSV ouvert.
    private var activeTrack: FlightTrack? { store.fgpx?.track ?? store.csv?.track }
    /// Fusion relue dans un .fgpx : rien n'est recalculé, les réglages du filtre ne s'appliquent pas.
    private var isImported: Bool { store.fgpx != nil }

    private var runKey: RunKey? {
        activeTrack.map { RunKey(name: $0.name, count: $0.points.count, speedIsThreeD: speedIsThreeD,
                                 lateralConstraint: lateralConstraint, fgpx: store.fgpx?.id) }
    }

    private func openFile(_ url: URL) {
        Task {
            if url.pathExtension.lowercased() == "fgpx" {
                await store.openFGPX(url)
            } else {
                await store.openCSV(url)
            }
        }
    }

    var body: some View {
        Group {
            if let track = activeTrack {
                viewer(track)
                    .navigationSubtitleIfAvailable(track.name)
            } else {
                TrackEmptyState(kind: "CSV ou FGPX", isLoading: store.isLoading, lastFile: store.lastCSVName,
                                reopenLast: { Task { await store.reopenLast(.csv) } }) { showImporter = true }
            }
        }
        .toolbar {
            TrackOpenToolbar(sessions: sessions, open: { showImporter = true },
                             show: { store.show($0, inGPX: false) })
            ToolbarItem {
                Button("Exporter .fgpx", systemImage: "square.and.arrow.up") { Task { await exportFGPX() } }
                    .disabled(result == nil || isExporting || isImported)
                    .help("Exporte la fusion GNSS / IMU (trajectoire corrigée, attitudes, vitesses, accélérations, gyros) dans un fichier .fgpx")
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: ExportFile.fgpxType,
                      defaultFilename: exportName) { outcome in
            if case .failure(let error) = outcome { store.errorMessage = error.localizedDescription }
        }
        // `.data` : l'extension .fgpx n'est déclarée dans aucun type du système, sans lui le sélecteur grise ces fichiers.
        // `.data` : l'extension .fgpx n'est déclarée dans aucun type du système, sans lui le sélecteur grise ces fichiers.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: TrackFileType.csv + [ExportFile.fgpxType, .data]) { result in
            if case .success(let url) = result { openFile(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openFile(url)
            return true
        }
        .task(id: runKey) {
            if let document = store.fgpx {
                adopt(track: document.track, output: document.result, mounting: document.mounting, config: document.config)
            } else {
                await runFusion()
            }
        }
        .onChange(of: activeTrack?.name) {
            isPlaying = false
            time = 0
        }
        .task(id: isPlaying) { await play() }
    }

    // MARK: Export

    /// Génère le .fgpx hors du fil principal (une heure de vol à 25 Hz fait ≈ 90 000 lignes), puis ouvre le panneau d'export.
    private func exportFGPX() async {
        guard let track = store.csv?.track, let result else { return }
        isExporting = true
        defer { isExporting = false }
        let smoothed = useSmoother, mounting = mounting, config = fusionConfig
        let text = await Task.detached(priority: .userInitiated) {
            FGPXExport.text(track: track, result: result, smoothed: smoothed, mounting: mounting, config: config)
        }.value
        exportFile = ExportFile(text: text)
        exportName = track.name
        showExporter = true
    }

    // MARK: Calcul

    private func runFusion() async {
        guard let track = store.csv?.track else {
            result = nil
            return
        }
        var config = FusionConfig()
        config.speedIsThreeD = speedIsThreeD
        config.useNonHolonomic = lateralConstraint
        fusionConfig = config
        isComputing = true
        failure = nil
        let output = await Task.detached(priority: .userInitiated) {
            FusionFilter.run(track: track, config: config)
        }.value
        guard !Task.isCancelled else { return }
        isComputing = false
        guard let output else {
            result = nil
            failure = "Il faut des positions GNSS valides et les mesures de l'IMU (accélérations et gyros) : "
                + "un export CSV RaceBoxStudio ou une session téléchargée convient."
            return
        }
        adopt(track: track, output: output, mounting: MountingCalibration.calibrate(samples: output.smoothed ?? output.filtered),
              config: config)
    }

    /// Met en place un résultat de fusion (calculé ici ou relu dans un .fgpx) : routes de la carte, repère de la scène,
    /// emprise satellite, calage, et curseur au premier point au-dessus de 50 km/h pour un nouveau vol.
    private func adopt(track: FlightTrack, output: FusionResult, mounting newMounting: MountingCalibration?,
                       config: FusionConfig) {
        fusionConfig = config
        failure = nil
        isComputing = false
        routes = Routes(raw: Self.coordinates(track.points.filter(FusionFilter.isUsableFix)),
                        filtered: Self.coordinates(output.filtered),
                        smoothed: output.smoothed.map(Self.coordinates) ?? [])
        let first = output.filtered[0]
        worldFrame = LocalFrame(latitude: first.latitude, longitude: first.longitude, altitude: 0)
        groundAltitude = output.filtered.map(\.altitude).min() ?? 0
        let lats = output.filtered.map(\.latitude), lons = output.filtered.map(\.longitude)
        if let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max(),
           let frame = worldFrame {
            let extent = max((maxLon - minLon) * frame.metersPerDegreeLon, (maxLat - minLat) * frame.metersPerDegreeLat)
            // Mosaïque assez large pour garnir l'horizon, bornée pour garder une résolution exploitable.
            satelliteSpec = SatelliteSpec(key: "\(track.name)-\(track.points.count)",
                                          originLatitude: first.latitude, originLongitude: first.longitude,
                                          centerLatitude: (minLat + maxLat) / 2, centerLongitude: (minLon + maxLon) / 2,
                                          side: min(30_000, max(10_000, extent * 3)))
        }
        mounting = newMounting
        result = output
        let start = output.filtered.first?.time ?? 0
        let end = output.filtered.last?.time ?? start
        let key = "\(track.name)-\(track.points.count)-\(store.fgpx?.id.uuidString ?? "")"
        if positionedKey != key {
            // Nouveau vol : on saute le roulage et on se place au premier point au-dessus de 50 km/h.
            positionedKey = key
            time = output.samples(smoothed: useSmoother).first { $0.groundSpeed * 3.6 > 50 }?.time ?? start
        } else {
            time = min(max(time, start), end)
        }
    }

    private static func thinned<T>(_ items: [T], maxCount: Int = 2000) -> [T] {
        guard items.count > maxCount else { return items }
        let step = Double(items.count) / Double(maxCount)
        return (0..<maxCount).map { items[Int(Double($0) * step)] }
    }

    private static func coordinates(_ points: [TrackPoint]) -> [CLLocationCoordinate2D] {
        thinned(points).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private static func coordinates(_ samples: [FusedSample]) -> [CLLocationCoordinate2D] {
        thinned(samples).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Lecture à vitesse réglable ; s'arrête en fin de vol.
    private func play() async {
        guard isPlaying, let result, let end = result.filtered.last?.time else { return }
        if time >= end { time = result.filtered.first?.time ?? 0 }
        var last = ContinuousClock.now
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let now = ContinuousClock.now
            let elapsed = now - last
            last = now
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            time += seconds * playbackRate
            if time >= end {
                time = end
                isPlaying = false
            }
        }
    }

    // MARK: Affichage

    @ViewBuilder private func viewer(_ track: FlightTrack) -> some View {
        VStack(spacing: 0) {
            controls
            if let result {
                let samples = result.samples(smoothed: useSmoother)
                let index = FusionResult.nearestIndex(in: samples, time: time)
                if samples.isEmpty {
                    Spacer()
                } else {
                    let current = samples[index]
                    panes(track: track, result: result, samples: samples, current: current, index: index)
                    playbackBar(start: samples[0].time, end: samples[samples.count - 1].time)
                    let mountRotation = mounting?.rotation ?? MountingCalibration.identity.rotation
                    // Force spécifique mesurée, ramenée dans les axes de l'avion : z = facteur de charge normal (signé).
                    let raw = track.points[result.pointIndices[index]]
                    let specificForce = mountRotation.inverse.act(SIMD3(raw.gX, raw.gY, raw.gZ) * fusionConfig.accelSign)
                    ReadoutBar(sample: current, angles: Attitude.euler(current.attitude * mountRotation),
                               load: raw.gZ.isFinite ? (normal: specificForce.z, total: simd_length(specificForce)) : nil)
                }
            } else if isComputing {
                ProgressView("Fusion GNSS / IMU…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView("Fusion impossible", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .topTrailing) {
            if isComputing, result != nil { ProgressView().controlSize(.small).padding(12) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { controlItems }
                VStack(alignment: .leading, spacing: 8) { controlItems }
            }
            if isImported, let document = store.fgpx {
                Label("Fusion relue dans un fichier .fgpx (\(document.isSmoothed ? "ESKF + RTS" : "ESKF"), "
                      + "\(document.result.filtered.count.formatted()) échantillons) : rien n'est recalculé.",
                      systemImage: "doc.badge.gearshape")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let diagnostics = result?.diagnostics {
                DiagnosticsLine(diagnostics: diagnostics, smoothed: useSmoother)
            }
            if result != nil { Text(mountingSummary).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var mountingSummary: String {
        guard let mounting else { return "Calage du boîtier non déterminé : la vitesse n'atteint pas 100 km/h." }
        return "Calage du boîtier (avion à plat à \(TrackFormat.number(mounting.speedKmh)) km/h, t = \(TrackFormat.clock(mounting.time))) : "
            + "tangage \(TrackFormat.number(mounting.pitch, 1))° · roulis \(TrackFormat.number(mounting.roll, 1))°"
    }

    @ViewBuilder private var controlItems: some View {
        Picker("Filtre", selection: $useSmoother) {
            Text("ESKF").tag(false)
            Text("ESKF + RTS").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(result?.smoothed == nil || isImported)
        .help("Le lisseur RTS repasse sur tout le vol : il corrige surtout l'attitude dans les virages")
        Toggle("Vitesse GNSS 3D", isOn: $speedIsThreeD)
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(isImported)
            .help("Réglage « Vitesse 3D » du boîtier : la vitesse enregistrée inclut alors la composante verticale")
        Toggle("Pas de dérapage", isOn: $lateralConstraint)
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(isImported)
            .help("Pseudo-mesure : vitesse latérale nulle dans le repère du boîtier (vol coordonné)")
        Toggle("Chase cam", isOn: $chase)
            .toggleStyle(.switch)
            .fixedSize()
            .help("Caméra de poursuite derrière l'avion, qui évolue à sa position réelle")
        Toggle("Satellite", isOn: $showsSatellite)
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!chase)
            .help("Imagerie satellite au sol en chase cam (Apple Plans)")
        Spacer(minLength: 0)
    }

    @ViewBuilder private func panes(track: FlightTrack, result: FusionResult, samples: [FusedSample], current: FusedSample, index: Int) -> some View {
        let rawPoint = track.points[result.pointIndices[index]]
        let rawNow = rawPoint.hasPosition ? CLLocationCoordinate2D(latitude: rawPoint.latitude, longitude: rawPoint.longitude) : nil
        let fusedNow = CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude)
        let map = FusionMapView(raw: routes.raw, fused: useSmoother && !routes.smoothed.isEmpty ? routes.smoothed : routes.filtered,
                                rawNow: rawNow, fusedNow: fusedNow)
            .id(track.name)
        #if os(visionOS)
        map
        #else
        let model = AircraftView(samples: samples, time: time, isPlaying: isPlaying, rate: playbackRate,
                                 frame: worldFrame, groundAltitude: groundAltitude,
                                 mounting: mounting?.rotation ?? MountingCalibration.identity.rotation, chase: chase,
                                 satellite: satelliteSpec, showsSatellite: showsSatellite)
        ResizableSplit(axis: sizeClass == .compact ? .vertical : .horizontal, fraction: $splitFraction) { map } second: { model }
            .padding(.horizontal)
        #endif
    }

    private func playbackBar(start: Double, end: Double) -> some View {
        HStack(spacing: 12) {
            Button(isPlaying ? "Pause" : "Lecture", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                isPlaying.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { min(max(time, start), end) }, set: { time = $0 }), in: start...max(end, start + 1))
            Text("\(TrackFormat.clock(time - start)) / \(TrackFormat.clock(end - start))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Picker("Vitesse de lecture", selection: $playbackRate) {
                ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text("×\(Int($0))").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Poignée de séparation

/// Deux volets côte à côte (ou empilés) séparés par une poignée qu'on glisse pour répartir la place.
/// Double-clic sur la poignée : retour à 50 / 50.
private struct ResizableSplit<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: Double
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    @State private var dragStart: Double?

    private let handleThickness: CGFloat = 14
    private let limits = 0.2...0.8

    var body: some View {
        GeometryReader { proxy in
            let horizontal = axis == .horizontal
            let available = max((horizontal ? proxy.size.width : proxy.size.height) - handleThickness, 1)
            let firstLength = available * min(max(fraction, limits.lowerBound), limits.upperBound)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: horizontal ? firstLength : nil, height: horizontal ? nil : firstLength)
                handle(horizontal: horizontal)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? fraction
                                dragStart = start
                                let delta = horizontal ? value.translation.width : value.translation.height
                                fraction = min(max(start + delta / available, limits.lowerBound), limits.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                second
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handle(horizontal: Bool) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.55))
            .frame(width: horizontal ? 4 : 36, height: horizontal ? 36 : 4)
            .frame(width: horizontal ? handleThickness : nil, height: horizontal ? nil : handleThickness)
            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
            .contentShape(.rect)
            .onTapGesture(count: 2) { withAnimation(.snappy) { fraction = 0.5 } }
            #if os(macOS)
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .help("Glisse pour répartir la place · double-clic : 50 / 50")
            .accessibilityLabel("Séparateur des volets")
    }
}

// MARK: - Diagnostic

private struct DiagnosticsLine: View {
    let diagnostics: FusionDiagnostics
    let smoothed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if diagnostics.yawCorrelation < 0 {
                Label(axisWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !diagnostics.headingInitialized {
                Label("Cap initial inconnu : pas de vitesse GNSS suffisante pour l'initialiser.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var summary: String {
        var parts = ["Écart brut / fusion : \(TrackFormat.number(diagnostics.correctionRMS, 2)) m RMS",
                     "GNSS rejeté : \(diagnostics.rejectedPositions) pos. · \(diagnostics.rejectedVelocities) vit."]
        if diagnostics.saturatedGyroSamples > 0 { parts.append("gyro saturé : \(diagnostics.saturatedGyroSamples)") }
        if diagnostics.yawCorrelation.isFinite { parts.append("cohérence lacet : \(TrackFormat.number(diagnostics.yawCorrelation, 2))") }
        if diagnostics.smoothingSkipped { parts.append("lissage ignoré (vol trop long)") }
        return parts.joined(separator: " · ")
    }

    private var axisWarning: String {
        diagnostics.yawCorrelation.isFinite
            ? "Le gyro Z ne suit pas le cap GNSS : vérifie le sens des axes (FusionConfig.gyroSign / accelSign)."
            : "Pas de virage exploitable pour vérifier le sens des axes du gyro."
    }
}

// MARK: - Carte : trajectoire brute et trajectoire fusionnée

private struct FusionMapView: View {
    let raw: [CLLocationCoordinate2D]
    let fused: [CLLocationCoordinate2D]
    let rawNow: CLLocationCoordinate2D?
    let fusedNow: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .automatic) {
            if raw.count >= 2 {
                MapPolyline(coordinates: raw)
                    .stroke(VizPalette.series2, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if fused.count >= 2 {
                MapPolyline(coordinates: fused)
                    .stroke(VizPalette.series1, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let rawNow {
                Annotation("", coordinate: rawNow) { marker(VizPalette.series2) }
            }
            Annotation("", coordinate: fusedNow) { marker(VizPalette.series1) }
        }
        .mapStyle(.hybrid(elevation: .flat))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topLeading) { legend.padding(10) }
        .frame(minHeight: 220)
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
    }

    /// Pastille + libellé : la couleur ne porte jamais seule l'information.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow("GNSS brut", VizPalette.series2)
            legendRow("Fusion", VizPalette.series1)
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }

    private func legendRow(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 4)
            Text(title)
        }
    }
}

// MARK: - Avion 3D (CAP 10, même modèle que iABView)

#if !os(visionOS)
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformImage = NSImage
private typealias PlatformPan = NSPanGestureRecognizer
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformImage = UIImage
private typealias PlatformPan = UIPanGestureRecognizer
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Emprise de l'imagerie satellite d'un vol : centre de la mosaïque et côté, repère local = premier point.
private struct SatelliteSpec: Equatable {
    let key: String
    let originLatitude: Double
    let originLongitude: Double
    let centerLatitude: Double
    let centerLongitude: Double
    let side: Double
}

#if os(macOS)
/// SCNView qui laisse la molette zoomer la chase cam ; en vue orbitale elle garde le comportement de SceneKit.
private final class OrbitSCNView: SCNView {
    var onScroll: ((Float) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
        if onScroll?(Float(event.scrollingDeltaY * scale)) != true { super.scrollWheel(with: event) }
    }
}
#endif

private struct AircraftView: PlatformViewRepresentable {
    /// Trajectoire fusionnée : la scène interpole elle-même entre échantillons, à la cadence du rendu.
    let samples: [FusedSample]
    let time: Double
    let isPlaying: Bool
    let rate: Double
    let frame: LocalFrame?
    let groundAltitude: Double
    /// Rotation avion → boîtier (calage).
    let mounting: simd_quatd
    let chase: Bool
    let satellite: SatelliteSpec?
    let showsSatellite: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> AircraftScene { AircraftScene() }

    #if os(macOS)
    func makeNSView(context: Context) -> SCNView { makeView(context) }
    func updateNSView(_ view: SCNView, context: Context) { update(view, context) }
    #else
    func makeUIView(context: Context) -> SCNView { makeView(context) }
    func updateUIView(_ view: SCNView, context: Context) { update(view, context) }
    #endif

    private func makeView(_ context: Context) -> SCNView {
        #if os(macOS)
        let view = OrbitSCNView()
        view.onScroll = { [weak coordinator = context.coordinator] delta in coordinator?.handleScroll(delta) ?? false }
        #else
        let view = SCNView()
        #endif
        // Chase cam : glisser fait tourner la caméra autour de l'avion, molette / pincement zoome, double-clic recentre.
        let pan = PlatformPan(target: context.coordinator, action: #selector(AircraftScene.handlePan(_:)))
        view.addGestureRecognizer(pan)
        #if os(macOS)
        let reset = NSClickGestureRecognizer(target: context.coordinator, action: #selector(AircraftScene.handleReset(_:)))
        reset.numberOfClicksRequired = 2
        #else
        let reset = UITapGestureRecognizer(target: context.coordinator, action: #selector(AircraftScene.handleReset(_:)))
        reset.numberOfTapsRequired = 2
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,
                                                           action: #selector(AircraftScene.handlePinch(_:))))
        #endif
        view.addGestureRecognizer(reset)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.orbitCamera
        view.antialiasingMode = .multisampling4X
        // Orbite autour de l'avion ; sans `automaticTarget = false`, SceneKit recentre la vue sur l'objet touché.
        view.allowsCameraControl = true
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        view.autoenablesDefaultLighting = false
        // L'hélice tourne en continu.
        // C'est le rendu (60 Hz) qui pilote l'avion et la caméra : lecture fluide, indépendante des ticks de l'interface.
        view.delegate = context.coordinator
        view.isPlaying = true
        view.preferredFramesPerSecond = 60
        view.clipsToBounds = true
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        #else
        view.layer.cornerRadius = 12
        #endif
        return view
    }

    private func update(_ view: SCNView, _ context: Context) {
        let scene = context.coordinator
        scene.setBackground(dark: colorScheme == .dark)
        scene.setMode(chase: chase, view: view)
        scene.configureSatellite(satellite, enabled: chase && showsSatellite)
        scene.feed(samples: samples, frame: frame, groundAltitude: groundAltitude, mounting: mounting)
        scene.sync(time: time, isPlaying: isPlaying, rate: rate)
        view.backgroundColor = PlatformColor(hex: colorScheme == .dark ? 0x1A1A19 : 0xE9EEF3)
    }
}

/// Scène : x = est, y = haut, z = −nord (comme la vue de trajectoire). Au repos l'avion vole cap nord, à plat.
private nonisolated final class AircraftScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene = SCNScene()
    private let aircraft = SCNNode()
    private let disc = SCNNode()
    let orbitCamera = SCNNode()
    private let chaseCamera = SCNNode()
    /// Disque d'horizon et repères cardinaux : vue orbitale seulement.
    private let orbitGroup = SCNNode()
    private let ground = SCNNode()
    private let trailNode = SCNNode()
    private var grid: SCNNode?
    private var isChase = false
    private var isDark = false
    private var needsCameraSnap = true
    private var cameraPosition = SIMD3<Float>.zero
    private var chaseHeading: Float = 0
    private var hasChaseHeading = false
    private var lastChaseTime: TimeInterval?

    // Lecture : l'interface donne le temps (≈ 20 Hz) ; le rendu (60 Hz) en déduit l'instant exact avec une horloge murale
    // et interpole position et attitude entre deux échantillons de 25 Hz.
    private let lock = NSLock()
    private var samples: [FusedSample] = []
    private var frame: LocalFrame?
    private var groundAltitude = 0.0
    private var mounting = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var uiTime = 0.0
    private var anchorTime = 0.0
    private var anchorUptime = 0.0
    private var playing = false
    private var rate = 1.0
    private var lastRenderedTime = -Double.infinity
    /// Dernier point (centre, bouts d'aile) de la traînée figée : le segment « tête » le relie à l'avion à chaque image.
    private var lastTrailTip: (center: SIMD3<Float>, left: SIMD3<Float>, right: SIMD3<Float>)?
    private let headNode = SCNNode()
    /// Demi-envergure en chase cam : 2,1 unités du modèle × l'échelle réelle (×2).
    private static let wingHalfSpan: Float = 4.2
    private static let trailDuration = 15.0
    /// Un segment relie les deux bouts d'aile à chaque multiple de cet intervalle (s).
    private static let rungInterval = 0.25
    private var lastTrailUptime: TimeInterval = 0
    private var lastDetailUptime: TimeInterval = 0

    // Rotation manuelle de la chase cam : azimut et élévation ajoutés au cadrage, zoom (logarithme de la distance).
    private let orbitLock = NSLock()
    private var orbitYaw: Float = 0
    private var orbitPitch: Float = 0
    private var orbitZoom: Float = 0

    private func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }

    @objc func handlePan(_ recognizer: PlatformPan) {
        let translation = recognizer.translation(in: recognizer.view)
        #if os(macOS)
        let delta = SIMD2<Float>(Float(translation.x), Float(translation.y))
        #else
        let delta = SIMD2<Float>(Float(translation.x), -Float(translation.y))
        #endif
        recognizer.setTranslation(.zero, in: recognizer.view)
        guard isChase else { return }
        orbitLock.lock()
        defer { orbitLock.unlock() }
        // La caméra suit la souris : vers la droite → côté droit de l'avion, vers le haut → plus haut.
        var yaw = orbitYaw - delta.x * 0.008
        if yaw > .pi { yaw -= 2 * .pi }
        if yaw < -.pi { yaw += 2 * .pi }
        orbitYaw = yaw
        orbitPitch = clamp(orbitPitch + delta.y * 0.006, -0.5, 1.2)
    }

    /// Molette : zoome en chase cam. Renvoie vrai si l'événement est consommé.
    func handleScroll(_ delta: Float) -> Bool {
        guard isChase else { return false }
        orbitLock.lock()
        defer { orbitLock.unlock() }
        orbitZoom = clamp(orbitZoom - delta, -1.2, 1.5)
        return true
    }

    #if !os(macOS)
    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard isChase else { return }
        orbitLock.lock()
        orbitZoom = clamp(orbitZoom - log(Float(recognizer.scale)), -1.2, 1.5)
        orbitLock.unlock()
        recognizer.scale = 1
    }
    #endif

    /// Double-clic : retour au cadrage de poursuite.
    @objc func handleReset(_ recognizer: AnyObject) {
        orbitLock.lock()
        orbitYaw = 0
        orbitPitch = 0
        orbitZoom = 0
        orbitLock.unlock()
    }

    // Imagerie satellite : mosaïque générale (≈ 6 m/pixel) + tuiles fines de 800 m autour de l'avion à basse altitude.
    private let satelliteNode = SCNNode()
    private let detailNode = SCNNode()
    private var satelliteSpec: SatelliteSpec?
    private var satelliteEnabled = false
    private var satelliteStarted = false
    private var hasSatelliteTiles = false
    private var satelliteTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailTiles: [SIMD2<Int>: SCNNode] = [:]
    private var detailFailures: [SIMD2<Int>: TimeInterval] = [:]
    private var isFetchingDetail = false
    private var detailGeneration = 0
    private var lastDetailCell = SIMD2<Int>(0, 0)
    private static let detailCellSide = 800.0
    private static let detailMaxAltitude: Float = 600
    private static let detailMaxTiles = 16
    /// L'avion est agrandi à l'échelle réelle (le modèle fait 4,2 unités d'envergure pour 8,4 m) en chase cam.
    private static let chaseModelScale: Float = 2
    private static let chaseDistance: Float = 32
    private static let chaseElevation: Float = 14 * .pi / 180
    private static let gridSpacing: Float = 100

    /// ENU → scène.
    private static let toScene = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)))
    /// Boîtier (avant, gauche, haut) → ENU pour un vol à plat cap nord.
    private static let reference = simd_double3x3(columns: (SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)))

    override init() {
        super.init()
        // Le modèle (après AircraftModelLoader) a le nez vers +Y et le dessus vers +Z : −90° autour de X
        // l'amène nez vers −Z, dessus vers +Y.
        let modelRoot = SCNNode()
        modelRoot.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        if let model = try? AircraftModelLoader.makeNode() { modelRoot.addChildNode(model) }
        aircraft.addChildNode(modelRoot)
        scene.rootNode.addChildNode(aircraft)
        orbitGroup.addChildNode(makeHorizon())
        orbitGroup.addChildNode(disc)
        scene.rootNode.addChildNode(orbitGroup)
        configureCameras()
        configureGround()
        for node in [satelliteNode, detailNode] {
            node.eulerAngles.x = -.pi / 2   // à plat : x local = est, y local = nord
            node.isHidden = true
            scene.rootNode.addChildNode(node)
        }
        trailNode.isHidden = true
        scene.rootNode.addChildNode(trailNode)
        headNode.isHidden = true
        scene.rootNode.addChildNode(headNode)
        scene.rootNode.addChildNode(makeLights())
    }

    func feed(samples: [FusedSample], frame: LocalFrame?, groundAltitude: Double, mounting: simd_quatd) {
        lock.lock()
        defer { lock.unlock() }
        self.samples = samples
        self.frame = frame
        self.groundAltitude = groundAltitude
        self.mounting = mounting
    }

    /// Recale l'horloge de lecture seulement si elle dérive de l'interface (saut du curseur, changement de vitesse).
    func sync(time: Double, isPlaying: Bool, rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let predicted = anchorTime + (now - anchorUptime) * self.rate
        if isPlaying != playing || rate != self.rate || !isPlaying || abs(predicted - time) > 0.25 {
            anchorTime = time
            anchorUptime = now
        }
        uiTime = time
        playing = isPlaying
        self.rate = rate
    }

    /// Scène : x = est, y = altitude au-dessus du point le plus bas du vol, z = −nord.
    private static func scenePosition(_ s: FusedSample, frame: LocalFrame, ground: Double) -> SIMD3<Float> {
        let p = frame.enu(latitude: s.latitude, longitude: s.longitude, altitude: s.altitude)
        return SIMD3(Float(p.x), Float(p.z - ground), Float(-p.y))
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime systemTime: TimeInterval) {
        lock.lock()
        let samples = samples, frame = frame, ground = groundAltitude, mount = mounting
        let playing = playing, rate = rate, uiTime = uiTime, anchorTime = anchorTime, anchorUptime = anchorUptime
        lock.unlock()
        guard let first = samples.first, let last = samples.last, let frame else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let t = min(max(playing ? anchorTime + (now - anchorUptime) * rate : uiTime, first.time), last.time)

        // Échantillons encadrant l'instant, puis interpolation (position, vitesse, attitude).
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < t { low = mid + 1 } else { high = mid }
        }
        let b = samples[low], a = samples[max(low - 1, 0)]
        let span = b.time - a.time
        let f = span > 1e-6 ? min(max((t - a.time) / span, 0), 1) : 0
        let attitude = simd_slerp(a.attitude, b.attitude, f)
        setAttitude(attitude, mounting: mount)
        guard isChase else { lastRenderedTime = t; return }

        let pa = Self.scenePosition(a, frame: frame, ground: ground), pb = Self.scenePosition(b, frame: frame, ground: ground)
        let position = pa + (pb - pa) * Float(f)
        let va = SIMD3(Float(a.velocity.x), Float(a.velocity.z), Float(-a.velocity.y))
        let vb = SIMD3(Float(b.velocity.x), Float(b.velocity.z), Float(-b.velocity.y))
        let velocity = va + (vb - va) * Float(f)

        // Curseur déplacé : la caméra se recale au lieu de traverser la scène.
        if abs(t - lastRenderedTime) > 0.5 { needsCameraSnap = true }
        lastRenderedTime = t

        // Traînées du centre et des deux bouts d'aile sur 15 s, recalculées à 10 Hz ; la tête suit l'avion à chaque image.
        if now - lastTrailUptime > 0.1 {
            lastTrailUptime = now
            rebuildTrails(samples: samples, upTo: low, time: t, frame: frame, ground: ground, mounting: mount)
        }
        updateChase(position: position, velocity: velocity, groundY: 0)
        updateTrailHead(position: position, orientation: Self.sceneQuat(attitude, mounting: mount))

        if now - lastDetailUptime > 0.5 {
            lastDetailUptime = now
            DispatchQueue.main.async { [weak self] in self?.updateDetailTiles(around: position) }
        }
    }

    /// Orientation de l'avion dans la scène : attitude du boîtier composée avec le calage.
    private static func sceneQuat(_ attitude: simd_quatd, mounting: simd_quatd) -> simd_quatf {
        let mounted = attitude * mounting
        let m = toScene * simd_matrix3x3(mounted) * reference.transpose * toScene.transpose
        let q = simd_quatd(m).normalized
        return simd_quatf(vector: SIMD4<Float>(q.vector))
    }

    func setAttitude(_ attitude: simd_quatd, mounting: simd_quatd) {
        let orientation = Self.sceneQuat(attitude, mounting: mounting)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        aircraft.simdOrientation = orientation
        SCNTransaction.commit()
    }

    func setBackground(dark: Bool) {
        isDark = dark
        applyBackground()
        disc.geometry?.firstMaterial?.diffuse.contents = PlatformColor(hex: dark ? 0x5A5955 : 0x9A9893)
    }

    private func applyBackground() {
        // Ciel de la chase cam : celui de iABView.
        let sky = PlatformColor(red: 0.35, green: 0.48, blue: 0.60, alpha: 1)
        scene.background.contents = isChase ? sky : PlatformColor(hex: isDark ? 0x1A1A19 : 0xE9EEF3)
        // Le sol se fond dans le ciel au loin : un horizon net, à la bonne hauteur (sans brouillard en vue orbitale).
        scene.fogColor = sky
        scene.fogStartDistance = isChase ? 9_000 : 0
        scene.fogEndDistance = isChase ? 50_000 : 0
    }

    func setMode(chase: Bool, view: SCNView) {
        guard chase != isChase else { return }
        isChase = chase
        orbitGroup.isHidden = chase
        ground.isHidden = !chase
        trailNode.isHidden = !chase
        headNode.isHidden = !chase
        lastTrailTip = nil
        aircraft.simdScale = SIMD3<Float>(repeating: chase ? Self.chaseModelScale : 1)
        if !chase { aircraft.simdPosition = .zero }
        // En chase cam la caméra est pilotée ici ; en vue orbitale, par la souris.
        view.allowsCameraControl = !chase
        view.pointOfView = chase ? chaseCamera : orbitCamera
        needsCameraSnap = true
        hasChaseHeading = false
        lastChaseTime = nil
        applyBackground()
    }

    /// Place l'avion à sa position, suit sa route sol avec une caméra lissée, et trace les 15 dernières secondes.
    func updateChase(position: SIMD3<Float>, velocity: SIMD3<Float>, groundY: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.25, max(0, now - (lastChaseTime ?? now))))
        lastChaseTime = now

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        aircraft.simdPosition = position
        // Le sol suit l'avion par pas de 100 m : la grille paraît infinie.
        ground.simdPosition = SIMD3(
            (position.x / Self.gridSpacing).rounded() * Self.gridSpacing, -0.05,
            (position.z / Self.gridSpacing).rounded() * Self.gridSpacing)

        // Cap de poursuite : route sol lissée (la caméra reste derrière la trajectoire, pas derrière le nez).
        if simd_length(SIMD2(velocity.x, velocity.z)) > 5 {
            let target = atan2(velocity.x, -velocity.z)
            if hasChaseHeading, !needsCameraSnap {
                var delta = (target - chaseHeading).truncatingRemainder(dividingBy: 2 * .pi)
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                chaseHeading += delta * (1 - exp(-dt / 1.0))
            } else {
                chaseHeading = target
            }
            hasChaseHeading = true
        }
        orbitLock.lock()
        let yaw = orbitYaw, pitch = orbitPitch, zoom = orbitZoom
        orbitLock.unlock()
        let azimuth = chaseHeading + yaw
        let elevation = Self.chaseElevation + pitch
        let back = SIMD3(-sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        var desired = position + back * Self.chaseDistance * exp(zoom)
        desired.y = max(desired.y, 2)   // jamais sous le sol
        // Saut (curseur déplacé) : la caméra se recale au lieu de traverser la scène.
        if needsCameraSnap || simd_distance(desired, cameraPosition) > 120 {
            cameraPosition = desired
            needsCameraSnap = false
        } else {
            cameraPosition += (desired - cameraPosition) * (1 - exp(-dt / 0.5))
        }
        chaseCamera.simdPosition = cameraPosition
        // Caméra sans roulis : l'horizon reste horizontal quoi que fasse l'avion.
        chaseCamera.simdLook(at: position, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        SCNTransaction.commit()
    }

    // MARK: Traînées

    private static let centerColor = SIMD3<Float>(0xEB, 0x68, 0x34) / 255
    private static let leftColor = SIMD3<Float>(0xE3, 0x49, 0x48) / 255
    private static let rightColor = SIMD3<Float>(0x1B, 0xAF, 0x7A) / 255
    private static let rungColor = SIMD3<Float>(1, 1, 1)

    /// Segments à couleur par sommet (alpha = fondu avec l'âge) ; sans éclairage ni écriture de profondeur.
    private static func lineGeometry(_ vertices: [SCNVector3], _ colors: [Float]) -> SCNGeometry? {
        guard vertices.count > 1 else { return nil }
        let colorSource = SCNGeometrySource(
            data: colors.withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)
        let element = SCNGeometryElement(indices: vertices.indices.map(Int32.init), primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colorSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.writesToDepthBuffer = false
        return geometry
    }

    /// Traînée du centre (orange), des bouts d'aile gauche (rouge) et droit (vert), et un segment entre les bouts
    /// d'aile à chaque multiple de 0,25 s du temps du vol (ancrés au temps : ils ne glissent pas avec la fenêtre).
    private func rebuildTrails(samples: [FusedSample], upTo upper: Int, time t: Double, frame: LocalFrame,
                               ground: Double, mounting: simd_quatd) {
        var start = upper
        while start > 0, samples[start - 1].time > t - Self.trailDuration { start -= 1 }
        guard upper - start >= 2 else {
            trailNode.geometry = nil
            lastTrailTip = nil
            return
        }
        var vertices: [SCNVector3] = []
        var colors: [Float] = []
        func segment(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ color: SIMD3<Float>, _ alpha: Float) {
            vertices += [SCNVector3(from), SCNVector3(to)]
            colors += [color.x, color.y, color.z, alpha, color.x, color.y, color.z, alpha]
        }
        var previous: (center: SIMD3<Float>, left: SIMD3<Float>, right: SIMD3<Float>)?
        for k in start..<upper {
            let sample = samples[k]
            let isRung = k == start
                || Int((sample.time / Self.rungInterval).rounded(.down)) != Int((samples[k - 1].time / Self.rungInterval).rounded(.down))
            let isLinePoint = (k - start) % 2 == 0 || k == upper - 1
            guard isRung || isLinePoint else { continue }
            let center = Self.scenePosition(sample, frame: frame, ground: ground)
            let wing = Self.sceneQuat(sample.attitude, mounting: mounting).act(SIMD3<Float>(1, 0, 0)) * Self.wingHalfSpan
            let tip = (center: center, left: center - wing, right: center + wing)
            let alpha = Float(max(0, 1 - (t - sample.time) / Self.trailDuration))
            if isRung { segment(tip.left, tip.right, Self.rungColor, alpha * 0.7) }
            if isLinePoint {
                if let previous {
                    segment(previous.center, tip.center, Self.centerColor, alpha)
                    segment(previous.left, tip.left, Self.leftColor, alpha)
                    segment(previous.right, tip.right, Self.rightColor, alpha)
                }
                previous = tip
            }
        }
        lastTrailTip = previous
        trailNode.geometry = Self.lineGeometry(vertices, colors)
    }

    /// Relie la traînée figée à la position actuelle de l'avion (rafraîchi à chaque image).
    private func updateTrailHead(position: SIMD3<Float>, orientation: simd_quatf) {
        guard let last = lastTrailTip else {
            headNode.geometry = nil
            return
        }
        let wing = orientation.act(SIMD3<Float>(1, 0, 0)) * Self.wingHalfSpan
        var vertices: [SCNVector3] = []
        var colors: [Float] = []
        for (from, to, color) in [(last.center, position, Self.centerColor),
                                  (last.left, position - wing, Self.leftColor),
                                  (last.right, position + wing, Self.rightColor)] {
            vertices += [SCNVector3(from), SCNVector3(to)]
            colors += [color.x, color.y, color.z, 1, color.x, color.y, color.z, 1]
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        headNode.geometry = Self.lineGeometry(vertices, colors)
        SCNTransaction.commit()
    }

    // MARK: Imagerie satellite

    func configureSatellite(_ spec: SatelliteSpec?, enabled: Bool) {
        satelliteEnabled = enabled
        if spec != satelliteSpec {
            satelliteSpec = spec
            resetSatellite()
        }
        if enabled, spec != nil, !satelliteStarted { startSatellite() }
        satelliteNode.isHidden = !(enabled && hasSatelliteTiles)
        detailNode.isHidden = !enabled
        // La grille ne sert que sans imagerie.
        grid?.isHidden = enabled && hasSatelliteTiles
    }

    private func resetSatellite() {
        satelliteTask?.cancel()
        detailTask?.cancel()
        detailGeneration += 1
        satelliteStarted = false
        hasSatelliteTiles = false
        isFetchingDetail = false
        detailTiles.removeAll()
        detailFailures.removeAll()
        satelliteNode.childNodes.forEach { $0.removeFromParentNode() }
        detailNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    private static func tileMaterial(_ image: PlatformImage) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = image
        material.diffuse.mipFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.maxAnisotropy = 8
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        return material
    }

    /// Mosaïque de petits instantanés (MapKit ne charge l'imagerie complète que sur de petites emprises),
    /// du centre vers l'extérieur, pour que le sol soit texturé jusqu'à l'horizon.
    private func startSatellite() {
        guard let spec = satelliteSpec else { return }
        satelliteStarted = true
        let frame = LocalFrame(latitude: spec.originLatitude, longitude: spec.originLongitude, altitude: 0)
        let centerEast = (spec.centerLongitude - spec.originLongitude) * frame.metersPerDegreeLon
        let centerNorth = (spec.centerLatitude - spec.originLatitude) * frame.metersPerDegreeLat
        satelliteNode.simdPosition = SIMD3(Float(centerEast), -0.1, Float(-centerNorth))

        #if os(macOS)
        let gridSize = 5
        #else
        let gridSize = 3
        #endif
        let tileSide = spec.side / Double(gridSize)
        var offsets: [(east: Double, north: Double)] = []
        for column in 0..<gridSize {
            for row in 0..<gridSize {
                offsets.append(((Double(column) - Double(gridSize - 1) / 2) * tileSide,
                                (Double(row) - Double(gridSize - 1) / 2) * tileSide))
            }
        }
        offsets.sort { hypot($0.east, $0.north) < hypot($1.east, $1.north) }

        satelliteTask = Task { @MainActor [weak self] in
            for offset in offsets {
                if Task.isCancelled { return }
                let options = MKMapSnapshotter.Options()
                options.region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: spec.centerLatitude + offset.north / frame.metersPerDegreeLat,
                        longitude: spec.centerLongitude + offset.east / frame.metersPerDegreeLon),
                    latitudinalMeters: tileSide, longitudinalMeters: tileSide)
                options.mapType = .satellite
                options.size = CGSize(width: 1_024, height: 1_024)
                // Une tuile qui échoue laisse un trou sans bloquer les suivantes.
                guard let snapshot = try? await MKMapSnapshotter(options: options).start(),
                      !Task.isCancelled, let self, self.satelliteSpec == spec else { continue }
                let plane = SCNPlane(width: tileSide, height: tileSide)
                plane.materials = [Self.tileMaterial(snapshot.image)]
                let tile = SCNNode(geometry: plane)
                tile.renderingOrder = -2
                tile.simdPosition = SIMD3(Float(offset.east), Float(offset.north), 0)
                self.satelliteNode.addChildNode(tile)
                self.hasSatelliteTiles = true
                self.satelliteNode.isHidden = !self.satelliteEnabled
                self.grid?.isHidden = self.satelliteEnabled
            }
        }
    }

    /// À basse altitude : tuiles 3 × 3 de 800 m autour de l'avion (≈ 0,8 m/pixel) par-dessus la mosaïque générale.
    private func updateDetailTiles(around position: SIMD3<Float>) {
        guard satelliteEnabled, let spec = satelliteSpec, !isFetchingDetail,
              position.y < Self.detailMaxAltitude else { return }
        let side = Self.detailCellSide
        let center = SIMD2<Int>(Int((Double(position.x) / side).rounded()), Int((Double(-position.z) / side).rounded()))
        lastDetailCell = center
        let now = ProcessInfo.processInfo.systemUptime
        var cells: [SIMD2<Int>] = []
        for dx in -1...1 {
            for dy in -1...1 {
                let cell = SIMD2(center.x + dx, center.y + dy)
                if detailTiles[cell] != nil { continue }
                if let failed = detailFailures[cell], now - failed < 30 { continue }
                cells.append(cell)
            }
        }
        guard !cells.isEmpty else { return }
        cells.sort { abs($0.x - center.x) + abs($0.y - center.y) < abs($1.x - center.x) + abs($1.y - center.y) }
        isFetchingDetail = true
        let generation = detailGeneration
        let frame = LocalFrame(latitude: spec.originLatitude, longitude: spec.originLongitude, altitude: 0)
        detailNode.simdPosition = SIMD3(0, -0.05, 0)
        detailTask = Task { @MainActor [weak self] in
            for cell in cells {
                if Task.isCancelled { return }
                let options = MKMapSnapshotter.Options()
                options.region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: spec.originLatitude + Double(cell.y) * side / frame.metersPerDegreeLat,
                        longitude: spec.originLongitude + Double(cell.x) * side / frame.metersPerDegreeLon),
                    latitudinalMeters: side, longitudinalMeters: side)
                options.mapType = .satellite
                options.size = CGSize(width: 1_024, height: 1_024)
                let snapshot = try? await MKMapSnapshotter(options: options).start()
                guard !Task.isCancelled, let self, self.detailGeneration == generation else { return }
                guard let snapshot else {
                    self.detailFailures[cell] = ProcessInfo.processInfo.systemUptime
                    continue
                }
                let plane = SCNPlane(width: side, height: side)
                let material = Self.tileMaterial(snapshot.image)
                // Par-dessus la mosaïque, sans test de profondeur : pas de scintillement au loin.
                material.readsFromDepthBuffer = false
                material.writesToDepthBuffer = false
                plane.materials = [material]
                let tile = SCNNode(geometry: plane)
                tile.renderingOrder = -1
                tile.simdPosition = SIMD3(Float(Double(cell.x) * side), Float(Double(cell.y) * side), 0)
                self.detailNode.addChildNode(tile)
                self.detailTiles[cell] = tile
                self.detailFailures[cell] = nil
                // Garde les tuiles les plus proches de l'avion pour borner la mémoire.
                while self.detailTiles.count > Self.detailMaxTiles {
                    guard let farthest = self.detailTiles.keys.max(by: {
                        abs($0.x - self.lastDetailCell.x) + abs($0.y - self.lastDetailCell.y)
                            < abs($1.x - self.lastDetailCell.x) + abs($1.y - self.lastDetailCell.y)
                    }) else { break }
                    self.detailTiles[farthest]?.removeFromParentNode()
                    self.detailTiles[farthest] = nil
                }
            }
            self?.isFetchingDetail = false
        }
    }

    /// Sol : plan sombre et grille de 100 m, recentrés sur l'avion.
    private func configureGround() {
        let plane = SCNPlane(width: 160_000, height: 160_000)
        plane.firstMaterial?.diffuse.contents = PlatformColor(hex: 0x4B5A3C)
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.isDoubleSided = true
        let floor = SCNNode(geometry: plane)
        floor.eulerAngles.x = -.pi / 2
        // Sous l'imagerie satellite (à y = −0,1 m) : il ne sert que de fond au-delà de la mosaïque.
        floor.simdPosition = SIMD3(0, -1.5, 0)
        ground.addChildNode(floor)
        let half: Float = 2_500
        var vertices: [SCNVector3] = []
        var line = -half
        while line <= half {
            vertices += [SCNVector3(line, 0.02, -half), SCNVector3(line, 0.02, half),
                         SCNVector3(-half, 0.02, line), SCNVector3(half, 0.02, line)]
            line += Self.gridSpacing
        }
        let element = SCNGeometryElement(indices: vertices.indices.map(Int32.init), primitiveType: .line)
        let grid = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        grid.firstMaterial?.diffuse.contents = PlatformColor(hex: 0x6F8059)
        grid.firstMaterial?.lightingModel = .constant
        let gridNode = SCNNode(geometry: grid)
        ground.addChildNode(gridNode)
        self.grid = gridNode
        ground.isHidden = true
        scene.rootNode.addChildNode(ground)
    }

    /// Disque d'horizon fixe sous l'avion, nord en rouge : l'avion tourne par rapport à lui.
    private func makeHorizon() -> SCNNode {
        let root = SCNNode()
        let y: Float = -1.6
        let plate = SCNCylinder(radius: 3.4, height: 0.01)
        plate.firstMaterial?.lightingModel = .constant
        plate.firstMaterial?.isDoubleSided = true
        plate.firstMaterial?.transparency = 0.35
        plate.firstMaterial?.writesToDepthBuffer = false
        disc.geometry = plate
        disc.simdPosition = SIMD3<Float>(0, y, 0)
        let ticks: [(SIMD3<Float>, CGFloat, CGFloat, UInt32)] = [
            ([0, y, -3.4], 0.12, 0.6, 0xE34948),  // nord
            ([3.4, y, 0], 0.6, 0.12, 0x8A8984),   // est
            ([0, y, 3.4], 0.12, 0.6, 0x8A8984),   // sud
            ([-3.4, y, 0], 0.6, 0.12, 0x8A8984),  // ouest
        ]
        for (position, width, length, hex) in ticks {
            let box = SCNBox(width: width, height: 0.03, length: length, chamferRadius: 0)
            box.firstMaterial?.diffuse.contents = PlatformColor(hex: hex)
            box.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: box)
            node.simdPosition = position
            root.addChildNode(node)
        }
        return root
    }

    private func configureCameras() {
        let orbit = SCNCamera()
        orbit.fieldOfView = 40
        orbit.zNear = 0.1
        orbit.zFar = 100
        orbitCamera.camera = orbit
        // Vue de derrière et de dessus, légèrement de côté.
        orbitCamera.simdPosition = SIMD3<Float>(4.2, 3.0, 7.0)
        orbitCamera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(orbitCamera)

        let chase = SCNCamera()
        chase.fieldOfView = 55
        chase.zNear = 1
        chase.zFar = 80_000
        chaseCamera.camera = chase
        scene.rootNode.addChildNode(chaseCamera)
    }

    private func makeLights() -> SCNNode {
        let root = SCNNode()
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1_650
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-0.75, 0.65, -0.25)
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 520
        fill.color = PlatformColor(red: 0.72, green: 0.82, blue: 1, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.45, -1.05, 0.35)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 260
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        [sunNode, fillNode, ambientNode].forEach(root.addChildNode)
        return root
    }
}
#endif

// MARK: - Bandeau de valeurs

private struct ReadoutBar: View {
    let sample: FusedSample
    /// Attitude de l'avion (boîtier + calage), en degrés.
    let angles: (heading: Double, pitch: Double, roll: Double)
    /// Facteur de charge en g : normal (axe vertical de l'avion, signé) et total (norme de la force spécifique).
    let load: (normal: Double, total: Double)?

    var body: some View {
        HStack(spacing: 8) {
            Readout(title: "Cap", value: String(format: "%03.0f°", angles.heading))
            Readout(title: "Tangage", value: String(format: "%+.1f°", angles.pitch))
            Readout(title: "Roulis", value: String(format: "%+.1f°", angles.roll))
            Readout(title: "Charge", value: load.map { String(format: "%+.1f g", $0.normal) } ?? "—",
                    detail: load.map { String(format: "total %.1f g", $0.total) })
            Readout(title: "Vitesse", value: String(format: "%.0f km/h", sample.groundSpeed * 3.6),
                    detail: String(format: "%.0f kt", sample.groundSpeed * 1.943_84))
            Readout(title: "Altitude", value: String(format: "%.0f m", sample.altitude),
                    detail: String(format: "%.0f ft", sample.altitude * 3.280_84))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct Readout: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail ?? " ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
