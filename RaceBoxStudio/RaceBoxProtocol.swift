import Foundation

// Protocole BLE RaceBox (révision 9) : trames UBX, messages de configuration.
// Port Swift de racebox_config.py.

extension Sequence where Element == UInt8 {
    /// "B5 62 FF 27 …"
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

struct UBXFrame: Equatable {
    let cls: UInt8
    let id: UInt8
    let payload: [UInt8]
}

enum UBX {
    static let raceBoxClass: UInt8 = 0xFF
    static let maxPayloadLength = 1024

    enum RaceBoxID {
        static let liveData: UInt8 = 0x01
        static let ack: UInt8 = 0x02
        static let nack: UInt8 = 0x03
        /// Donnée enregistrée en mémoire : même charge utile de 80 octets que `liveData`.
        static let recordedData: UInt8 = 0x21
        static let recordingStatus: UInt8 = 0x22
        /// Démarre le téléchargement (charge vide) ou l'annule (un octet).
        static let download: UInt8 = 0x23
        /// Effacement de la mémoire (charge vide) ou annulation (un octet). Progression : un octet 0…100.
        static let erase: UInt8 = 0x24
        static let recordingConfig: UInt8 = 0x25
        /// Changement d'état de l'enregistrement autonome (démarrage, arrêt, pause).
        static let recordingStateChange: UInt8 = 0x26
        static let gnssConfig: UInt8 = 0x27
        /// Déverrouillage de la mémoire avec le code de sécurité (UInt32).
        static let unlock: UInt8 = 0x30
    }

    /// UBX-MON-VER : lecture seule, transmise telle quelle à la puce GNSS.
    static let monClass: UInt8 = 0x0A
    static let monVersionID: UInt8 = 0x04

    /// Somme de contrôle de Fletcher-8 calculée sur classe, id, longueur et charge utile.
    static func checksum<S: Sequence>(_ bytes: S) -> [UInt8] where S.Element == UInt8 {
        var a: UInt8 = 0
        var b: UInt8 = 0
        for x in bytes {
            a = a &+ x
            b = b &+ a
        }
        return [a, b]
    }

    static func packet(cls: UInt8, id: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let length = UInt16(payload.count)
        let body = [cls, id, UInt8(length & 0xFF), UInt8(length >> 8)] + payload
        return [0xB5, 0x62] + body + checksum(body)
    }
}

/// Réassemble les trames UBX découpées sur plusieurs notifications BLE.
struct UBXParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: Data) -> [UBXFrame] {
        buffer.append(contentsOf: data)
        var frames: [UBXFrame] = []
        while true {
            guard let start = syncIndex() else {
                buffer = Array(buffer.suffix(1))
                return frames
            }
            buffer.removeFirst(start)
            if buffer.count < 6 { return frames }
            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            if length > UBX.maxPayloadLength {
                buffer.removeFirst(2)
                continue
            }
            let total = 8 + length
            if buffer.count < total { return frames }
            let raw = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if UBX.checksum(raw[2..<(total - 2)]) == Array(raw[(total - 2)...]) {
                frames.append(UBXFrame(cls: raw[2], id: raw[3], payload: Array(raw[6..<(total - 2)])))
            }
        }
    }

    private func syncIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        return (0..<(buffer.count - 1)).first { buffer[$0] == 0xB5 && buffer[$0 + 1] == 0x62 }
    }
}

// MARK: - Configuration GNSS (0xFF 0x27, firmware 3.3 ou plus)

struct DynamicModel: Identifiable, Hashable {
    let id: UInt8
    let name: String

    static let all: [DynamicModel] = [
        DynamicModel(id: 0, name: "Portable"),
        DynamicModel(id: 2, name: "Stationnaire"),
        DynamicModel(id: 3, name: "Piéton"),
        DynamicModel(id: 4, name: "Automobile (défaut RaceBox)"),
        DynamicModel(id: 5, name: "Mer"),
        DynamicModel(id: 6, name: "Aérien <1g"),
        DynamicModel(id: 7, name: "Aérien <2g"),
        DynamicModel(id: 8, name: "Aérien <4g"),
    ]

