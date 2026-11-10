import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Trajectoire commune aux visionneuses CSV et GPX : lecture des fichiers, statistiques, réduction pour l'affichage.
// Les valeurs absentes valent `.nan` (plus léger que des optionnels sur des dizaines de milliers de points).

nonisolated struct TrackPoint: Identifiable, Sendable {
    let id: Int
    /// Secondes depuis le premier point.
    var time: Double
    var latitude = Double.nan
    var longitude = Double.nan
    /// Altitude en mètres (MSL pour les CSV RaceBox, `ele` pour les GPX).
    var altitude = Double.nan
    /// m/s
    var speed = Double.nan
    var heading = Double.nan
    /// Accélérations en g : X avant/arrière, Y droite/gauche, Z haut/bas (facteur de charge).
    var gX = Double.nan
    var gY = Double.nan
    var gZ = Double.nan
    /// Vitesses de rotation en °/s : X roulis, Y tangage, Z lacet.
    var rollRate = Double.nan
    var pitchRate = Double.nan
    var yawRate = Double.nan
    var satellites = Double.nan

    var hasPosition: Bool { latitude.isFinite && longitude.isFinite && !(latitude == 0 && longitude == 0) }
    var speedKmh: Double { speed * 3.6 }
}

nonisolated struct TrackStats: Sendable {
    var duration: Double = 0
    /// Mètres, somme des segments entre positions valides.
    var distance: Double = 0
    var maxSpeed = Double.nan
    var averageSpeed = Double.nan
    var minAltitude = Double.nan
    var maxAltitude = Double.nan
    /// Cumul des montées, en mètres.
    var climb: Double = 0
    var maxG = Double.nan
    var minG = Double.nan
    var maxRotation = Double.nan
    var averageSatellites = Double.nan

    init() {}

    init(points: [TrackPoint]) {
        guard let first = points.first, let last = points.last else { return }
        duration = last.time - first.time
        var previous: TrackPoint?
        var speeds = Accumulator()
        var altitudes = Accumulator()
        var loads = Accumulator()
        var rotations = Accumulator()
        var satellites = Accumulator()
        var lastAltitude = Double.nan
        for point in points {
            speeds.add(point.speed)
            altitudes.add(point.altitude)
            loads.add(point.gZ)
            rotations.add(max(abs(point.rollRate), abs(point.pitchRate), abs(point.yawRate)))
            satellites.add(point.satellites)
            if point.altitude.isFinite {
                if lastAltitude.isFinite, point.altitude > lastAltitude { climb += point.altitude - lastAltitude }
                lastAltitude = point.altitude
            }
            if point.hasPosition {
                if let previous { distance += Geo.distance(previous, point) }
                previous = point
            }
        }
        maxSpeed = speeds.max
        averageSpeed = speeds.mean
        minAltitude = altitudes.min
        maxAltitude = altitudes.max
        maxG = loads.max
        minG = loads.min
        maxRotation = rotations.max
        averageSatellites = satellites.mean
    }

    /// Min / max / moyenne en ignorant les valeurs absentes.
    private struct Accumulator {
        var min = Double.nan
        var max = Double.nan
        private var sum = 0.0
        private var count = 0
        var mean: Double { count > 0 ? sum / Double(count) : .nan }

        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            min = min.isFinite ? Swift.min(min, value) : value
            max = max.isFinite ? Swift.max(max, value) : value
            sum += value
            count += 1
        }
    }
}

nonisolated struct FlightTrack: Sendable {
    var name: String
    var startDate: Date?
    var points: [TrackPoint]
    let stats: TrackStats

    var hasPosition: Bool { points.contains(where: \.hasPosition) }
    var hasSpeed: Bool { points.contains { $0.speed.isFinite } }
    var hasAltitude: Bool { points.contains { $0.altitude.isFinite } }
    var hasAcceleration: Bool { points.contains { $0.gZ.isFinite } }
    var hasRotation: Bool { points.contains { $0.rollRate.isFinite } }
    var hasSatellites: Bool { points.contains { $0.satellites.isFinite } }

    init(name: String, startDate: Date?, points: [TrackPoint]) {
        self.name = name
        self.startDate = startDate
        self.points = points
        stats = TrackStats(points: points)
    }
}

// MARK: - Géographie

