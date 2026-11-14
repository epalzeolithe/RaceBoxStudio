import MapKit
import RealityKit
import SwiftUI

// MARK: - Volet GPX

struct GPXViewerPane: View {
    let store: ViewerStore
    let sessions: [RecordingSession]

    @State private var colorMode = TrajectoryColorMode.speed
    @State private var exaggeration = 1.0
    @State private var resetToken = 0
    @State private var showImporter = false
    /// Imagerie satellite plaquée au sol, téléchargée une fois par trajectoire.
    @State private var satellite = false
    @State private var satelliteImage: CGImage?
    @State private var isLoadingSatellite = false

    var body: some View {
        Group {
            if let track = store.gpx {
                viewer(track)
                    .navigationSubtitleIfAvailable(track.name)
            } else {
                TrackEmptyState(kind: "GPX", isLoading: store.isLoading, lastFile: store.lastGPXName,
                                reopenLast: { Task { await store.reopenLast(.gpx) } }) { showImporter = true }
            }
        }
        .toolbar { TrackOpenToolbar(sessions: sessions, open: { showImporter = true },
                                    show: { store.show($0, inGPX: true) }) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: TrackFileType.gpx) { result in
            if case .success(let url) = result { Task { await store.openGPX(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.openGPX(url) }
            return true
        }
        .onChange(of: store.gpx?.name) {
            // Le facteur de charge n'existe pas dans un GPX classique.
            if colorMode == .loadFactor, store.gpx?.hasAcceleration != true { colorMode = .speed }
            satelliteImage = nil
        }
        .task(id: "\(store.gpx?.name ?? "")-\(satellite)") { await loadSatelliteIfNeeded() }
    }

    private func loadSatelliteIfNeeded() async {
        guard satellite, satelliteImage == nil, let track = store.gpx,
              let layout = TrajectoryScene.Layout(track: track) else { return }
        isLoadingSatellite = true
        defer { isLoadingSatellite = false }
        do {
            satelliteImage = try await TrajectoryScene.satelliteImage(region: layout.groundRegion)
        } catch {
            satellite = false
            store.errorMessage = "Imagerie satellite indisponible : \(error.localizedDescription)"
        }
    }

    private func viewer(_ track: FlightTrack) -> some View {
        VStack(spacing: 0) {
            controls(track)
            ZStack(alignment: .bottomLeading) {
                #if os(visionOS)
                TrackMapView(route: Downsample.stride(track.points.filter(\.hasPosition), maxCount: 2000))
                #else
                Trajectory3DView(track: track, colorMode: colorMode, exaggeration: exaggeration,
                                 groundImage: satellite ? satelliteImage : nil)
                    .id("\(track.name)-\(colorMode)-\(exaggeration)-\(resetToken)-\(satellite && satelliteImage != nil)")
                #endif
                TrajectoryLegend(track: track, colorMode: colorMode)
                    .padding(12)
            }
            statsStrip(track)
        }
    }

    private func controls(_ track: FlightTrack) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { controlItems(track) }
            VStack(alignment: .leading, spacing: 8) { controlItems(track) }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func controlItems(_ track: FlightTrack) -> some View {
        Picker("Couleur", selection: $colorMode) {
            ForEach(TrajectoryColorMode.allCases.filter { $0 != .loadFactor || track.hasAcceleration }) {
                Text($0.title).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        HStack {
            Text("Relief ×\(exaggeration.formatted(.number.precision(.fractionLength(0))))")
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)
            Slider(value: $exaggeration, in: 1...5, step: 1)
                .frame(minWidth: 100, maxWidth: 180)
        }
        .help("Exagère les altitudes pour mieux voir les figures")
        HStack(spacing: 6) {
            Toggle("Satellite", isOn: $satellite)
                .toggleStyle(.switch)
                .fixedSize()
            if isLoadingSatellite { ProgressView().controlSize(.small) }
        }
        .help("Plaque au sol l'imagerie satellite haute résolution d'Apple Plans")
        Spacer(minLength: 0)
        Button("Recentrer", systemImage: "scope") { resetToken += 1 }
    }

    private func statsStrip(_ track: FlightTrack) -> some View {
        let s = track.stats
        let items: [(String, String)] = [
            ("Durée", TrackFormat.clock(s.duration)),
            ("Distance", TrackFormat.number(s.distance / 1000, 2, unit: "km")),
            ("Vitesse max", TrackFormat.number(s.maxSpeed * 3.6, unit: "km/h")),
            ("Altitude", "\(TrackFormat.number(s.minAltitude)) – \(TrackFormat.number(s.maxAltitude, unit: "m"))"),
        ] + (track.hasAcceleration ? [("Charge", "\(TrackFormat.number(s.minG, 1)) / \(TrackFormat.number(s.maxG, 1, unit: "g"))")] : [])
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Text(item.1).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                }
                Text("Glisse pour tourner autour de la trajectoire")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

extension View {
    /// Sous-titre de fenêtre sur macOS (nom du fichier ouvert) ; sans effet ailleurs.
    @ViewBuilder func navigationSubtitleIfAvailable(_ text: String) -> some View {
        #if os(macOS)
        navigationSubtitle(text)
        #else
        self
        #endif
    }
}

// MARK: - Couleur de la trajectoire

enum TrajectoryColorMode: String, CaseIterable, Identifiable {
    case speed, altitude, loadFactor

    var id: Self { self }

    var title: String {
        switch self {
        case .speed: "Vitesse"
        case .altitude: "Altitude"
        case .loadFactor: "Facteur de charge"
        }
    }

    var unit: String {
        switch self {
        case .speed: "km/h"
        case .altitude: "m"
        case .loadFactor: "g"
        }
    }

    func value(_ p: TrackPoint) -> Double {
        switch self {
        case .speed: p.speedKmh
        case .altitude: p.altitude
        case .loadFactor: p.gZ
        }
    }

    /// Vitesse et altitude : magnitude → rampe séquentielle. Facteur de charge : de part et d'autre de 1 g → divergente.
    var isDiverging: Bool { self == .loadFactor }

    func ramp(dark: Bool) -> [UInt32] {
        switch (isDiverging, dark) {
        case (true, false): VizPalette.divergingLight
        case (true, true): VizPalette.divergingDark
        case (false, false): VizPalette.sequentialLight
        case (false, true): VizPalette.sequentialDark
        }
    }

    /// Bornes de l'échelle. Divergente : symétrique autour de 1 g pour que le gris tombe sur le vol en palier.
    func range(_ points: [TrackPoint]) -> ClosedRange<Double> {
        let values = points.map(value).filter(\.isFinite)
        guard let low = values.min(), let high = values.max(), high > low else { return 0...1 }
        if isDiverging {
            let spread = max(abs(high - 1), abs(low - 1), 0.5)
            return (1 - spread)...(1 + spread)
        }
        return low...high
    }

    func bin(_ value: Double, range: ClosedRange<Double>, count: Int) -> Int {
        guard value.isFinite else { return 0 }
        let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(count - 1, max(0, Int(t * Double(count))))
    }
}

struct TrajectoryLegend: View {
    let track: FlightTrack
    let colorMode: TrajectoryColorMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let range = colorMode.range(track.points)
        let colors = colorMode.ramp(dark: colorScheme == .dark).map { Color(hex: $0) }
        VStack(alignment: .leading, spacing: 6) {
            Text("\(colorMode.title) (\(colorMode.unit))").font(.caption.weight(.semibold))
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 8)
                .clipShape(.capsule)
            HStack {
                Text(TrackFormat.number(range.lowerBound, colorMode == .loadFactor ? 1 : 0))
                Spacer()
                if colorMode.isDiverging { Text("1"); Spacer() }
                Text(TrackFormat.number(range.upperBound, colorMode == .loadFactor ? 1 : 0))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 160)
            HStack(spacing: 12) {
                marker("Départ", color: TrajectoryScene.startColor)
                marker("Arrivée", color: TrajectoryScene.endColor)
            }
            .font(.caption2)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    /// Pastille colorée + libellé en couleur de texte (la couleur ne porte jamais seule l'information).
    private func marker(_ title: String, color: UInt32) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
            Text(title)
        }
    }
}

// MARK: - Vue 3D

#if !os(visionOS)
struct Trajectory3DView: View {
    let track: FlightTrack
    let colorMode: TrajectoryColorMode
    let exaggeration: Double
    /// Imagerie satellite à plaquer au sol (nil : grille).
    let groundImage: CGImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        RealityView { content in
            content.camera = .virtual
            content.add(await TrajectoryScene.build(track: track, colorMode: colorMode,
                                                    exaggeration: Float(exaggeration), dark: dark,
                                                    groundImage: groundImage))
        }
        .realityViewCameraControls(.orbit)
        .background(dark ? Color(hex: 0x1A1A19) : Color(hex: 0xFCFCFB))
    }
}
#endif

/// Construit la scène : tube coloré, ombre au sol, lignes verticales, grille, repères départ / arrivée.
enum TrajectoryScene {
    static let startColor: UInt32 = 0x0CA30C
    static let endColor: UInt32 = 0xD03B3B
    /// Taille de la scène (en mètres virtuels), centrée sur l'origine.
    private static let size: Float = 1.5
    /// Inclinaison initiale vers l'observateur : on voit la grille au sol et le relief d'un coup d'œil.
    private static let initialTilt: Float = 0.5

