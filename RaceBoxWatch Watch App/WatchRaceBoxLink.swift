import CoreBluetooth
import Foundation
import Observation
import WatchKit

enum WatchLinkError: LocalizedError {
    case notConnected
    case missingCharacteristic
    case timeout
    case disconnected
    case noResponse
    case rejected

    var errorDescription: String? {
        switch self {
        case .notConnected: "Pas connecté au RaceBox."
        case .missingCharacteristic: "Service BLE du RaceBox introuvable."
        case .timeout: "Délai dépassé."
        case .disconnected: "RaceBox déconnecté."
        case .noResponse: "Pas de réponse du RaceBox."
        case .rejected: "Refusé : mémoire verrouillée, pleine, ou boîtier non Mini S/Micro."
        }
    }
}

struct CommandResult: Equatable {
    let text: String
    let isError: Bool
}

/// Connexion directe montre → RaceBox, pour démarrer et arrêter l'enregistrement autonome.
/// Le boîtier n'accepte qu'un seul client : ferme l'app RaceBox du téléphone avant de t'y connecter.
@Observable
final class WatchRaceBoxLink: NSObject {
    enum Connection: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
    }

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var connection: Connection = .idle
    private(set) var isBusy = false
    private(set) var lastResult: CommandResult?

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    private struct Candidate {
        let peripheral: CBPeripheral
        let name: String
        var rssi: Int
    }

    private struct Waiter {
        let id = UUID()
        let predicate: (UBXFrame) -> Bool
        let continuation: CheckedContinuation<UBXFrame?, Never>
    }

    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // écriture vers le boîtier
    private static let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notifications du boîtier
    private static let writeChunkSize = 20
    private static let savedDeviceKey = "lastRaceBoxIdentifier"

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var candidates: [UUID: Candidate] = [:]
    @ObservationIgnored private var characteristics: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var parser = UBXParser()
    @ObservationIgnored private var inbox: [UBXFrame] = []
    @ObservationIgnored private var waiter: Waiter?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingServiceDiscoveries = 0

    @ObservationIgnored private var connectContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var discoveryContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var notifyContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var writeContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Connexion

    /// Lance la recherche si on n'est ni connecté ni en cours de connexion.
    func ensureConnected() {
        guard connection == .idle, central.state == .poweredOn else { return }
        connection = .searching
        candidates.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        searchTask?.cancel()
        searchTask = Task {
            // 4 s pour repérer le boîtier mémorisé ou, à défaut, le plus proche.
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { connectToBestCandidate() }
        }
    }

    func disconnect() {
        searchTask?.cancel()
        if connection == .searching { central.stopScan() }
        if let peripheral { central.cancelPeripheralConnection(peripheral) } else { connection = .idle }
    }

    private func connectToBestCandidate() {
        guard connection == .searching else { return }
        central.stopScan()
        guard let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else {
            connection = .idle
            report("Aucun RaceBox trouvé.", isError: true)
            return
        }
        Task { await connect(to: best) }
    }

    private func connect(to candidate: Candidate) async {
        guard connection == .searching else { return }
        searchTask?.cancel()
        central.stopScan()
        connection = .connecting(candidate.name)
        let target = candidate.peripheral
        target.delegate = self
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                central.cancelPeripheralConnection(target)
                failPending(WatchLinkError.timeout)
            }
        }
        defer { timeout.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectContinuation = continuation
                central.connect(target)
            }
            peripheral = target
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                discoveryContinuation = continuation
                target.discoverServices([Self.uartService])
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard let tx = characteristics[Self.uartTX] else {
                    continuation.resume(throwing: WatchLinkError.missingCharacteristic)
                    return
                }
                notifyContinuation = continuation
                target.setNotifyValue(true, for: tx)
            }
            UserDefaults.standard.set(target.identifier.uuidString, forKey: Self.savedDeviceKey)
            connection = .connected(candidate.name)
            WKInterfaceDevice.current().play(.success)
        } catch {
            central.cancelPeripheralConnection(target)
            resetConnection()
            report(error.localizedDescription, isError: true)
        }
    }

    // MARK: Commandes

    func startRecording() async {
        await runCommand(payload: RecordingConfig.start, success: "Enregistrement démarré")
    }

    func stopRecording() async {
        await runCommand(payload: RecordingConfig.stop, success: "Enregistrement arrêté")
    }

    private func runCommand(payload: [UInt8], success: String) async {
        guard isConnected else {
            report(WatchLinkError.notConnected.localizedDescription, isError: true)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: payload)
            report(success, isError: false)
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func report(_ text: String, isError: Bool) {
        lastResult = CommandResult(text: text, isError: isError)
        WKInterfaceDevice.current().play(isError ? .failure : .success)
    }

    // MARK: Échanges UBX

    private func send(id: UInt8, payload: [UInt8]) async throws {
        guard let peripheral, let characteristic = characteristics[Self.uartRX] else { throw WatchLinkError.notConnected }
        let bytes = UBX.packet(cls: UBX.raceBoxClass, id: id, payload: payload)
        for start in stride(from: 0, to: bytes.count, by: Self.writeChunkSize) {
            let chunk = Data(bytes[start..<min(start + Self.writeChunkSize, bytes.count)])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeContinuation = continuation
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
        }
    }

    /// Envoie une commande 0xFF et attend l'ACK/NACK correspondant.
    private func expectAck(id: UInt8, payload: [UInt8]) async throws {
        inbox.removeAll()
        try await send(id: id, payload: payload)
        let reply = await nextFrame(timeout: .seconds(5)) {
            $0.cls == UBX.raceBoxClass
                && ($0.id == UBX.RaceBoxID.ack || $0.id == UBX.RaceBoxID.nack)
                && Array($0.payload.prefix(2)) == [UBX.raceBoxClass, id]
        }
        guard let reply else { throw WatchLinkError.noResponse }
        if reply.id == UBX.RaceBoxID.nack { throw WatchLinkError.rejected }
    }

    private func nextFrame(timeout: Duration, matching predicate: @escaping (UBXFrame) -> Bool) async -> UBXFrame? {
        if let frame = takeMatch(predicate) { return frame }
        return await withCheckedContinuation { continuation in
            let pending = Waiter(predicate: predicate, continuation: continuation)
            waiter = pending
            Task {
                try? await Task.sleep(for: timeout)
                if let current = waiter, current.id == pending.id {
                    waiter = nil
                    current.continuation.resume(returning: nil)
                }
            }
        }
    }

    private func takeMatch(_ predicate: (UBXFrame) -> Bool) -> UBXFrame? {
        guard let index = inbox.firstIndex(where: predicate) else { return nil }
        let frame = inbox[index]
        inbox.removeFirst(index + 1)
        return frame
    }

    private func receive(_ frame: UBXFrame) {
        inbox.append(frame)
        if let current = waiter, let match = takeMatch(current.predicate) {
            waiter = nil
            current.continuation.resume(returning: match)
        }
    }

    // MARK: Aides

    private func resetConnection() {
        peripheral = nil
        characteristics = [:]
        parser = UBXParser()
        inbox = []
        connection = .idle
    }

    /// Réveille toutes les opérations en attente avec une erreur (déconnexion, délai).
    private func failPending(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        discoveryContinuation?.resume(throwing: error)
        discoveryContinuation = nil
        notifyContinuation?.resume(throwing: error)
        notifyContinuation = nil
        writeContinuation?.resume(throwing: error)
        writeContinuation = nil
        if let waiter {
            waiter.continuation.resume(returning: nil)
            self.waiter = nil
        }
    }
}

