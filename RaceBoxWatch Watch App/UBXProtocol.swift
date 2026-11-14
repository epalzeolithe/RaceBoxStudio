import Foundation

// Sous-ensemble du protocole BLE RaceBox (révision 9) nécessaire à la montre :
// trames UBX, réassemblage des notifications et commandes d'enregistrement autonome.
// Reflète MyApp/RaceBoxProtocol.swift : en cas de correction d'un côté, reporter de l'autre.

extension Sequence where Element == UInt8 {
    /// "B5 62 FF 25 …"
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
        static let recordingStatus: UInt8 = 0x22
        static let recordingConfig: UInt8 = 0x25
        static let recordingStateChange: UInt8 = 0x26
    }

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

// MARK: - Enregistrement autonome (0xFF 0x25, Mini S / Micro)

enum RecordingConfig {
    /// 25 Hz, attend un fix avant de démarrer, AUCUN filtre d'arrêt :
    /// le filtre No-Fix couperait l'enregistrement pendant un vol dos prolongé.
    static let start: [UInt8] = [1, 0, 0x01, 0] + [UInt8](repeating: 0, count: 8)
    static let stop = [UInt8](repeating: 0, count: 12)
}

// MARK: - État de la mémoire (0xFF 0x22)

struct MemoryStatus: Equatable {
    let isRecording: Bool
    let isLocked: Bool
    let storedMessages: Int
    /// Capacité, en messages de données.
    let memorySize: Int

    init?(payload p: [UInt8]) {
        guard p.count >= 12 else { return nil }
        func u32(_ o: Int) -> Int { Int(p[o]) | Int(p[o + 1]) << 8 | Int(p[o + 2]) << 16 | Int(p[o + 3]) << 24 }
        isRecording = p[0] != 0
        isLocked = p[2] & 0x01 != 0 && p[2] & 0x02 == 0
        storedMessages = u32(4)
        memorySize = u32(8)
    }

    var freeRatio: Double {
        guard memorySize > 0 else { return 0 }
        return Double(max(memorySize - storedMessages, 0)) / Double(memorySize)
    }

    /// Durée restante à 25 Hz, la fréquence utilisée par la montre.
    var remainingTime: TimeInterval { Double(max(memorySize - storedMessages, 0)) / 25 }
}

// MARK: - Extrait du message de données (0xFF 0x01)

/// Seuls les champs utiles à l'écran de la montre, pour ne pas tout décoder 25 fois par seconde.
struct LiveSnapshot: Equatable {
    let fixStatus: UInt8
    let satellites: Int
    /// Fix 3D avec le bit « fix valide » levé (recommandation de la doc).
    let hasGoodFix: Bool
    /// Batterie (Mini / Mini S) ou tension d'entrée (Micro).
    let powerByte: UInt8

    init?(payload p: [UInt8]) {
        guard p.count == 80 else { return nil }
        fixStatus = p[20]
        hasGoodFix = p[20] == 3 && p[21] & 0x01 != 0
        satellites = Int(p[23])
        powerByte = p[67]
    }
}

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