    /// Repère local commun à la scène et à l'imagerie satellite (indépendant de l'exagération du relief).
    struct Layout {
        let points: [TrackPoint]
        let origin: TrackPoint
        let minAltitude: Double
        let metersPerDegreeLat = 111_132.0
        let metersPerDegreeLon: Double
        /// Centre horizontal de la trajectoire, en mètres depuis le premier point (x = est, z = −nord).
        let centerX: Double
        let centerZ: Double
        /// Côté du carré de sol, en mètres : l'emprise horizontale + 20 % de marge.
        let groundSide: Double

        init?(track: FlightTrack) {
            let points = Downsample.stride(track.points.filter { $0.hasPosition && $0.altitude.isFinite }, maxCount: 3000)
            guard let origin = points.first, points.count >= 2 else { return nil }
            self.points = points
            self.origin = origin
            minAltitude = points.map(\.altitude).min() ?? origin.altitude
            let lonScale = 111_320.0 * cos(origin.latitude * .pi / 180), latScale = 111_132.0
            metersPerDegreeLon = lonScale
            let xs = points.map { ($0.longitude - origin.longitude) * lonScale }
            let zs = points.map { -($0.latitude - origin.latitude) * latScale }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minZ = zs.min() ?? 0, maxZ = zs.max() ?? 0
            centerX = (minX + maxX) / 2
            centerZ = (minZ + maxZ) / 2
            groundSide = max(maxX - minX, maxZ - minZ, 50) * 1.2
        }

