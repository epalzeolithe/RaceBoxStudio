import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Données enregistrées en autonome (Mini S / Micro) : état de la mémoire, échantillons, export CSV / GPX.

private extension Array where Element == UInt8 {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func i16(_ offset: Int) -> Int16 { Int16(bitPattern: u16(offset)) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }
}

// MARK: - État de la mémoire (0xFF 0x22)

struct RecordingStatus: Equatable {
    let isRecording: Bool
    /// Remplissage de la mémoire, de 0 à 100 %.
    let memoryLevel: Int
    let securityEnabled: Bool
    let unlocked: Bool
    let storedMessages: Int
    /// Capacité, en messages de données.
    let memorySize: Int

    var isLocked: Bool { securityEnabled && !unlocked }

    /// Durée d'enregistrement restante dans la mémoire libre à la fréquence donnée (sans pause de filtre).
    func remainingTime(hertz: Int) -> TimeInterval {
        Double(max(memorySize - storedMessages, 0)) / Double(max(hertz, 1))
    }

    init?(payload: [UInt8]) {
        guard payload.count >= 12 else { return nil }
        isRecording = payload[0] != 0
        memoryLevel = Int(payload[1])
        securityEnabled = payload[2] & 0x01 != 0
        unlocked = payload[2] & 0x02 != 0
        storedMessages = Int(payload.u32(4))
        memorySize = Int(payload.u32(8))
    }
}

// MARK: - Échantillon (message de données de 80 octets)

struct RaceBoxSample {
    let itow: UInt32
    let date: Date?
    let fixStatus: UInt8
    let fixFlags: UInt8
    let satellites: Int
    let latitude: Double
    let longitude: Double
    let altitudeWGS: Double
    let altitudeMSL: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    /// m/s
    let speed: Double
    let heading: Double
    let speedAccuracy: Double
    let headingAccuracy: Double
    let pdop: Double
    let latLonFlags: UInt8
    /// Batterie (Mini / Mini S) ou tension d'entrée (Micro), voir `PowerReading`.
    let powerByte: UInt8
    let gForceX: Double
    let gForceY: Double
    let gForceZ: Double
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double
    /// Échantillon ajouté par l'app pour combler une pause du boîtier (filtre No-Fix ou d'immobilité), pas une mesure.
    let isFilled: Bool

    var hasValidPosition: Bool { fixStatus >= 2 && latLonFlags & 0x01 == 0 }
    /// Recommandation de la doc : fix 3D avec le bit « fix valide » levé.
    var hasGoodFix: Bool { fixStatus == 3 && fixFlags & 0x01 != 0 }
    var totalG: Double { (gForceX * gForceX + gForceY * gForceY + gForceZ * gForceZ).squareRoot() }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    init?(payload p: [UInt8]) {
        guard p.count == 80 else { return nil }
        itow = p.u32(0)
        if p[11] & 0x03 == 0x03 {
            let components = DateComponents(year: Int(p.u16(4)), month: Int(p[6]), day: Int(p[7]),
                                            hour: Int(p[8]), minute: Int(p[9]), second: Int(p[10]))
            date = Self.utc.date(from: components)?.addingTimeInterval(Double(p.i32(16)) / 1e9)
        } else {
            date = nil
        }
        fixStatus = p[20]
        fixFlags = p[21]
        satellites = Int(p[23])
        longitude = Double(p.i32(24)) / 1e7
        latitude = Double(p.i32(28)) / 1e7
        altitudeWGS = Double(p.i32(32)) / 1000
        altitudeMSL = Double(p.i32(36)) / 1000
        horizontalAccuracy = Double(p.u32(40)) / 1000
        verticalAccuracy = Double(p.u32(44)) / 1000
        speed = Double(p.i32(48)) / 1000
        heading = Double(p.i32(52)) / 1e5
        speedAccuracy = Double(p.u32(56)) / 1000
        headingAccuracy = Double(p.u32(60)) / 1e5
        pdop = Double(p.u16(64)) / 100
        latLonFlags = p[66]
        powerByte = p[67]
        gForceX = Double(p.i16(68)) / 1000
        gForceY = Double(p.i16(70)) / 1000
        gForceZ = Double(p.i16(72)) / 1000
        rotationX = Double(p.i16(74)) / 100
        rotationY = Double(p.i16(76)) / 100
        rotationZ = Double(p.i16(78)) / 100
        isFilled = false
    }

