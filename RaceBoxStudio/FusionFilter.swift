import Foundation
import simd

// Fusion GNSS / IMU : filtre de Kalman étendu à état d'erreur (ESKF) à 15 états, couplage lâche,
// suivi d'un lisseur de Rauch-Tung-Striebel (passe arrière) pour le post-traitement.
//
// Repères
// - Navigation : ENU local (x = est, y = nord, z = haut), origine au premier fix valide.
// - Boîtier : avant (x), gauche (y), haut (z), repère direct. `FusionConfig.accelSign` / `gyroSign`
//   corrigent les signes si les axes du RaceBox diffèrent.
// - Attitude : quaternion boîtier → ENU. L'erreur d'attitude δθ est exprimée dans le repère du boîtier.
//
// État d'erreur (15) : position 0…2, vitesse 3…5, attitude 6…8, biais accéléromètre 9…11, biais gyro 12…14.

// MARK: - Réglages

nonisolated struct FusionConfig: Sendable {
    var gravity = 9.80665
    /// Signes appliqués aux axes du boîtier pour obtenir le repère avant / gauche / haut.
    /// Déterminés sur un vol réel (V30) en testant les 24 orientations possibles : le repère du RaceBox est tourné
    /// de 180° autour de la verticale par rapport à avant / gauche / haut (X et Y inversés, accéléromètre et gyro).
    var accelSign = SIMD3<Double>(-1, -1, 1)
    var gyroSign = SIMD3<Double>(-1, -1, 1)
    /// Le gyro sature à ±320 °/s : au-delà de ce seuil l'échantillon n'est plus fiable.
    var gyroSaturation = 315.0
    /// Vrai si la vitesse du récepteur est la vitesse 3D (réglage « Vitesse 3D » du boîtier), faux si vitesse sol.
    var speedIsThreeD = true
    /// Pseudo-mesure « pas de vitesse latérale » dans le repère du boîtier (vol coordonné, sans dérapage).
    var useNonHolonomic = true

    // Bruits de processus (densités continues).
    var gyroNoise = 0.003       // rad/s/√Hz
    var accelNoise = 1.0        // m/s²/√Hz (voltige : vibrations, échantillons IMU instantanés à 25 Hz)
    var gyroBiasWalk = 2e-3     // rad/s/√s (le biais dérive en vol, avec la température)
    var accelBiasWalk = 2e-3    // m/s²/√s

    // Mesures GNSS. Le récepteur filtre déjà ses sorties : elles sont corrélées dans le temps, donc on gonfle leur bruit.
    var positionNoiseScale = 2.0
    var speedNoiseScale = 2.0
    var minPositionSigma = 0.5
    var defaultHAcc = 3.0
    var defaultVAcc = 5.0
    var defaultSpeedAcc = 0.3
    var defaultHeadingAcc = 2.0  // degrés
    /// En dessous, la direction de la vitesse n'est pas exploitable.
    var courseMinSpeed = 3.0
    /// Vitesse à partir de laquelle le cap GNSS initialise le lacet.
    var headingInitSpeed = 4.0

    /// Écart entre cap du nez et route sol (dérive due au vent, dérapage), radians.
    var crabSigma = 0.12
    var nhcSigma = 2.0           // m/s
    var nhcMinSpeed = 8.0
    var stationarySpeed = 0.5
    /// Une mesure rejetée par le test de Mahalanobis plus de N fois d'affilée est acceptée (filtre resynchronisé).
    var maxConsecutiveRejections = 25
    /// Trou de données au-delà duquel le filtre repart de la mesure GNSS.
    var maxGap = 1.0
    /// Au-delà, on saute le lisseur (≈ 225 floats stockés par échantillon).
    var maxSmoothedSamples = 300_000
}

// MARK: - Résultats