        func meters(_ p: TrackPoint, exaggeration: Float) -> SIMD3<Float> {
            SIMD3<Float>(Float((p.longitude - origin.longitude) * metersPerDegreeLon - centerX),
                         Float(p.altitude - minAltitude) * exaggeration,
                         Float(-(p.latitude - origin.latitude) * metersPerDegreeLat - centerZ))
        }

        /// Zone géographique couverte par le carré de sol, nord en haut.
        var groundRegion: MKCoordinateRegion {
            let center = CLLocationCoordinate2D(latitude: origin.latitude - centerZ / metersPerDegreeLat,
                                                longitude: origin.longitude + centerX / metersPerDegreeLon)
            return MKCoordinateRegion(center: center,
                                      span: MKCoordinateSpan(latitudeDelta: groundSide / metersPerDegreeLat,
                                                             longitudeDelta: groundSide / metersPerDegreeLon))
        }
    }

    /// Image satellite haute résolution (4 096 px de côté) de la zone, sans libellés ni relief.
    static func satelliteImage(region: MKCoordinateRegion) async throws -> CGImage {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 2048, height: 2048)
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        #if os(macOS)
        options.appearance = NSAppearance(named: .aqua)
        #else
        options.traitCollection = UITraitCollection(displayScale: 2)
        #endif
        let snapshot = try await MKMapSnapshotter(options: options).start()
        #if os(macOS)
        guard let image = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
        #else
        guard let image = snapshot.image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        return image
        #endif
    }