nonisolated enum Geo {
    static let earthRadius = 6_371_000.0

    /// Distance au sol (haversine), en mètres.
    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}

// MARK: - Réduction pour les graphiques

nonisolated struct SeriesPoint: Identifiable, Sendable {
    let id: Int
    let time: Double
    let value: Double
    let series: String
}

nonisolated enum Downsample {
    /// Garde, pour chaque tranche de temps, le minimum et le maximum de la valeur :
    /// les pics (g, rotations) restent visibles même avec 1 000 points affichés au lieu de 90 000.
    static func extremes(_ points: [TrackPoint], maxCount: Int = 1200, series: String = "",
                         value: (TrackPoint) -> Double) -> [SeriesPoint] {
        let valid = points.filter { value($0).isFinite }
        guard valid.count > maxCount, maxCount >= 2 else {
            return valid.map { SeriesPoint(id: $0.id, time: $0.time, value: value($0), series: series) }
        }
        let bucketSize = Double(valid.count) / Double(maxCount / 2)
        var out: [SeriesPoint] = []
        out.reserveCapacity(maxCount)
        var start = 0
        while start < valid.count {
            let end = min(valid.count, Int((Double(out.count / 2 + 1) * bucketSize).rounded()))
            let bucket = valid[start..<max(end, start + 1)]
            if let low = bucket.min(by: { value($0) < value($1) }), let high = bucket.max(by: { value($0) < value($1) }) {
                for p in [low, high].sorted(by: { $0.time < $1.time }) {
                    out.append(SeriesPoint(id: p.id, time: p.time, value: value(p), series: series))
                }
            }
            start = max(end, start + 1)
        }
        return out
    }

    /// Un point sur n, pour les vues qui n'ont pas besoin des extrêmes (3D, carte, nuage V-n).
    static func stride(_ points: [TrackPoint], maxCount: Int) -> [TrackPoint] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let step = Double(points.count) / Double(maxCount)
        return (0..<maxCount).map { points[Int(Double($0) * step)] }
    }
}

// MARK: - CSV

/// Fichier CSV brut : en-tête + lignes non découpées (découpées à l'affichage, pour économiser la mémoire).
nonisolated struct CSVTable: Sendable {
    struct Row: Identifiable, Sendable {
        let id: Int
        let line: String
    }

    let header: [String]
    let rows: [Row]
    let separator: Character

    func fields(of row: Row) -> [Substring] { CSVTable.split(row.line, separator: separator) }

    /// Découpe une ligne en tenant compte des guillemets.
    static func split(_ line: String, separator: Character) -> [Substring] {
        guard line.contains("\"") else { return line.split(separator: separator, omittingEmptySubsequences: false) }
        var fields: [Substring] = []
        var start = line.startIndex
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "\"" { inQuotes.toggle() }
            if c == separator, !inQuotes {
                fields.append(line[start..<index].trimmingQuotes)
                start = line.index(after: index)
            }
            index = line.index(after: index)
        }
        fields.append(line[start...].trimmingQuotes)
        return fields
    }
}

private extension Substring {
    nonisolated var trimmingQuotes: Substring {
        guard count >= 2, first == "\"", last == "\"" else { return self }
        return dropFirst().dropLast()
    }
}