    /// Échantillon intermédiaire entre `a` (avant la pause) et `b` (après), à la fraction `f` de l'intervalle :
    /// valeurs interpolées linéairement (cap par le plus court chemin). Pendant une pause No-Fix il n'y a pas de fix,
    /// ce qui est conservé ; en immobilité le fix de `a` est repris.
    init(filling a: RaceBoxSample, to b: RaceBoxSample, fraction f: Double, itow: UInt32, noFix: Bool) {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        self.itow = itow
        var elapsed = Int64(itow) - Int64(a.itow)
        if elapsed < 0 { elapsed += RaceBoxSample.weekMilliseconds }
        date = a.date?.addingTimeInterval(Double(elapsed) / 1000)
        fixStatus = noFix ? 0 : a.fixStatus
        fixFlags = noFix ? 0 : a.fixFlags
        satellites = a.satellites
        latitude = mix(a.latitude, b.latitude)
        longitude = mix(a.longitude, b.longitude)
        altitudeWGS = mix(a.altitudeWGS, b.altitudeWGS)
        altitudeMSL = mix(a.altitudeMSL, b.altitudeMSL)
        horizontalAccuracy = mix(a.horizontalAccuracy, b.horizontalAccuracy)
        verticalAccuracy = mix(a.verticalAccuracy, b.verticalAccuracy)
        speed = mix(a.speed, b.speed)
        var turn = b.heading - a.heading
        while turn > 180 { turn -= 360 }
        while turn < -180 { turn += 360 }
        var interpolated = (a.heading + turn * f).truncatingRemainder(dividingBy: 360)
        if interpolated < 0 { interpolated += 360 }
        heading = interpolated
        speedAccuracy = mix(a.speedAccuracy, b.speedAccuracy)
        headingAccuracy = mix(a.headingAccuracy, b.headingAccuracy)
        pdop = a.pdop
        latLonFlags = 0
        powerByte = a.powerByte
        gForceX = mix(a.gForceX, b.gForceX)
        gForceY = mix(a.gForceY, b.gForceY)
        gForceZ = mix(a.gForceZ, b.gForceZ)
        rotationX = mix(a.rotationX, b.rotationX)
        rotationY = mix(a.rotationY, b.rotationY)
        rotationZ = mix(a.rotationZ, b.rotationZ)
        isFilled = true
    }

    static let weekMilliseconds: Int64 = 604_800_000
}

// MARK: - Session

/// Suite continue d'échantillons. La mémoire est une longue liste : on coupe là où le temps GPS saute.
/// Pause détectée dans une session : le boîtier n'enregistre rien (filtre No-Fix ou filtre d'immobilité).
struct RecordingPause {
    enum Kind { case noFix, stationary }
    let kind: Kind
    /// Secondes de données manquantes.
    let duration: Double
    /// Échantillons ajoutés pour la combler.
    let filledCount: Int
}

struct RecordingSession: Identifiable {
    let id = UUID()
    let samples: [RaceBoxSample]
    /// Pauses comblées dans `samples` (les échantillons ajoutés ont `isFilled`).
    var pauses: [RecordingPause] = []

    /// Écart maximal entre deux échantillons d'une même session, en ms (25 Hz = 40 ms).
    private static let maxGap: Int64 = 5000

    /// `boundaries` : indices des échantillons qui suivent un message 0xFF 0x26 de démarrage ou d'arrêt.
    /// S'il y en a, ils font foi (une pause de filtre reste dans la même session) ;
    /// sinon (ancien firmware) on coupe sur les sauts de temps GPS.
    static func split(_ samples: [RaceBoxSample], boundaries: Set<Int> = []) -> [RecordingSession] {
        var sessions: [RecordingSession] = []
        var current: [RaceBoxSample] = []
        for (index, sample) in samples.enumerated() {
            if let last = current.last {
                let delta = Int64(sample.itow) - Int64(last.itow)
                let cut = boundaries.isEmpty ? (delta < 0 || delta > maxGap) : boundaries.contains(index)
                if cut {
                    sessions.append(RecordingSession(samples: current))
                    current = []
                }
            }
            current.append(sample)
        }
        if !current.isEmpty { sessions.append(RecordingSession(samples: current)) }
        return sessions.map { $0.fillingPauses() }
    }

    /// Plus longue pause comblée (au-delà, on laisse le trou : l'appareil a sans doute été éteint).
    private static let maxFilledPause: Int64 = 4 * 3_600_000