    static func name(for id: UInt8) -> String {
        all.first { $0.id == id }?.name ?? "inconnu"
    }
}

struct GNSSConfig: Equatable {
    var dynamicModel: UInt8
    var speed3D: Bool
    /// Précision horizontale minimale pour accepter un fix, en mètres.
    var minAccuracy: UInt8

    /// Réglage voltige : aérien <4g, vitesse 3D, précision 10 m.
    static let aerobatics = GNSSConfig(dynamicModel: 8, speed3D: true, minAccuracy: 10)

    init(dynamicModel: UInt8, speed3D: Bool, minAccuracy: UInt8) {
        self.dynamicModel = dynamicModel
        self.speed3D = speed3D
        self.minAccuracy = minAccuracy
    }

    init?(payload: [UInt8]) {
        guard payload.count == 3 else { return nil }
        self.init(dynamicModel: payload[0], speed3D: payload[1] != 0, minAccuracy: payload[2])
    }

    var payload: [UInt8] { [dynamicModel, speed3D ? 1 : 0, minAccuracy] }
}

// MARK: - Enregistrement autonome (0xFF 0x25, Mini S / Micro)

struct RecordingSettings: Equatable {
    enum DataRate: UInt8, CaseIterable, Identifiable {
        case hz25 = 0, hz10 = 1, hz5 = 2, hz1 = 3, hz20 = 4

        var id: UInt8 { rawValue }
        var hertz: Int {
            switch self {
            case .hz25: 25
            case .hz20: 20
            case .hz10: 10
            case .hz5: 5
            case .hz1: 1
            }
        }
        /// 20 Hz demande le firmware 3.3 ou plus.
        var needsFirmware33: Bool { self == .hz20 }

        static let ordered: [DataRate] = [.hz25, .hz20, .hz10, .hz5, .hz1]
    }

    var dataRate: DataRate = .hz25
    var waitForFix = true
    var stationaryFilter = false
    var noFixFilter = false
    var autoShutdown = false
    var waitForDataBeforeShutdown = false
    /// Seuil du filtre d'arrêt, en mm/s (1389 ≈ 5 km/h).
    var stationarySpeed: UInt16 = 1389
    /// Durées de détection, en secondes.
    var stationaryInterval: UInt16 = 30
    var noFixInterval: UInt16 = 30
    var shutdownInterval: UInt16 = 300

    /// 25 Hz, attend un fix avant de démarrer, AUCUN filtre d'arrêt :
    /// le filtre No-Fix couperait l'enregistrement pendant un vol dos prolongé.
    static let aerobatics = RecordingSettings()

    /// Réglage conseillé par RaceBox : tous les filtres, 5 km/h pendant 30 s, arrêt auto après 5 min.
    static let recommended = RecordingSettings(stationaryFilter: true, noFixFilter: true,
                                               autoShutdown: true, waitForDataBeforeShutdown: true)

    static let disablePayload = [UInt8](repeating: 0, count: 12)

    init(dataRate: DataRate = .hz25, waitForFix: Bool = true, stationaryFilter: Bool = false,
         noFixFilter: Bool = false, autoShutdown: Bool = false, waitForDataBeforeShutdown: Bool = false) {
        self.dataRate = dataRate
        self.waitForFix = waitForFix
        self.stationaryFilter = stationaryFilter
        self.noFixFilter = noFixFilter
        self.autoShutdown = autoShutdown
        self.waitForDataBeforeShutdown = waitForDataBeforeShutdown
    }

    /// Décode le débit, les drapeaux et les quatre UInt16 placés à partir de l'octet 4.
    private init?(rate: UInt8, flags: UInt8, tail: ArraySlice<UInt8>) {
        guard tail.count >= 8, let rate = DataRate(rawValue: rate) else { return nil }
        let values = Array(tail)
        func u16(_ offset: Int) -> UInt16 { UInt16(values[offset]) | UInt16(values[offset + 1]) << 8 }
        dataRate = rate
        waitForFix = flags & 0x01 != 0
        stationaryFilter = flags & 0x02 != 0
        noFixFilter = flags & 0x04 != 0
        autoShutdown = flags & 0x08 != 0
        waitForDataBeforeShutdown = flags & 0x10 != 0
        stationarySpeed = u16(0)
        stationaryInterval = u16(2)
        noFixInterval = u16(4)
        shutdownInterval = u16(6)
    }