nonisolated struct FusedSample: Sendable {
    /// Secondes depuis le premier point de la trajectoire (même origine que `TrackPoint.time`).
    let time: Double
    let latitude: Double
    let longitude: Double
    let altitude: Double
    /// Vitesse ENU, m/s.
    let velocity: SIMD3<Double>
    /// Attitude boîtier → ENU.
    let attitude: simd_quatd
    /// Degrés : cap 0…360 (nord = 0, horaire), tangage (nez en haut > 0), roulis (aile droite basse > 0).
    let heading: Double
    let pitch: Double
    let roll: Double
    /// Biais gyro estimé, °/s.
    let gyroBias: SIMD3<Double>

    var groundSpeed: Double { (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot() }
}

nonisolated struct FusionDiagnostics: Sendable {
    var sampleCount = 0
    var rejectedPositions = 0
    var rejectedVelocities = 0
    var saturatedGyroSamples = 0
    /// Le cap initial vient du cap GNSS (sinon le lacet est resté inconnu).
    var headingInitialized = false
    var startedStationary = false
    /// Corrélation entre la vitesse de lacet du gyro et la variation du cap GNSS : proche de 1 si les axes sont bons,
    /// négative si le signe du gyro Z est inversé. NaN sans virage.
    var yawCorrelation = Double.nan
    /// Écart quadratique moyen horizontal entre positions GNSS brutes et trajectoire corrigée, en mètres.
    var correctionRMS = Double.nan
    var smoothingSkipped = false
}

nonisolated struct FusionResult: Sendable {
    let filtered: [FusedSample]
    /// nil si la trajectoire est trop longue pour le lisseur.
    let smoothed: [FusedSample]?
    /// Pour chaque échantillon, l'indice du point d'origine dans `FlightTrack.points`.
    let pointIndices: [Int]
    let diagnostics: FusionDiagnostics

    func samples(smoothed useSmoothed: Bool) -> [FusedSample] {
        useSmoothed ? (smoothed ?? filtered) : filtered
    }

    /// Indice de l'échantillon le plus proche de `time`.
    static func nearestIndex(in samples: [FusedSample], time: Double) -> Int {
        guard !samples.isEmpty else { return 0 }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(samples[low - 1].time - time) < abs(samples[low].time - time) { return low - 1 }
        return low
    }
}

// MARK: - Calage du boîtier sur l'avion

/// Montage du boîtier, déduit d'un instant où l'avion est connu à plat (roulis = tangage = 0).
nonisolated struct MountingCalibration: Sendable {
    /// Rotation avion → boîtier : attitude de l'avion = attitude du boîtier · rotation.
    let rotation: simd_quatd
    /// Tangage du montage en degrés : positif si le nez du boîtier est sous l'axe de l'avion.
    let pitch: Double
    /// Roulis du montage en degrés (aile droite du boîtier plus basse que celle de l'avion si > 0).
    let roll: Double
    /// Instant de calage (s depuis le début) et vitesse sol à cet instant.
    let time: Double
    let speedKmh: Double

    static let identity = MountingCalibration(rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                                              pitch: 0, roll: 0, time: 0, speedKmh: 0)

    /// Premier passage au-dessus de `speedKmh` : l'avion y est supposé à plat. Le lacet du montage n'est pas
    /// observable avec ce seul instant (il est pris nul : l'axe avant de l'avion est la projection de celui du boîtier).
    static func calibrate(samples: [FusedSample], atSpeedKmh speedKmh: Double = 100) -> MountingCalibration? {
        guard let index = samples.firstIndex(where: { $0.groundSpeed * 3.6 >= speedKmh }) else { return nil }
        let time = samples[index].time
        // Moyenne sur ±0,5 s de la verticale vue du boîtier.
        var up = SIMD3<Double>.zero
        for sample in samples where abs(sample.time - time) <= 0.5 {
            up += simd_matrix3x3(sample.attitude).transpose * SIMD3(0, 0, 1)
        }
        guard simd_length(up) > 0.5 else { return nil }
        up = simd_normalize(up)
        // Repère avion exprimé dans le repère du boîtier : z = verticale, x = avant du boîtier mis à l'horizontale.
        let forward = simd_normalize(SIMD3<Double>(1, 0, 0) - simd_dot(SIMD3(1, 0, 0), up) * up)
        let left = simd_cross(up, forward)
        let rotation = simd_quatd(simd_double3x3(columns: (forward, left, up))).normalized
        let angles = Attitude.euler(rotation)
        return MountingCalibration(rotation: rotation, pitch: angles.pitch, roll: angles.roll,
                                   time: time, speedKmh: samples[index].groundSpeed * 3.6)
    }
}

// MARK: - Repère local

nonisolated struct LocalFrame: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let metersPerDegreeLat: Double
    let metersPerDegreeLon: Double

    init(latitude: Double, longitude: Double, altitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        let phi = latitude * .pi / 180
        metersPerDegreeLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        metersPerDegreeLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi)
    }

    func enu(latitude lat: Double, longitude lon: Double, altitude alt: Double) -> SIMD3<Double> {
        SIMD3((lon - longitude) * metersPerDegreeLon, (lat - latitude) * metersPerDegreeLat, alt - altitude)
    }

    func geodetic(_ p: SIMD3<Double>) -> (latitude: Double, longitude: Double, altitude: Double) {
        (latitude + p.y / metersPerDegreeLat, longitude + p.x / metersPerDegreeLon, altitude + p.z)
    }
}

// MARK: - Matrice dense (15 × 15 au plus : pas besoin d'Accelerate)

