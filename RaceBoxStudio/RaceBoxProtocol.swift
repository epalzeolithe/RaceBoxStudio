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
        static let recordingConfig: UInt8 = 0x25
        static let gnssConfig: UInt8 = 0x27
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

enum RecordingConfig {
    /// 25 Hz, attend un fix avant de démarrer, AUCUN filtre d'arrêt :
    /// le filtre No-Fix couperait l'enregistrement pendant un vol dos prolongé.
    static let start: [UInt8] = [1, 0, 0x01, 0] + [UInt8](repeating: 0, count: 8)
    static let stop = [UInt8](repeating: 0, count: 12)
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