    static func build(track: FlightTrack, colorMode: TrajectoryColorMode, exaggeration: Float, dark: Bool,
                      groundImage: CGImage? = nil) async -> Entity {
        let root = Entity()
        guard let layout = Layout(track: track) else { return root }
        let points = layout.points

        // Coordonnées locales en mètres (x = est, y = haut, z = −nord), puis mise à l'échelle de la scène.
        var positions = points.map { layout.meters($0, exaggeration: exaggeration) }
        let lower = positions.reduce(positions[0]) { pointwiseMin($0, $1) }
        let upper = positions.reduce(positions[0]) { pointwiseMax($0, $1) }
        let extent = upper - lower
        let scale = size / max(Float(layout.groundSide) / 1.2, extent.y, 1)
        let lift = extent.y * scale / 2 // centre vertical de la scène sur l'origine
        positions = positions.map { $0 * scale - SIMD3<Float>(0, lift, 0) }
        let groundY = -lift
        let half = Float(layout.groundSide) * scale / 2
        let radius: Float = 0.004

        // Tube coloré par tranches de valeur.
        let ramp = colorMode.ramp(dark: dark)
        let range = colorMode.range(points)
        let bins = points.map { colorMode.bin(colorMode.value($0), range: range, count: ramp.count) }
        let tube = Tube.descriptors(positions, bins: bins, binCount: ramp.count, radius: radius)
        if let mesh = try? MeshResource.generate(from: tube) {
            let materials = ramp.map { UnlitMaterial(color: platformColor($0)) }
            root.addChild(ModelEntity(mesh: mesh, materials: materials))
        }

        // Sur l'imagerie satellite, des repères clairs restent lisibles sur le terrain sombre.
        let guide = groundImage != nil ? platformColor(0xFFFFFF, alpha: 0.6)
            : dark ? platformColor(0x8A8984, alpha: 0.5) : platformColor(0x9A9893, alpha: 0.45)

        // Ombre au sol : la même trace aplatie, pour lire la position horizontale.
        let shadow = positions.map { SIMD3<Float>($0.x, groundY + 0.001, $0.z) }
        if let mesh = try? MeshResource.generate(from: Tube.descriptors(shadow, bins: Array(repeating: 0, count: shadow.count),
                                                                         binCount: 1, radius: radius * 0.5)) {
            root.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: guide)]))
        }

        // Lignes verticales régulières : relient la trajectoire à son ombre pour lire la hauteur.
        let dropStep = max(1, positions.count / 60)
        for p in Swift.stride(from: 0, to: positions.count, by: dropStep).map({ positions[$0] }) {
            let height = p.y - groundY
            guard height > 0.002 else { continue }
            let line = ModelEntity(mesh: .generateBox(width: radius * 0.4, height: height, depth: radius * 0.4),
                                   materials: [UnlitMaterial(color: guide)])
            line.position = SIMD3<Float>(p.x, groundY + height / 2, p.z)
            root.addChild(line)
        }

        // Sol : imagerie satellite si demandée, sinon grille.
        if let groundImage, let texture = try? await TextureResource(image: groundImage, options: .init(semantic: .color)) {
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            let ground = ModelEntity(mesh: .generatePlane(width: 2 * half, depth: 2 * half), materials: [material])
            ground.position = SIMD3<Float>(0, groundY - 0.001, 0)
            root.addChild(ground)
        } else {
            addGrid(to: root, half: half, groundY: groundY, dark: dark)
        }
        // Départ et arrivée.
        for (position, color) in [(positions[0], startColor), (positions[positions.count - 1], endColor)] {
            let marker = ModelEntity(mesh: .generateSphere(radius: radius * 3.5),
                                     materials: [UnlitMaterial(color: platformColor(color))])
            marker.position = position
            root.addChild(marker)
        }
        root.orientation = simd_quatf(angle: initialTilt, axis: [1, 0, 0])
        return root
    }

    private static func addGrid(to root: Entity, half: Float, groundY: Float, dark: Bool) {
        let divisions = 10
        let gridColor = dark ? platformColor(0x383835) : platformColor(0xE4E2DD)
        for i in 0...divisions {
            let offset = -half + Float(i) * (2 * half / Float(divisions))
            for (w, d, x, z) in [(2 * half, 0.0015 as Float, 0 as Float, offset), (0.0015 as Float, 2 * half, offset, 0 as Float)] {
                let line = ModelEntity(mesh: .generateBox(width: w, height: 0.0005, depth: d),
                                       materials: [UnlitMaterial(color: gridColor)])
                line.position = SIMD3<Float>(x, groundY, z)
                root.addChild(line)
            }
        }
    }

    #if os(macOS)
    private static func platformColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor { NSColor(hex: hex).withAlphaComponent(alpha) }
    #else
    private static func platformColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor { UIColor(hex: hex).withAlphaComponent(alpha) }
    #endif
}

/// Maillage d'un tube à section hexagonale le long d'une polyligne, découpé en un maillage par couleur.
private enum Tube {
    static let sides = 6