nonisolated struct DenseMatrix: Sendable {
    let rows: Int
    let cols: Int
    var storage: [Double]

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        storage = [Double](repeating: 0, count: rows * cols)
    }

    init(column values: [Double]) {
        rows = values.count
        cols = 1
        storage = values
    }

    static func identity(_ n: Int) -> DenseMatrix {
        var m = DenseMatrix(rows: n, cols: n)
        for i in 0..<n { m[i, i] = 1 }
        return m
    }

    subscript(row: Int, col: Int) -> Double {
        get { storage[row * cols + col] }
        set { storage[row * cols + col] = newValue }
    }

    var transposed: DenseMatrix {
        var out = DenseMatrix(rows: cols, cols: rows)
        for r in 0..<rows { for c in 0..<cols { out[c, r] = self[r, c] } }
        return out
    }

    /// Copie un bloc 3 × 3 (simd est rangé par colonnes).
    mutating func setBlock(row: Int, col: Int, _ block: simd_double3x3, scale: Double = 1) {
        for c in 0..<3 { for r in 0..<3 { self[row + r, col + c] = block[c][r] * scale } }
    }

    static func * (lhs: DenseMatrix, rhs: DenseMatrix) -> DenseMatrix {
        var out = DenseMatrix(rows: lhs.rows, cols: rhs.cols)
        let n = lhs.rows, m = lhs.cols, p = rhs.cols
        lhs.storage.withUnsafeBufferPointer { a in
            rhs.storage.withUnsafeBufferPointer { b in
                out.storage.withUnsafeMutableBufferPointer { c in
                    for i in 0..<n {
                        for k in 0..<m {
                            let x = a[i * m + k]
                            if x == 0 { continue } // F est très creuse
                            for j in 0..<p { c[i * p + j] += x * b[k * p + j] }
                        }
                    }
                }
            }
        }
        return out
    }

    static func + (lhs: DenseMatrix, rhs: DenseMatrix) -> DenseMatrix {
        var out = lhs
        for i in out.storage.indices { out.storage[i] += rhs.storage[i] }
        return out
    }

    static func - (lhs: DenseMatrix, rhs: DenseMatrix) -> DenseMatrix {
        var out = lhs
        for i in out.storage.indices { out.storage[i] -= rhs.storage[i] }
        return out
    }

    /// Résout A·X = B (Cholesky) pour A symétrique définie positive. Une petite régularisation rattrape
    /// les pertes de positivité dues aux arrondis ; nil si A reste inutilisable.
    static func solveSPD(_ a: DenseMatrix, _ b: DenseMatrix) -> DenseMatrix? {
        let n = a.rows
        var jitter = 0.0
        let scale = (0..<n).reduce(0.0) { $0 + abs(a[$1, $1]) } / Double(max(n, 1))
        for _ in 0..<4 {
            if let x = cholesky(a, b, jitter: jitter) { return x }
            jitter = jitter == 0 ? max(scale, 1e-12) * 1e-10 : jitter * 100
        }
        return nil
    }

    private static func cholesky(_ a: DenseMatrix, _ b: DenseMatrix, jitter: Double) -> DenseMatrix? {
        let n = a.rows
        var l = DenseMatrix(rows: n, cols: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i, j] + (i == j ? jitter : 0)
                for k in 0..<j { sum -= l[i, k] * l[j, k] }
                if i == j {
                    guard sum > 0, sum.isFinite else { return nil }
                    l[i, i] = sum.squareRoot()
                } else {
                    l[i, j] = sum / l[j, j]
                }
            }
        }
        var x = b
        for c in 0..<b.cols {
            for i in 0..<n {
                var s = x[i, c]
                for k in 0..<i { s -= l[i, k] * x[k, c] }
                x[i, c] = s / l[i, i]
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                var s = x[i, c]
                for k in (i + 1)..<n { s -= l[k, i] * x[k, c] }
                x[i, c] = s / l[i, i]
            }
        }
        return x
    }
}

// MARK: - Géométrie de l'attitude

nonisolated enum Attitude {
    static func skew(_ v: SIMD3<Double>) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(0, v.z, -v.y), SIMD3(-v.z, 0, v.x), SIMD3(v.y, -v.x, 0)))
    }

    /// Quaternion de la rotation de vecteur `v` (exponentielle).
    static func exp(_ v: SIMD3<Double>) -> simd_quatd {
        let angle = simd_length(v)
        if angle < 1e-9 { return simd_quatd(ix: v.x / 2, iy: v.y / 2, iz: v.z / 2, r: 1).normalized }
        let s = sin(angle / 2) / angle
        return simd_quatd(ix: v.x * s, iy: v.y * s, iz: v.z * s, r: cos(angle / 2))
    }

    /// Attitude pour une verticale `up` (vue du boîtier) et un cap donnés (radians, horaire depuis le nord).
    static func make(upInBody up: SIMD3<Double>, heading: Double) -> simd_quatd {
        var forward = SIMD3<Double>(1, 0, 0) - simd_dot(SIMD3(1, 0, 0), up) * up
        if simd_length(forward) < 1e-6 { forward = SIMD3(0, 1, 0) } // nez à la verticale : cas dégénéré
        forward = simd_normalize(forward)
        let left = simd_cross(up, forward)
        let forwardNav = SIMD3(sin(heading), cos(heading), 0)
        let leftNav = SIMD3(-cos(heading), sin(heading), 0)
        let nav = simd_double3x3(columns: (forwardNav, leftNav, SIMD3(0, 0, 1)))
        let body = simd_double3x3(columns: (forward, left, up))
        return simd_quatd(nav * body.transpose).normalized
    }

    /// Cap (0…360), tangage et roulis en degrés.
    static func euler(_ q: simd_quatd) -> (heading: Double, pitch: Double, roll: Double) {
        let r = simd_matrix3x3(q)
        let forward = r.columns.0, left = r.columns.1, up = r.columns.2
        var heading = atan2(forward.x, forward.y) * 180 / .pi
        if heading < 0 { heading += 360 }
        let pitch = asin(max(-1, min(1, forward.z))) * 180 / .pi
        let roll = atan2(left.z, up.z) * 180 / .pi
        return (heading, pitch, roll)
    }
}

