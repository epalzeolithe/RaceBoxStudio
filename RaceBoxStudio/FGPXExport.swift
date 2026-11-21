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