// MARK: - CoreBluetooth

// CoreBluetooth appelle ces méthodes sur la file principale (voir `init`).
extension WatchRaceBoxLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            ensureConnected()
        } else if connection != .idle {
            failPending(WatchLinkError.disconnected)
            resetConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let announced = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard announced?.hasPrefix("RaceBox") == true || services.contains(Self.uartService) else { return }
        let candidate = Candidate(peripheral: peripheral, name: announced ?? "RaceBox", rssi: RSSI.intValue)
        candidates[peripheral.identifier] = candidate
        // Le boîtier utilisé la dernière fois : on s'y connecte sans attendre la fin de la recherche.
        if peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: Self.savedDeviceKey) {
            Task { await connect(to: candidate) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failPending(error ?? WatchLinkError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failPending(error ?? WatchLinkError.disconnected)
        let wasConnected = isConnected
        resetConnection()
        if wasConnected { report("RaceBox déconnecté.", isError: true) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            discoveryContinuation?.resume(throwing: error)
            discoveryContinuation = nil
            return
        }
        let services = peripheral.services ?? []
        pendingServiceDiscoveries = services.count
        if services.isEmpty {
            discoveryContinuation?.resume(throwing: WatchLinkError.missingCharacteristic)
            discoveryContinuation = nil
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            discoveryContinuation?.resume(throwing: error)
            discoveryContinuation = nil
            return
        }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries <= 0 {
            discoveryContinuation?.resume()
            discoveryContinuation = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            notifyContinuation?.resume(throwing: error)
        } else {
            notifyContinuation?.resume()
        }
        notifyContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            writeContinuation?.resume(throwing: error)
        } else {
            writeContinuation?.resume()
        }
        writeContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.uartTX, error == nil, let data = characteristic.value else { return }
        // On ignore le flux de données temps réel (0xFF 0x01, 25 Hz).
        for frame in parser.feed(data) where !(frame.cls == UBX.raceBoxClass && frame.id == UBX.RaceBoxID.liveData) {
            receive(frame)
        }
    }
}