// MARK: - Filtre

nonisolated enum FusionFilter {
    /// Mesures de l'IMU converties en repère avant / gauche / haut, SI.
    private struct IMUReading {
        var w: SIMD3<Double>      // rad/s
        var f: SIMD3<Double>      // force spécifique, m/s²
        var saturated: Bool

        init?(_ p: TrackPoint, _ config: FusionConfig) {
            guard p.gX.isFinite, p.gY.isFinite, p.gZ.isFinite,
                  p.rollRate.isFinite, p.pitchRate.isFinite, p.yawRate.isFinite else { return nil }
            f = SIMD3(p.gX, p.gY, p.gZ) * config.gravity * config.accelSign
            let dps = SIMD3(p.rollRate, p.pitchRate, p.yawRate) * config.gyroSign
            saturated = max(abs(dps.x), abs(dps.y), abs(dps.z)) >= config.gyroSaturation
            w = dps * (.pi / 180)
        }
    }

    private struct Snapshot {
        var p: SIMD3<Double>
        var v: SIMD3<Double>
        var q: simd_quatd
        var ba: SIMD3<Double>
        var bg: SIMD3<Double>

        func corrected(by e: [Double]) -> Snapshot {
            Snapshot(p: p + SIMD3(e[0], e[1], e[2]), v: v + SIMD3(e[3], e[4], e[5]),
                     q: (q * Attitude.exp(SIMD3(e[6], e[7], e[8]))).normalized,
                     ba: ba + SIMD3(e[9], e[10], e[11]), bg: bg + SIMD3(e[12], e[13], e[14]))
        }

        func sample(time: Double, frame: LocalFrame) -> FusedSample {
            let geo = frame.geodetic(p)
            let angles = Attitude.euler(q)
            return FusedSample(time: time, latitude: geo.latitude, longitude: geo.longitude, altitude: geo.altitude,
                               velocity: v, attitude: q, heading: angles.heading, pitch: angles.pitch,
                               roll: angles.roll, gyroBias: bg * (180 / .pi))
        }
    }

    private enum Channel: Int, CaseIterable {
        case position, speed, course, heading, lateral, stationary
    }

    /// Seuils du χ² à 99,9 % pour 1, 2 et 3 degrés de liberté (test de Mahalanobis).
    private static let chiSquare: [Double] = [10.83, 13.82, 16.27]

    // MARK: Moteur ESKF

    private struct Engine {
        let config: FusionConfig
        var p = SIMD3<Double>.zero
        var v = SIMD3<Double>.zero
        var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        var ba = SIMD3<Double>.zero
        var bg = SIMD3<Double>.zero
        var covariance = DenseMatrix.identity(15)
        /// Correction injectée pendant l'échantillon en cours : sert au lisseur.
        var pending = [Double](repeating: 0, count: 15)
        var streak = [Int](repeating: 0, count: Channel.allCases.count)
        var rejections = [Int](repeating: 0, count: Channel.allCases.count)

        init(config: FusionConfig) { self.config = config }

        var snapshot: Snapshot { Snapshot(p: p, v: v, q: q, ba: ba, bg: bg) }

        /// Prédiction entre deux échantillons IMU : mécanisation (trapèze + compensation de conisation),
        /// puis propagation de la covariance. Renvoie la matrice de lissage C = P·Fᵀ·P⁻ (225 valeurs).
        mutating func predict(from a: IMUReading, to b: IMUReading, dt: Double, attitudeNoiseScale: Double,
                              wantsSmoother: Bool) -> [Float] {
            let gravity = SIMD3<Double>(0, 0, -config.gravity)
            let w0 = a.w - bg, w1 = b.w - bg
            let f0 = a.f - ba, f1 = b.f - ba

            let r0 = simd_matrix3x3(q)
            let acc0 = r0 * f0 + gravity
            // Rotation sur le pas : vitesse angulaire moyenne + terme de conisation à deux échantillons.
            let dTheta = 0.5 * (w0 + w1) * dt + (dt * dt / 12) * simd_cross(w0, w1)
            let qNew = (q * Attitude.exp(dTheta)).normalized
            let acc1 = simd_matrix3x3(qNew) * f1 + gravity

            p += v * dt + (acc0 / 3 + acc1 / 6) * dt * dt
            v += 0.5 * (acc0 + acc1) * dt
            q = qNew

            // F = exp(A·dt) à l'ordre 2.
            let wm = 0.5 * (w0 + w1), fm = 0.5 * (f0 + f1)
            var adt = DenseMatrix(rows: 15, cols: 15)
            adt.setBlock(row: 0, col: 3, matrix_identity_double3x3, scale: dt)
            adt.setBlock(row: 3, col: 6, r0 * Attitude.skew(fm), scale: -dt)
            adt.setBlock(row: 3, col: 9, r0, scale: -dt)
            adt.setBlock(row: 6, col: 6, Attitude.skew(wm), scale: -dt)
            adt.setBlock(row: 6, col: 12, matrix_identity_double3x3, scale: -dt)
            let f = DenseMatrix.identity(15) + adt + adt * adt.storageScaled(0.5)

            var noise = DenseMatrix(rows: 15, cols: 15)
            for i in 3..<6 { noise[i, i] = config.accelNoise * config.accelNoise * dt }
            for i in 6..<9 { noise[i, i] = config.gyroNoise * config.gyroNoise * dt * attitudeNoiseScale }
            for i in 9..<12 { noise[i, i] = config.accelBiasWalk * config.accelBiasWalk * dt }
            for i in 12..<15 { noise[i, i] = config.gyroBiasWalk * config.gyroBiasWalk * dt }

            let previous = covariance
            covariance = f * previous * f.transposed + noise
            symmetrize()

            guard wantsSmoother else { return [] }
            // C = P_k|k · Fᵀ · P_k+1|k⁻¹, soit Cᵀ = P_k+1|k⁻¹ · F · P_k|k.
            guard let x = DenseMatrix.solveSPD(covariance, f * previous) else {
                return [Float](repeating: 0, count: 225)
            }
            return x.transposed.storage.map(Float.init)
        }

        mutating func symmetrize() {
            for i in 0..<15 {
                for j in 0..<i {
                    let m = 0.5 * (covariance[i, j] + covariance[j, i])
                    covariance[i, j] = m
                    covariance[j, i] = m
                }
                covariance[i, i] = max(covariance[i, i], 1e-14)
            }
        }

        /// Mise à jour par mesure(s) indépendante(s) : innovation `y`, jacobienne `h`, variances `r`.
        /// Renvoie faux si la mesure est rejetée (Mahalanobis) ou inutilisable.
        @discardableResult
        mutating func update(_ channel: Channel, y: [Double], h: DenseMatrix, variance r: [Double],
                             gated: Bool = true) -> Bool {
            let m = y.count
            let hp = h * covariance
            var s = hp * h.transposed
            for i in 0..<m { s[i, i] += r[i] }
            guard let sy = DenseMatrix.solveSPD(s, DenseMatrix(column: y)),
                  let x = DenseMatrix.solveSPD(s, hp) else { return false }
            if gated {
                var d2 = 0.0
                for i in 0..<m { d2 += y[i] * sy[i, 0] }
                if d2 > FusionFilter.chiSquare[min(m, 3) - 1] {
                    streak[channel.rawValue] += 1
                    if streak[channel.rawValue] < config.maxConsecutiveRejections {
                        rejections[channel.rawValue] += 1
                        return false
                    }
                }
            }
            streak[channel.rawValue] = 0
            let k = x.transposed // 15 × m : P·Hᵀ·S⁻¹
            var dx = [Double](repeating: 0, count: 15)
            for i in 0..<15 { for j in 0..<m { dx[i] += k[i, j] * y[j] } }
            covariance = covariance - k * hp
            symmetrize()
            inject(dx)
            return true
        }

        /// Ajoute l'erreur estimée à l'état nominal ; l'erreur retombe à zéro.
        mutating func inject(_ dx: [Double]) {
            p += SIMD3(dx[0], dx[1], dx[2])
            v += SIMD3(dx[3], dx[4], dx[5])
            q = (q * Attitude.exp(SIMD3(dx[6], dx[7], dx[8]))).normalized
            ba += SIMD3(dx[9], dx[10], dx[11])
            bg += SIMD3(dx[12], dx[13], dx[14])
            for i in 0..<15 { pending[i] += dx[i] }
        }

        // MARK: Mesures

        mutating func updatePosition(_ z: SIMD3<Double>, sigmaH: Double, sigmaV: Double?) {
            let m = sigmaV == nil ? 2 : 3
            var h = DenseMatrix(rows: m, cols: 15)
            for i in 0..<m { h[i, i] = 1 }
            let y = (0..<m).map { z[$0] - p[$0] }
            var r = [sigmaH * sigmaH, sigmaH * sigmaH]
            if let sigmaV { r.append(sigmaV * sigmaV) }
            update(.position, y: y, h: h, variance: r)
        }

        /// Norme de la vitesse (3D ou sol) fournie par le récepteur.
        mutating func updateSpeed(_ measured: Double, sigma: Double, threeD: Bool) {
            let vs = threeD ? v : SIMD3(v.x, v.y, 0)
            let norm = simd_length(vs)
            guard norm > 0.5 else { return }
            var h = DenseMatrix(rows: 1, cols: 15)
            for k in 0..<(threeD ? 3 : 2) { h[0, 3 + k] = vs[k] / norm }
            update(.speed, y: [measured - norm], h: h, variance: [sigma * sigma])
        }

        /// Direction de la vitesse (cap de route, radians, horaire depuis le nord).
        mutating func updateCourse(_ measured: Double, sigma: Double) {
            let h2 = v.x * v.x + v.y * v.y
            guard h2 > 1 else { return }
            var h = DenseMatrix(rows: 1, cols: 15)
            h[0, 3] = v.y / h2
            h[0, 4] = -v.x / h2
            var innovation = measured - atan2(v.x, v.y)
            while innovation > .pi { innovation -= 2 * .pi }
            while innovation < -.pi { innovation += 2 * .pi }
            update(.course, y: [innovation], h: h, variance: [sigma * sigma])
        }

        /// Cap du nez ≈ route sol : seule mesure qui ancre le lacet de façon absolue (lève l'ambiguïté de 180°
        /// que la contrainte latérale ne voit pas).
        mutating func updateHeading(courseRadians: Double, sigma: Double) {
            let r = simd_matrix3x3(q)
            let forward = r.columns.0
            let h2 = forward.x * forward.x + forward.y * forward.y
            guard h2 > 0.09 else { return } // nez trop vertical : le cap n'a plus de sens
            // δforward = −R·[e_x]×·δθ
            let m = -(r * Attitude.skew(SIMD3(1, 0, 0)))
            var h = DenseMatrix(rows: 1, cols: 15)
            for k in 0..<3 { h[0, 6 + k] = (forward.y * m[k][0] - forward.x * m[k][1]) / h2 }
            var innovation = courseRadians - atan2(forward.x, forward.y)
            while innovation > .pi { innovation -= 2 * .pi }
            while innovation < -.pi { innovation += 2 * .pi }
            update(.heading, y: [innovation], h: h, variance: [sigma * sigma])
        }

        /// Vitesse latérale nulle dans le repère du boîtier.
        mutating func updateLateral(sigma: Double) {
            let r = simd_matrix3x3(q)
            let w = r.transpose * v
            var h = DenseMatrix(rows: 1, cols: 15)
            let left = r.columns.1
            for k in 0..<3 { h[0, 3 + k] = left[k] }
            h[0, 6] = w.z
            h[0, 8] = -w.x
            update(.lateral, y: [-w.y], h: h, variance: [sigma * sigma])
        }

        /// À l'arrêt : vitesse nulle, rotation nulle (donc gyro = biais) et gravité seule sur l'accéléromètre.
        mutating func updateStationary(_ imu: IMUReading) {
            var hv = DenseMatrix(rows: 3, cols: 15)
            for k in 0..<3 { hv[k, 3 + k] = 1 }
            update(.stationary, y: [-v.x, -v.y, -v.z], h: hv, variance: [0.0025, 0.0025, 0.0025], gated: false)

            var hg = DenseMatrix(rows: 3, cols: 15)
            for k in 0..<3 { hg[k, 12 + k] = 1 }
            let yg = imu.w - bg
            update(.stationary, y: [yg.x, yg.y, yg.z], h: hg, variance: [1e-4, 1e-4, 1e-4], gated: false)

            let tilt = simd_matrix3x3(q).transpose * SIMD3(0, 0, config.gravity)
            var ha = DenseMatrix(rows: 3, cols: 15)
            ha.setBlock(row: 0, col: 6, Attitude.skew(tilt))
            for k in 0..<3 { ha[k, 9 + k] = 1 }
            let ya = imu.f - (ba + tilt)
            update(.stationary, y: [ya.x, ya.y, ya.z], h: ha, variance: [0.04, 0.04, 0.04], gated: false)
        }
    }

    // MARK: - Traitement complet

    /// Un fix exploitable : position valide, 3D quand le statut est connu, précision correcte.
    static func isUsableFix(_ p: TrackPoint) -> Bool {
        guard p.hasPosition else { return false }
        if p.fix.isFinite, p.fix < 3 { return false }
        if p.hAcc.isFinite, p.hAcc > 50 { return false }
        return true
    }

    /// nil si la trajectoire n'a pas d'IMU ni assez de positions GNSS.
    static func run(track: FlightTrack, config: FusionConfig = FusionConfig()) -> FusionResult? {
        let points = track.points
        // Échantillons à IMU complète, dans l'ordre strict du temps GNSS (jamais l'heure de réception).
        var candidates: [Int] = []
        var lastTime = -Double.infinity
        for i in points.indices where points[i].time.isFinite && points[i].time > lastTime
            && IMUReading(points[i], config) != nil {
            candidates.append(i)
            lastTime = points[i].time
        }
        guard let startIndex = candidates.firstIndex(where: { isUsableFix(points[$0]) }) else { return nil }
        let steps = Array(candidates[startIndex...])
        guard steps.count >= 10 else { return nil }
        let imus = steps.map { IMUReading(points[$0], config)! }

        let first = points[steps[0]]
        let frame = LocalFrame(latitude: first.latitude, longitude: first.longitude,
                               altitude: first.altitude.isFinite ? first.altitude : 0)
        var diagnostics = FusionDiagnostics()

        // Initialisation : immobilité de départ → gravité (roulis, tangage) et biais du gyro.
        var stillCount = 0
        for i in steps.prefix(100) {
            guard points[i].speed.isFinite, points[i].speed < 0.5 else { break }
            stillCount += 1
        }
        let startsStill = stillCount >= 25
        let window = startsStill ? stillCount : min(25, steps.count)
        var meanF = SIMD3<Double>.zero, meanW = SIMD3<Double>.zero
        for imu in imus.prefix(window) {
            meanF += imu.f
            meanW += imu.w
        }
        meanF /= Double(window)
        meanW /= Double(window)
        let initialBias = startsStill && simd_length(meanW) < 0.5 ? meanW : .zero

        let headingIndex = steps.firstIndex { i in
            let p = points[i]
            return isUsableFix(p) && p.speed.isFinite && p.speed >= config.headingInitSpeed && p.heading.isFinite
        }
        let initialHeading = headingIndex.map { points[steps[$0]].heading * .pi / 180 }
        diagnostics.headingInitialized = initialHeading != nil
        diagnostics.startedStationary = startsStill

        var engine = Engine(config: config)
        let up = simd_length(meanF) > 1 ? simd_normalize(meanF) : SIMD3(0, 0, 1)
        engine.q = Attitude.make(upInBody: up, heading: initialHeading ?? 0)
        engine.bg = initialBias
        let h0 = first.hAcc.isFinite ? first.hAcc : config.defaultHAcc
        let v0 = first.vAcc.isFinite ? first.vAcc : config.defaultVAcc
        if !startsStill, headingIndex == 0, let heading = initialHeading, first.speed.isFinite {
            engine.v = SIMD3(sin(heading), cos(heading), 0) * first.speed
        }
        let yawSigma = headingIndex == 0 ? 0.15 : (initialHeading != nil ? 1.0 : .pi)
        let tiltSigma = startsStill ? 0.05 : 0.2
        let diagonal: [Double] = [h0, h0, v0, startsStill ? 0.1 : 3, startsStill ? 0.1 : 3, startsStill ? 0.1 : 3,
                                  tiltSigma, tiltSigma, yawSigma, 0.3, 0.3, 0.3] + Array(repeating: startsStill ? 0.01 : 0.03, count: 3)
        engine.covariance = DenseMatrix(rows: 15, cols: 15)
        for i in 0..<15 { engine.covariance[i, i] = diagonal[i] * diagonal[i] }

        let wantsSmoother = steps.count <= config.maxSmoothedSamples
        diagnostics.smoothingSkipped = !wantsSmoother
        var snapshots: [Snapshot] = []
        var transitions: [Float] = []
        var corrections: [Float] = []
        var measured: [SIMD2<Double>] = []
        snapshots.reserveCapacity(steps.count)
        if wantsSmoother {
            transitions.reserveCapacity(steps.count * 225)
            corrections.reserveCapacity(steps.count * 15)
        }
        var stillStreak = 0

        for (n, i) in steps.enumerated() {
            let point = points[i], imu = imus[n]
            let usable = isUsableFix(point)
            let gnss = usable ? frame.enu(latitude: point.latitude, longitude: point.longitude,
                                          altitude: point.altitude.isFinite ? point.altitude : frame.altitude) : nil
            engine.pending = [Double](repeating: 0, count: 15)

            // Prédiction.
            var transition = [Float](repeating: 0, count: wantsSmoother ? 225 : 0)
            if n > 0 {
                let dt = point.time - points[steps[n - 1]].time
                if dt > config.maxGap {
                    // Trou : on repart de la mesure GNSS, la covariance est gonflée et le lisseur ne traverse pas le trou.
                    if let gnss { engine.p = gnss }
                    for k in 0..<3 {
                        engine.covariance[k, k] += 100 * 100
                        engine.covariance[3 + k, 3 + k] += 10 * 10
                    }
                } else {
                    if imu.saturated { diagnostics.saturatedGyroSamples += 1 }
                    // Gyro saturé : la valeur lue est une borne basse, on la garde mais on n'a plus confiance dans l'attitude.
                    transition = engine.predict(from: imus[n - 1], to: imu, dt: dt,
                                                attitudeNoiseScale: imu.saturated || imus[n - 1].saturated ? 100 : 1,
                                                wantsSmoother: wantsSmoother)
                }
            }

            // Mises à jour GNSS.
            if let gnss {
                let sigmaH = max(config.minPositionSigma,
                                 (point.hAcc.isFinite ? point.hAcc : config.defaultHAcc) * config.positionNoiseScale)
                let sigmaV = max(config.minPositionSigma,
                                 (point.vAcc.isFinite ? point.vAcc : config.defaultVAcc) * config.positionNoiseScale)
                engine.updatePosition(gnss, sigmaH: sigmaH, sigmaV: point.altitude.isFinite ? sigmaV : nil)
                if point.speed.isFinite {
                    let sigmaS = max(0.05, (point.speedAcc.isFinite ? point.speedAcc : config.defaultSpeedAcc)
                                     * config.speedNoiseScale)
                    engine.updateSpeed(point.speed, sigma: sigmaS, threeD: config.speedIsThreeD)
                    if point.speed >= config.courseMinSpeed, point.heading.isFinite {
                        let headingSigma = (point.headingAcc.isFinite ? point.headingAcc : config.defaultHeadingAcc)
                            * .pi / 180 * config.speedNoiseScale
                        let sigma = (headingSigma * headingSigma + (sigmaS / point.speed) * (sigmaS / point.speed)).squareRoot()
                        engine.updateCourse(point.heading * .pi / 180, sigma: sigma)
                        engine.updateHeading(courseRadians: point.heading * .pi / 180,
                                             sigma: (sigma * sigma + config.crabSigma * config.crabSigma).squareRoot())
                    }
                }
            }

            // Pseudo-mesures propres au véhicule.
            // Le gyro peut avoir plusieurs °/s d'offset au repos : on juge la rotation par rapport au biais estimé.
            let residual = imu.w - engine.bg
            let rotating = max(abs(residual.x), abs(residual.y), abs(residual.z)) > 0.05
            let stationary = usable && point.speed.isFinite && point.speed < config.stationarySpeed && !rotating
                && abs(simd_length(imu.f) - config.gravity) < 0.3
            stillStreak = stationary ? stillStreak + 1 : 0
            if stillStreak >= 3 {
                engine.updateStationary(imu)
            } else if config.useNonHolonomic, !imu.saturated,
                      (engine.v.x * engine.v.x + engine.v.y * engine.v.y).squareRoot() > config.nhcMinSpeed {
                engine.updateLateral(sigma: config.nhcSigma)
            }

            snapshots.append(engine.snapshot)
            measured.append(gnss.map { SIMD2($0.x, $0.y) } ?? SIMD2(.nan, .nan))
            if wantsSmoother {
                transitions += transition.isEmpty ? [Float](repeating: 0, count: 225) : transition
                corrections += engine.pending.map(Float.init)
            }
        }

        diagnostics.sampleCount = steps.count
        diagnostics.rejectedPositions = engine.rejections[Channel.position.rawValue]
        diagnostics.rejectedVelocities = engine.rejections[Channel.speed.rawValue]
            + engine.rejections[Channel.course.rawValue] + engine.rejections[Channel.heading.rawValue] + engine.rejections[Channel.lateral.rawValue]
        diagnostics.yawCorrelation = yawCorrelation(points: points, steps: steps, imus: imus)

        // Lisseur RTS : e_k = C_k · (d_k+1 + e_k+1), où d est la correction injectée à l'échantillon suivant.
        var smoothedSnapshots: [Snapshot]?
        if wantsSmoother {
            var out = snapshots
            var error = [Double](repeating: 0, count: 15)
            for n in stride(from: steps.count - 2, through: 0, by: -1) {
                var input = [Double](repeating: 0, count: 15)
                for k in 0..<15 { input[k] = Double(corrections[(n + 1) * 15 + k]) + error[k] }
                let base = (n + 1) * 225
                var next = [Double](repeating: 0, count: 15)
                for r in 0..<15 {
                    var sum = 0.0
                    for c in 0..<15 { sum += Double(transitions[base + r * 15 + c]) * input[c] }
                    next[r] = sum
                }
                error = next
                out[n] = snapshots[n].corrected(by: error)
            }
            smoothedSnapshots = out
        }

        let times = steps.map { points[$0].time }
        let filtered = zip(snapshots, times).map { $0.sample(time: $1, frame: frame) }
        let smoothed = smoothedSnapshots.map { s in zip(s, times).map { $0.sample(time: $1, frame: frame) } }

        // Amplitude de la correction : écart horizontal brut ↔ trajectoire retenue.
        let reference = smoothedSnapshots ?? snapshots
        var sum = 0.0, count = 0
        for (snapshot, z) in zip(reference, measured) where z.x.isFinite {
            let d = SIMD2(snapshot.p.x, snapshot.p.y) - z
            sum += d.x * d.x + d.y * d.y
            count += 1
        }
        diagnostics.correctionRMS = count > 0 ? (sum / Double(count)).squareRoot() : .nan

        return FusionResult(filtered: filtered, smoothed: smoothed, pointIndices: steps, diagnostics: diagnostics)
    }

    /// Cohérence des axes : lacet du gyro Z contre variation du cap GNSS (en mouvement rapide).
    private static func yawCorrelation(points: [TrackPoint], steps: [Int], imus: [IMUReading]) -> Double {
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for n in 1..<steps.count {
            let a = points[steps[n - 1]], b = points[steps[n]]
            guard a.speed > 5, b.speed > 5, a.heading.isFinite, b.heading.isFinite else { continue }
            let dt = b.time - a.time
            guard dt > 0, dt < 0.5 else { continue }
            var dh = b.heading - a.heading
            while dh > 180 { dh -= 360 }
            while dh < -180 { dh += 360 }
            let courseRate = -dh / dt                    // antihoraire positif, comme le lacet d'un repère direct
            guard abs(courseRate) < 90 else { continue }
            let gyroRate = imus[n].w.z * 180 / .pi
            sab += courseRate * gyroRate
            saa += courseRate * courseRate
            sbb += gyroRate * gyroRate
        }
        guard saa > 1, sbb > 1 else { return .nan }
        return sab / (saa * sbb).squareRoot()
    }
}

private extension DenseMatrix {
    func storageScaled(_ factor: Double) -> DenseMatrix {
        var out = self
        for i in out.storage.indices { out.storage[i] *= factor }
        return out
    }
}
