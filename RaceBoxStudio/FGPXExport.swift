import Foundation
import simd

/// Export .fgpx : les données de la fusion GNSS / IMU, une ligne par échantillon (25 Hz), au format CSV.
///
/// Les lignes qui commencent par « # » sont des métadonnées (version, source, repères, calage…) ; la première
/// ligne sans « # » est l'en-tête des colonnes, séparées par des virgules, point décimal, valeurs vides = absentes.
///
/// Repères : position et vitesse en ENU / WGS84 ; attitude de l'AVION (attitude du boîtier composée avec le calage
/// mesuré au premier passage à 100 km/h) ; axes de l'avion = avant, gauche, haut (repère direct).
nonisolated enum FGPXExport {
    static let version = 1

    static let columns: [String] = [
        "utc", "t_s",
        // trajectoire corrigée (fusion)
        "lat_deg", "lon_deg", "alt_msl_m",
        "vel_e_ms", "vel_n_ms", "vel_u_ms", "ground_speed_ms", "speed_kmh",
        // attitude de l'avion
        "heading_deg", "pitch_deg", "roll_deg", "qw", "qx", "qy", "qz",
        // attitude du boîtier (avant calage)
        "box_heading_deg", "box_pitch_deg", "box_roll_deg",
        // accélérations (force spécifique) et vitesses de rotation dans les axes de l'avion
        "accel_fwd_g", "accel_left_g", "accel_up_g", "load_factor_g",
        "gyro_fwd_dps", "gyro_left_dps", "gyro_up_dps",
        // biais gyro estimé (axes du boîtier, repère avant / gauche / haut)
        "gyro_bias_x_dps", "gyro_bias_y_dps", "gyro_bias_z_dps",
        // GNSS brut et mesures brutes du boîtier, telles qu'enregistrées
        "lat_raw_deg", "lon_raw_deg", "alt_raw_m", "speed_raw_ms", "heading_raw_deg",
        "h_acc_m", "v_acc_m", "speed_acc_ms", "heading_acc_deg", "satellites", "fix",
        "g_x", "g_y", "g_z", "gyro_x_dps", "gyro_y_dps", "gyro_z_dps",
    ]

    static func text(track: FlightTrack, result: FusionResult, smoothed: Bool, mounting: MountingCalibration?,
                     config: FusionConfig) -> String {
        let samples = result.samples(smoothed: smoothed)
        let mount = mounting?.rotation ?? MountingCalibration.identity.rotation
        let unmount = mount.inverse
        var out = ""
        out.reserveCapacity(samples.count * 420)

        // MARK: Métadonnées
        out += "# FGPX \(version)\n"
        out += "# generator: RaceBoxStudio, fusion GNSS/IMU (ESKF 15 états\(smoothed && result.smoothed != nil ? " + lisseur RTS" : ""))\n"
        out += "# source: \(track.name)\n"
        if let start = track.startDate {
            out += "# start_utc: \(start.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))\n"
        }
        out += "# samples: \(samples.count)\n"
        out += "# smoothed: \(smoothed && result.smoothed != nil ? 1 : 0)\n"
        out += "# frames: position WGS84 ; vitesses ENU (est, nord, haut) ; cap horaire depuis le nord ; tangage > 0 nez en haut ; "
        out += "roulis > 0 aile droite basse ; quaternion = attitude avion → ENU (ENU : x est, y nord, z haut)\n"
        out += "# aircraft_axes: x avant, y gauche, z haut ; accel = force spécifique en g (1 g vers le haut au repos) ; gyro en °/s, biais retiré\n"
        out += "# sensor_signs: accel \(signs(config.accelSign)) gyro \(signs(config.gyroSign)) (valeurs brutes × signe = repère avant / gauche / haut du boîtier)\n"
        if let mounting {
            out += "# mounting_pitch_deg: \(String(format: "%.3f", mounting.pitch))\n"
            out += "# mounting_roll_deg: \(String(format: "%.3f", mounting.roll))\n"
            let q = mounting.rotation
            out += "# mounting_quaternion: \(String(format: "%.9f %.9f %.9f %.9f", q.real, q.imag.x, q.imag.y, q.imag.z))\n"
            out += "# mounting_calibrated_at_s: \(String(format: "%.2f", mounting.time))\n"
            out += "# mounting_calibrated_speed_kmh: \(String(format: "%.1f", mounting.speedKmh))\n"
        } else {
            out += "# mounting: none (attitude du boîtier)\n"
        }
        out += "# speed_is_3d: \(config.speedIsThreeD ? 1 : 0)\n"
        out += "# columns: \(columns.count)\n"
        out += columns.joined(separator: ",") + "\n"

        // MARK: Lignes
        let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for (k, sample) in samples.enumerated() {
            let raw = track.points[result.pointIndices[k]]
            let aircraft = (sample.attitude * mount).normalized
            let angles = Attitude.euler(aircraft)
            let box = Attitude.euler(sample.attitude)

            // Force spécifique et vitesses de rotation : brut → avant / gauche / haut du boîtier → axes de l'avion.
            let fBox = SIMD3(raw.gX, raw.gY, raw.gZ) * config.accelSign
            let wBox = SIMD3(raw.rollRate, raw.pitchRate, raw.yawRate) * config.gyroSign - sample.gyroBias
            let f = unmount.act(fBox)
            let w = unmount.act(wBox)
            let load = (fBox.x * fBox.x + fBox.y * fBox.y + fBox.z * fBox.z).squareRoot()

            var fields: [String] = []
            fields.reserveCapacity(columns.count)
            func add(_ value: Double, _ digits: Int) {
                fields.append(value.isFinite ? String(format: "%.\(digits)f", value) : "")
            }
            fields.append(track.startDate.map { ($0.addingTimeInterval(sample.time)).formatted(isoStyle) } ?? "")
            add(sample.time, 3)
            add(sample.latitude, 8); add(sample.longitude, 8); add(sample.altitude, 3)
            add(sample.velocity.x, 3); add(sample.velocity.y, 3); add(sample.velocity.z, 3)
            add(sample.groundSpeed, 3); add(sample.groundSpeed * 3.6, 2)
            add(angles.heading, 3); add(angles.pitch, 3); add(angles.roll, 3)
            add(aircraft.real, 6); add(aircraft.imag.x, 6); add(aircraft.imag.y, 6); add(aircraft.imag.z, 6)
            add(box.heading, 3); add(box.pitch, 3); add(box.roll, 3)
            add(f.x, 4); add(f.y, 4); add(f.z, 4); add(load, 4)
            add(w.x, 3); add(w.y, 3); add(w.z, 3)
            add(sample.gyroBias.x, 4); add(sample.gyroBias.y, 4); add(sample.gyroBias.z, 4)
            let hasPosition = raw.hasPosition
            add(hasPosition ? raw.latitude : .nan, 8); add(hasPosition ? raw.longitude : .nan, 8)
            add(hasPosition ? raw.altitude : .nan, 3)
            add(raw.speed, 3); add(raw.heading, 3)
            add(raw.hAcc, 3); add(raw.vAcc, 3); add(raw.speedAcc, 3); add(raw.headingAcc, 3)
            add(raw.satellites, 0); add(raw.fix, 0)
            add(raw.gX, 4); add(raw.gY, 4); add(raw.gZ, 4)
            add(raw.rollRate, 3); add(raw.pitchRate, 3); add(raw.yawRate, 3)
            out += fields.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    private static func signs(_ v: SIMD3<Double>) -> String {
        "\(Int(v.x)) \(Int(v.y)) \(Int(v.z))"
    }
}

// MARK: - Lecture d'un .fgpx

/// Fusion relue dans un .fgpx : de quoi alimenter la visionneuse Fusion sans recalculer.
nonisolated struct FGPXDocument: Sendable, Identifiable {
    let id = UUID()
    /// Trajectoire « brute » reconstruite (GNSS et IMU tels qu'enregistrés), alignée échantillon par échantillon sur la fusion.
    let track: FlightTrack
    let result: FusionResult
    let mounting: MountingCalibration?
    let config: FusionConfig
    let isSmoothed: Bool
}

nonisolated enum FGPXReader {
    enum ReadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Fichier .fgpx illisible : \(detail)"
            }
        }
    }

    private static let requiredColumns = ["t_s", "lat_deg", "lon_deg", "alt_msl_m", "vel_e_ms", "vel_n_ms", "vel_u_ms",
                                          "qw", "qx", "qy", "qz"]

    static func read(_ text: String, name: String) throws -> FGPXDocument {
        var meta: [String: String] = [:]
        var index: [String: Int]?
        var samples: [FusedSample] = []
        var points: [TrackPoint] = []
        var mountRotation = MountingCalibration.identity.rotation
        var frame: LocalFrame?
        var squaredError = 0.0, errorCount = 0

        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("FGPX") {
                    let version = Int(body.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 1
                    guard version <= FGPXExport.version else {
                        throw ReadError.invalid("version \(version) plus récente que celle prise en charge (\(FGPXExport.version))")
                    }
                } else if let colon = body.firstIndex(of: ":") {
                    meta[String(body[..<colon])] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let columns = index else {
                var map: [String: Int] = [:]
                for (i, field) in fields.enumerated() { map[field.trimmingCharacters(in: .whitespaces)] = i }
                if let missing = requiredColumns.first(where: { map[$0] == nil }) {
                    throw ReadError.invalid("colonne « \(missing) » absente")
                }
                index = map
                mountRotation = mountingRotation(meta)
                continue
            }
            func value(_ column: String) -> Double {
                guard let i = columns[column], i < fields.count else { return .nan }
                return Double(fields[i]) ?? .nan
            }
            let time = value("t_s"), lat = value("lat_deg"), lon = value("lon_deg")
            guard time.isFinite, lat.isFinite, lon.isFinite else { continue }

            // Le fichier contient l'attitude de l'AVION ; la visionneuse part de celle du boîtier et applique le calage.
            let aircraft = simd_quatd(ix: value("qx"), iy: value("qy"), iz: value("qz"), r: value("qw")).normalized
            let box = (aircraft * mountRotation.inverse).normalized
            let angles = Attitude.euler(box)
            samples.append(FusedSample(
                time: time, latitude: lat, longitude: lon, altitude: value("alt_msl_m"),
                velocity: SIMD3(value("vel_e_ms"), value("vel_n_ms"), value("vel_u_ms")), attitude: box,
                heading: angles.heading, pitch: angles.pitch, roll: angles.roll,
                gyroBias: SIMD3(value("gyro_bias_x_dps"), value("gyro_bias_y_dps"), value("gyro_bias_z_dps"))))

            var p = TrackPoint(id: points.count, time: time)
            p.latitude = value("lat_raw_deg"); p.longitude = value("lon_raw_deg"); p.altitude = value("alt_raw_m")
            p.speed = value("speed_raw_ms"); p.heading = value("heading_raw_deg")
            p.gX = value("g_x"); p.gY = value("g_y"); p.gZ = value("g_z")
            p.rollRate = value("gyro_x_dps"); p.pitchRate = value("gyro_y_dps"); p.yawRate = value("gyro_z_dps")
            p.satellites = value("satellites"); p.fix = value("fix")
            p.hAcc = value("h_acc_m"); p.vAcc = value("v_acc_m")
            p.speedAcc = value("speed_acc_ms"); p.headingAcc = value("heading_acc_deg")
            points.append(p)

            let origin = frame ?? LocalFrame(latitude: lat, longitude: lon, altitude: 0)
            frame = origin
            if p.hasPosition {
                let fused = origin.enu(latitude: lat, longitude: lon, altitude: 0)
                let rawPosition = origin.enu(latitude: p.latitude, longitude: p.longitude, altitude: 0)
                squaredError += (fused.x - rawPosition.x) * (fused.x - rawPosition.x) + (fused.y - rawPosition.y) * (fused.y - rawPosition.y)
                errorCount += 1
            }
        }
        guard index != nil else { throw ReadError.invalid("en-tête de colonnes introuvable") }
        guard samples.count >= 2 else { throw ReadError.invalid("moins de deux échantillons") }

        let isSmoothed = meta["smoothed"] == "1"
        var diagnostics = FusionDiagnostics()
        diagnostics.sampleCount = samples.count
        diagnostics.headingInitialized = true
        diagnostics.correctionRMS = errorCount > 0 ? (squaredError / Double(errorCount)).squareRoot() : .nan
        let result = FusionResult(filtered: samples, smoothed: isSmoothed ? samples : nil,
                                  pointIndices: Array(samples.indices), diagnostics: diagnostics)

        var config = FusionConfig()
        if let signs = meta["sensor_signs"] {
            let tokens = signs.split(separator: " ").map(String.init)
            func vector(after key: String) -> SIMD3<Double>? {
                guard let i = tokens.firstIndex(of: key), i + 3 < tokens.count,
                      let x = Double(tokens[i + 1]), let y = Double(tokens[i + 2]), let z = Double(tokens[i + 3]) else { return nil }
                return SIMD3(x, y, z)
            }
            if let accel = vector(after: "accel") { config.accelSign = accel }
            if let gyro = vector(after: "gyro") { config.gyroSign = gyro }
        }
        config.speedIsThreeD = meta["speed_is_3d"] != "0"

        var mounting: MountingCalibration?
        if let pitch = meta["mounting_pitch_deg"].flatMap(Double.init) {
            mounting = MountingCalibration(rotation: mountRotation, pitch: pitch,
                                           roll: meta["mounting_roll_deg"].flatMap(Double.init) ?? 0,
                                           time: meta["mounting_calibrated_at_s"].flatMap(Double.init) ?? 0,
                                           speedKmh: meta["mounting_calibrated_speed_kmh"].flatMap(Double.init) ?? 0)
        }

        let startDate = meta["start_utc"].flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let track = FlightTrack(name: meta["source"] ?? name, startDate: startDate, points: points)
        return FGPXDocument(track: track, result: result, mounting: mounting, config: config, isSmoothed: isSmoothed)
    }

    /// Rotation avion → boîtier du calage : quaternion écrit dans le fichier, sinon reconstruit à partir des angles.
    private static func mountingRotation(_ meta: [String: String]) -> simd_quatd {
        if let text = meta["mounting_quaternion"] {
            let v = text.split(separator: " ").compactMap { Double($0) }
            if v.count == 4 { return simd_quatd(ix: v[1], iy: v[2], iz: v[3], r: v[0]).normalized }
        }
        guard let pitch = meta["mounting_pitch_deg"].flatMap(Double.init) else { return MountingCalibration.identity.rotation }
        let roll = meta["mounting_roll_deg"].flatMap(Double.init) ?? 0
        return (Attitude.exp(SIMD3(0, -pitch * .pi / 180, 0)) * Attitude.exp(SIMD3(roll * .pi / 180, 0, 0))).normalized
    }
}