    static func descriptors(_ path: [SIMD3<Float>], bins: [Int], binCount: Int, radius: Float) -> [MeshDescriptor] {
        // Points consécutifs confondus : on les retire pour éviter des directions nulles.
        var points: [SIMD3<Float>] = []
        var pointBins: [Int] = []
        for (p, b) in zip(path, bins) where points.last.map({ simd_distance($0, p) > 1e-5 }) ?? true {
            points.append(p)
            pointBins.append(b)
        }
        guard points.count >= 2 else { return [] }

        // Repère transporté le long de la courbe : pas de vrille quand la trajectoire passe à la verticale.
        var normals: [SIMD3<Float>] = []
        var previousNormal = SIMD3<Float>(0, 1, 0)
        for i in points.indices {
            let ahead = points[min(i + 1, points.count - 1)], behind = points[max(i - 1, 0)]
            let tangent = simd_normalize(ahead - behind)
            var n = previousNormal - simd_dot(previousNormal, tangent) * tangent
            if simd_length(n) < 1e-4 {
                n = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                n -= simd_dot(n, tangent) * tangent
            }
            n = simd_normalize(n)
            normals.append(n)
            previousNormal = n
        }

        var positions = Array(repeating: [SIMD3<Float>](), count: binCount)
        var vertexNormals = Array(repeating: [SIMD3<Float>](), count: binCount)
        var indices = Array(repeating: [UInt32](), count: binCount)
        func ring(_ i: Int) -> [(SIMD3<Float>, SIMD3<Float>)] {
            let ahead = points[min(i + 1, points.count - 1)], behind = points[max(i - 1, 0)]
            let tangent = simd_normalize(ahead - behind)
            let n = normals[i]
            let b = simd_cross(tangent, n)
            return (0..<sides).map { k in
                let angle = Float(k) / Float(sides) * 2 * .pi
                let dir = cos(angle) * n + sin(angle) * b
                return (points[i] + radius * dir, dir)
            }
        }
        for i in 0..<(points.count - 1) {
            let bin = min(max(pointBins[i], 0), binCount - 1)
            let base = UInt32(positions[bin].count)
            for (p, n) in ring(i) + ring(i + 1) {
                positions[bin].append(p)
                vertexNormals[bin].append(n)
            }
            let s = UInt32(sides)
            for k in 0..<s {
                let a = base + k, b = base + (k + 1) % s
                let c = a + s, d = b + s
                indices[bin] += [a, c, b, b, c, d]
            }
        }

        return (0..<binCount).compactMap { bin in
            guard !positions[bin].isEmpty else { return nil }
            var descriptor = MeshDescriptor(name: "segment-\(bin)")
            descriptor.positions = MeshBuffers.Positions(positions[bin])
            descriptor.normals = MeshBuffers.Normals(vertexNormals[bin])
            descriptor.primitives = .triangles(indices[bin])
            descriptor.materials = .allFaces(UInt32(bin))
            return descriptor
        }
    }
}

// MARK: - Aperçu : boucle synthétique

#Preview("Trajectoire 3D") {
    let points = (0..<1500).map { i -> TrackPoint in
        let t = Double(i) / 1500 * 2 * .pi
        var p = TrackPoint(id: i, time: Double(i) / 10)
        // Une boucle verticale suivie d'un huit horizontal.
        p.latitude = 44.0 + 0.004 * sin(t)
        p.longitude = 1.0 + 0.006 * sin(2 * t)
        p.altitude = 800 + 250 * (1 - cos(t))
        p.speed = 50 + 25 * cos(t)
        p.gZ = 1 + 3 * sin(3 * t)
        return p
    }
    let store = ViewerStore()
    GPXViewerPane(store: store, sessions: [])
        .task { store.showInBoth(FlightTrack(name: "Boucle d'essai", startDate: .now, points: points)) }
        .frame(width: 900, height: 650)
}

#if !os(visionOS)
/// Vérifie le sens de l'image au sol : nord-ouest rouge, nord-est jaune, sud gris.
/// La trace part du sud (point vert) et finit au nord-ouest (point rouge) : celui-ci doit tomber sur le quadrant rouge.
#Preview("Orientation du sol") {
    let points = (0..<200).map { i -> TrackPoint in
        let t = Double(i) / 199
        var p = TrackPoint(id: i, time: Double(i))
        p.latitude = 44.0 + 0.01 * t
        p.longitude = 1.0 - 0.006 * t
        p.altitude = 500 + 300 * sin(t * .pi)
        p.speed = 50
        return p
    }
    let size = 256
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // CGContext a son origine en bas à gauche : y haut = haut de l'image = nord.
    context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2))
    context.setFillColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: size / 2, y: size / 2, width: size / 2, height: size / 2))
    let image = context.makeImage()!
    return Trajectory3DView(track: FlightTrack(name: "Nord", startDate: nil, points: points),
                            colorMode: .altitude, exaggeration: 1, groundImage: image)
        .frame(width: 700, height: 500)
}
#endif