nonisolated enum CSVReader {
    enum ReadError: LocalizedError {
        case empty
        var errorDescription: String? { "Le fichier CSV est vide ou illisible." }
    }

    /// Lit un CSV (export RaceBoxStudio, export de l'app RaceBox ou CSV générique).
    static func read(_ text: String, name: String) throws -> (table: CSVTable, track: FlightTrack) {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { throw ReadError.empty }
        lines.removeFirst()
        let separator = detectSeparator(headerLine)
        let header = CSVTable.split(headerLine, separator: separator).map { String($0).trimmingCharacters(in: .whitespaces) }
        let rows = lines.enumerated().map { CSVTable.Row(id: $0.offset, line: $0.element) }
        let table = CSVTable(header: header, rows: rows, separator: separator)
        return (table, track(from: table, name: name))
    }

    private static func detectSeparator(_ header: String) -> Character {
        [",", ";", "\t"].max { a, b in header.filter { $0 == a }.count < header.filter { $0 == b }.count } ?? ","
    }

    /// « Speed_kmh » → « speedkmh » : on compare des noms simplifiés.
    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func track(from table: CSVTable, name: String) -> FlightTrack {
        let names = table.header.map(normalized)
        func column(_ candidates: String...) -> Int? {
            for candidate in candidates { if let i = names.firstIndex(of: candidate) { return i } }
            return nil
        }
        let itow = column("itowms", "itow")
        let date = column("utc", "time", "timestamp", "datetime", "date")
        let lat = column("latitude", "lat")
        let lon = column("longitude", "lon", "lng")
        let alt = column("altitudemslm", "altitudemsl", "altitude", "alt", "ele", "elevation", "altitudewgsm")
        let speedKmh = column("speedkmh", "speedkph")
        let speedMs = column("speedms", "speed")
        let heading = column("headingdeg", "heading", "course")
        let gx = column("gx", "gforcex", "accx")
        let gy = column("gy", "gforcey", "accy")
        let gz = column("gz", "gforcez", "accz")
        let rx = column("gyroxdps", "gyrox", "rotationx", "rotx")
        let ry = column("gyroydps", "gyroy", "rotationy", "roty")
        let rz = column("gyrozdps", "gyroz", "rotationz", "rotz")
        let sats = column("satellites", "sats", "numsv")

        let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func parseDate(_ text: Substring) -> Date? {
            let s = String(text)
            return (try? dateStyle.parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
        }

        var points: [TrackPoint] = []
        points.reserveCapacity(table.rows.count)
        var startDate: Date?
        var firstItow = Double.nan
        var firstDate: Date?
        for row in table.rows {
            let f = table.fields(of: row)
            func value(_ index: Int?) -> Double {
                guard let index, index < f.count else { return .nan }
                return Double(f[index].trimmingCharacters(in: .whitespaces)) ?? .nan
            }
            var time = Double(points.count) / 25 // à défaut : 25 Hz
            if let itow, case let ms = value(itow), ms.isFinite {
                if !firstItow.isFinite { firstItow = ms }
                var delta = ms - firstItow
                if delta < 0 { delta += 604_800_000 } // passage de semaine GPS
                time = delta / 1000
            } else if let date, date < f.count, let d = parseDate(f[date]) {
                if firstDate == nil { firstDate = d }
                time = d.timeIntervalSince(firstDate ?? d)
            }
            if startDate == nil, let date, date < f.count { startDate = parseDate(f[date]) }

            var p = TrackPoint(id: row.id, time: time)
            p.latitude = value(lat)
            p.longitude = value(lon)
            p.altitude = value(alt)
            p.speed = speedKmh.map { value($0) / 3.6 } ?? value(speedMs)
            p.heading = value(heading)
            p.gX = value(gx)
            p.gY = value(gy)
            p.gZ = value(gz)
            p.rollRate = value(rx)
            p.pitchRate = value(ry)
            p.yawRate = value(rz)
            p.satellites = value(sats)
            points.append(p)
        }
        return FlightTrack(name: name, startDate: startDate, points: points)
    }
}

// MARK: - GPX

nonisolated enum GPXReader {
    enum ReadError: LocalizedError {
        case invalid(String)
        case noPoints
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "GPX illisible : \(detail)"
            case .noPoints: "Aucun point de trace dans ce GPX."
            }
        }
    }

    static func read(_ data: Data, name: String) throws -> FlightTrack {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ReadError.invalid(parser.parserError?.localizedDescription ?? "format inconnu")
        }
        guard let first = delegate.raw.first else { throw ReadError.noPoints }
        let start = first.date
        var points: [TrackPoint] = []
        points.reserveCapacity(delegate.raw.count)
        for (index, raw) in delegate.raw.enumerated() {
            let time = (raw.date.map { d in start.map { d.timeIntervalSince($0) } ?? 0 } ?? nil) ?? Double(index)
            var p = TrackPoint(id: index, time: time)
            p.latitude = raw.lat
            p.longitude = raw.lon
            p.altitude = raw.ele
            p.speed = raw.speed
            p.heading = raw.course
            points.append(p)
        }
        // Vitesse absente du fichier : on la déduit des positions successives.
        if !points.contains(where: { $0.speed.isFinite }) {
            for i in points.indices.dropFirst() {
                let dt = points[i].time - points[i - 1].time
                if dt > 0 { points[i].speed = Geo.distance(points[i - 1], points[i]) / dt }
            }
        }
        return FlightTrack(name: name, startDate: start, points: points)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Raw {
            var lat = Double.nan
            var lon = Double.nan
            var ele = Double.nan
            var speed = Double.nan
            var course = Double.nan
            var date: Date?
        }

        var raw: [Raw] = []
        private var current: Raw?
        private var text = ""
        private let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        /// « gpxtpx:speed » → « speed ».
        private func local(_ name: String) -> String {
            String(name.split(separator: ":").last ?? Substring(name)).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            text = ""
            let name = local(elementName)
            if name == "trkpt" || name == "rtept" {
                var point = Raw()
                point.lat = Double(attributes["lat"] ?? "") ?? .nan
                point.lon = Double(attributes["lon"] ?? "") ?? .nan
                current = point
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local(elementName) {
            case "ele": current?.ele = Double(value) ?? .nan
            case "speed": current?.speed = Double(value) ?? .nan
            case "course": current?.course = Double(value) ?? .nan
            case "time":
                current?.date = (try? dateStyle.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
            case "trkpt", "rtept":
                if let current { raw.append(current) }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}

// MARK: - Session téléchargée → trajectoire

extension RecordingSession {
    /// Trajectoire directement issue des échantillons, sans passer par un fichier.
    var track: FlightTrack {
        let firstItow = samples.first.map { Int64($0.itow) } ?? 0
        let points = samples.enumerated().map { index, s in
            var p = TrackPoint(id: index, time: Double(Int64(s.itow) - firstItow) / 1000)
            if s.hasValidPosition {
                p.latitude = s.latitude
                p.longitude = s.longitude
                p.altitude = s.altitudeMSL
            }
            p.speed = s.speed
            p.heading = s.heading
            p.gX = s.gForceX
            p.gY = s.gForceY
            p.gZ = s.gForceZ
            p.rollRate = s.rotationX
            p.pitchRate = s.rotationY
            p.yawRate = s.rotationZ
            p.satellites = Double(s.satellites)
            return p
        }
        return FlightTrack(name: title, startDate: startDate, points: points)
    }
}

// MARK: - Couleurs (palette de référence validée, déclinée clair / sombre)

enum VizPalette {
    /// Série unique : bleu (emplacement 1).
    static let series1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    /// Trois séries maximum dans un même graphique : bleu, orange, aqua (validés deux à deux, daltonisme compris).
    static let series2 = Color(light: 0xEB6834, dark: 0xD95926)
    static let series3 = Color(light: 0x1BAF7A, dark: 0x199E70)

    /// Rampe séquentielle bleue (faible → fort) : en clair on fonce, en sombre on éclaircit.
    static let sequentialLight: [UInt32] = [0x9EC5F4, 0x86B6EF, 0x6DA7EC, 0x5598E7, 0x3987E5, 0x2A78D6, 0x256ABF, 0x1C5CAB, 0x184F95, 0x0D366B]
    static let sequentialDark: [UInt32] = [0x104281, 0x184F95, 0x1C5CAB, 0x256ABF, 0x2A78D6, 0x3987E5, 0x5598E7, 0x6DA7EC, 0x86B6EF, 0xB7D3F6]
    /// Divergente bleu ↔ rouge, gris neutre au centre (ici 1 g, le vol en palier).
    static let divergingLight: [UInt32] = [0x1C5CAB, 0x3987E5, 0x86B6EF, 0xF0EFEC, 0xF2A9A6, 0xE34948, 0xB52D2D]
    static let divergingDark: [UInt32] = [0x5598E7, 0x3987E5, 0x1C5CAB, 0x383835, 0xA33A3A, 0xE66767, 0xF2A9A6]
}

extension Color {
    /// Couleur qui suit le mode clair / sombre du système.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
        #endif
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

// MARK: - Formats

nonisolated enum TrackFormat {
    /// 83 s → « 1:23 », 3 723 s → « 1:02:03 ».
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func number(_ value: Double, _ digits: Int = 0, unit: String = "") -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits))) + (unit.isEmpty ? "" : " " + unit)
    }
}

/// Types de fichiers acceptés par les visionneuses.
enum TrackFileType {
    static var csv: [UTType] { [.commaSeparatedText, .tabSeparatedText, .plainText] }
    static var gpx: [UTType] { [ExportFile.gpxType, .xml] }
}