    /// Réponse à la lecture 0xFF 0x25 : [activé, débit, drapeaux, réservé, 4 × UInt16].
    static func fromConfigPayload(_ payload: [UInt8]) -> (enabled: Bool, settings: RecordingSettings)? {
        guard payload.count == 12,
              let settings = RecordingSettings(rate: payload[1], flags: payload[2], tail: payload[4...]) else { return nil }
        return (payload[0] != 0, settings)
    }

    var flags: UInt8 {
        (waitForFix ? 0x01 : 0) | (stationaryFilter ? 0x02 : 0) | (noFixFilter ? 0x04 : 0)
            | (autoShutdown ? 0x08 : 0) | (waitForDataBeforeShutdown ? 0x10 : 0)
    }

    var enablePayload: [UInt8] {
        var out: [UInt8] = [1, dataRate.rawValue, flags, 0]
        for value in [stationarySpeed, stationaryInterval, noFixInterval, shutdownInterval] {
            out += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        return out
    }

    var summary: String {
        var parts = ["\(dataRate.hertz) Hz"]
        if waitForFix { parts.append("attente fix") }
        if stationaryFilter {
            parts.append("arrêt < \(Int((Double(stationarySpeed) * 0.0036).rounded())) km/h (\(stationaryInterval) s)")
        }
        if noFixFilter { parts.append("no-fix \(noFixInterval) s") }
        if autoShutdown { parts.append("extinction \(shutdownInterval) s") }
        return parts.joined(separator: " · ")
    }
}

/// Message 0xFF 0x26 : nouvel état de l'enregistrement autonome.
enum RecordingStateChange: UInt8 {
    case stopped = 0, running = 1, paused = 2

    init?(payload: [UInt8]) {
        guard let first = payload.first else { return nil }
        self.init(rawValue: first)
    }

    var label: String {
        switch self {
        case .stopped: "arrêté"
        case .running: "en cours"
        case .paused: "en pause (filtre)"
        }
    }
}

// MARK: - Alimentation (octet 67 du message de données)

enum PowerReading: Equatable {
    /// Mini / Mini S : bit de poids fort = en charge, 7 bits restants = niveau en %.
    case battery(percent: Int, charging: Bool)
    /// Micro : pas de batterie, tension d'entrée (octet / 10).
    case inputVoltage(Double)

    init(byte: UInt8, isMicro: Bool) {
        if isMicro {
            self = .inputVoltage(Double(byte) / 10)
        } else {
            self = .battery(percent: Int(byte & 0x7F), charging: byte & 0x80 != 0)
        }
    }
}

// MARK: - Réponse UBX-MON-VER

struct ChipInfo: Equatable {
    let software: String
    let hardware: String
    /// Contient normalement MOD=… (nom exact du module).
    let extensions: [String]

    init?(payload: [UInt8]) {
        guard payload.count >= 40 else { return nil }
        func string(_ range: Range<Int>) -> String {
            String(decoding: payload[range].prefix { $0 != 0 }, as: UTF8.self)
        }
        software = string(0..<30)
        hardware = string(30..<40)
        var found: [String] = []
        var start = 40
        while start < payload.count {
            let text = string(start..<min(start + 30, payload.count))
            if !text.isEmpty { found.append(text) }
            start += 30
        }
        extensions = found
    }
}

/// "3.3" -> (3, 3). Renvoie (0, 0) si la chaîne est illisible.
/// Tolère les caractères parasites (octet nul, espaces) que le boîtier peut ajouter à la fin.
func parseFirmwareVersion(_ string: String) -> (major: Int, minor: Int) {
    let parts = string.split(separator: ".")
    func leadingNumber(_ part: Substring) -> Int? {
        Int(part.drop { !($0.isASCII && $0.isNumber) }.prefix { $0.isASCII && $0.isNumber })
    }
    guard parts.count >= 2, let major = leadingNumber(parts[0]), let minor = leadingNumber(parts[1]) else {
        return (0, 0)
    }
    return (major, minor)
}