    /// Détecte les pauses au sein de la session (trou de temps entre deux échantillons) et les comble au rythme
    /// de la session. Pause « No-Fix » si le dernier échantillon avant le trou n'avait pas de fix, sinon pause
    /// d'immobilité (le filtre d'arrêt ne s'active qu'avec un fix valide).
    func fillingPauses() -> RecordingSession {
        guard samples.count > 2 else { return self }
        func delta(_ later: RaceBoxSample, _ earlier: RaceBoxSample) -> Int64 {
            var d = Int64(later.itow) - Int64(earlier.itow)
            if d < -RaceBoxSample.weekMilliseconds / 2 { d += RaceBoxSample.weekMilliseconds }
            return d
        }
        let deltas = zip(samples.dropFirst(), samples).map(delta)
        let regular = deltas.filter { $0 > 0 && $0 <= 2000 }.sorted()
        guard !regular.isEmpty else { return self }
        let step = Double(regular[regular.count / 2])
        let threshold = max(3 * step, 200)

        var out: [RaceBoxSample] = []
        out.reserveCapacity(samples.count)
        var found: [RecordingPause] = []
        for (index, sample) in samples.enumerated() {
            out.append(sample)
            guard index + 1 < samples.count else { break }
            let gap = deltas[index]
            guard Double(gap) > threshold, gap <= Self.maxFilledPause else { continue }
            let next = samples[index + 1]
            let noFix = sample.fixStatus < 3 || sample.fixFlags & 0x01 == 0
            let count = max(Int((Double(gap) / step).rounded()) - 1, 0)
            if count > 0 {
                for k in 1...count {
                    let fraction = Double(k) / Double(count + 1)
                    let itow = UInt32((Int64(sample.itow) + Int64(Double(gap) * fraction)) % RaceBoxSample.weekMilliseconds)
                    out.append(RaceBoxSample(filling: sample, to: next, fraction: fraction, itow: itow, noFix: noFix))
                }
            }
            found.append(RecordingPause(kind: noFix ? .noFix : .stationary, duration: Double(gap) / 1000, filledCount: count))
        }
        guard !found.isEmpty else { return self }
        var filled = RecordingSession(samples: out)
        filled.pauses = found
        return filled
    }

    var startDate: Date? { samples.lazy.compactMap(\.date).first }
    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return Double(Int64(last.itow) - Int64(first.itow)) / 1000
    }
    var maxSpeedKmh: Double { (samples.map(\.speed).max() ?? 0) * 3.6 }
    var maxG: Double { samples.map(\.totalG).max() ?? 0 }

    var title: String {
        guard let startDate else { return "Session sans date" }
        return startDate.formatted(date: .abbreviated, time: .standard)
    }

    var fileStem: String {
        guard let startDate else { return "racebox-session" }
        return "racebox-" + startDate.formatted(Date.ISO8601FormatStyle().year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
            .timeSeparator(.omitted))
    }

    // MARK: Export

    private static func isoString(_ date: Date?) -> String {
        date?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) ?? ""
    }

    func csv() -> String {
        var out = "utc,itow_ms,fix,satellites,latitude,longitude,altitude_wgs_m,altitude_msl_m,"
            + "h_accuracy_m,v_accuracy_m,speed_ms,speed_kmh,heading_deg,speed_accuracy_ms,"
            + "heading_accuracy_deg,pdop,g_x,g_y,g_z,gyro_x_dps,gyro_y_dps,gyro_z_dps,filled\n"
        out.reserveCapacity(samples.count * 190)
        for s in samples {
            out += Self.isoString(s.date)
            out += String(format: ",%u,%u,%d,%.7f,%.7f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.5f,%.3f,%.5f,%.2f,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f,%d\n",
                          s.itow, s.fixStatus, s.satellites, s.latitude, s.longitude,
                          s.altitudeWGS, s.altitudeMSL, s.horizontalAccuracy, s.verticalAccuracy,
                          s.speed, s.speed * 3.6, s.heading, s.speedAccuracy, s.headingAccuracy, s.pdop,
                          s.gForceX, s.gForceY, s.gForceZ, s.rotationX, s.rotationY, s.rotationZ, s.isFilled ? 1 : 0)
        }
        return out
    }

    /// Trace GPS : points à position valide, et points ajoutés pour combler les pauses (trace continue).
    func gpx() -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RaceBoxStudio" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(title)</name><trkseg>

        """
        for s in samples where s.hasValidPosition || s.isFilled {
            out += String(format: "<trkpt lat=\"%.7f\" lon=\"%.7f\"><ele>%.2f</ele>", s.latitude, s.longitude, s.altitudeMSL)
            if s.date != nil { out += "<time>\(Self.isoString(s.date))</time>" }
            out += String(format: "<extensions><speed>%.3f</speed></extensions></trkpt>\n", s.speed)
        }
        out += "</trkseg></trk>\n</gpx>\n"
        return out
    }
}

// MARK: - Fichier exporté

struct ExportFile: FileDocument {
    nonisolated static var gpxType: UTType { UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml }
    /// Export de la fusion GNSS / IMU : un CSV d'extension .fgpx.
    nonisolated static var fgpxType: UTType { UTType(filenameExtension: "fgpx", conformingTo: .commaSeparatedText) ?? .commaSeparatedText }
    nonisolated static var readableContentTypes: [UTType] { [.commaSeparatedText, gpxType, fgpxType, .xml] }

    var text: String

    nonisolated init(text: String) { self.text = text }

    nonisolated init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
