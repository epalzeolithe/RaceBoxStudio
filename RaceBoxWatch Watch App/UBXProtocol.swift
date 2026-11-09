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
        static let recordingConfig: UInt8 = 0x25
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
