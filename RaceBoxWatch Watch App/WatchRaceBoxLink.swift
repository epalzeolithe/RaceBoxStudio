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
    /// Instance unique, partagée par l'interface et les intentions du bouton Action.
    static let shared = WatchRaceBoxLink()

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
    private(set) var memory: MemoryStatus?
    /// Le boîtier ne répond pas à la lecture de la mémoire (RaceBox Mini sans enregistrement autonome).
    private(set) var memoryUnavailable = false
    /// Pause signalée en direct par le boîtier (filtre d'arrêt ou de fix).
    private(set) var isPaused = false
    private(set) var live: LiveSnapshot?
    private(set) var power: PowerReading?
    /// Autonomie batterie estimée d'après la vitesse de décharge observée, en secondes.
    private(set) var batteryTimeRemaining: TimeInterval?

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
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isMicro = false
    /// Déconnexion demandée par l'utilisateur : pas de signal d'erreur.
    @ObservationIgnored private var userRequestedDisconnect = false
    /// Changements de niveau de batterie observés hors charge (date, %).
    @ObservationIgnored private var batteryHistory: [(date: Date, percent: Int)] = []

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
        userRequestedDisconnect = true
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
            // Efface une erreur antérieure (« Pas connecté », « Aucun RaceBox trouvé »…) devenue fausse.
            lastResult = nil
            isMicro = candidate.name.localizedCaseInsensitiveContains("Micro")
            WKInterfaceDevice.current().play(.success)
            startPolling()
        } catch {
            central.cancelPeripheralConnection(target)
            resetConnection()
            report(error.localizedDescription, isError: true)
        }
    }

    // MARK: Commandes

    func startRecording() async {
        await runCommand(payload: RecordingConfig.start, success: "Enregistrement démarré", haptic: .start)
    }

    func stopRecording() async {
        await runCommand(payload: RecordingConfig.stop, success: "Enregistrement arrêté", haptic: .stop)
    }

    /// Pour le bouton Action : se connecte si besoin, relit l'état réel du boîtier, puis
    /// l'arrête s'il enregistre, le démarre sinon.
    /// Renvoie `true` si la séance doit continuer, `false` si l'enregistrement est arrêté,
    /// `nil` si l'état n'a pas pu être déterminé (rien n'a été envoyé).
    func toggleRecordingWhenReady() async -> Bool? {
        guard await waitUntilReady() else {
            report("RaceBox introuvable : aucune action effectuée.", isError: true)
            return nil
        }
        guard let isRecording = await readRecordingState() else {
            report("État du RaceBox illisible : aucune action effectuée.", isError: true)
            return nil
        }
        if isRecording {
            await stopRecording()
            // Si l'arrêt a échoué, le boîtier enregistre toujours : on garde la séance.
            return memory?.isRecording == true
        }
        await startRecording()
        return true
    }

    /// Relit l'état du boîtier ; `nil` si la lecture échoue (on ne se fie pas à une valeur périmée).
    private func readRecordingState() async -> Bool? {
        isBusy = true
        defer { isBusy = false }
        do {
            try await refreshMemory()
        } catch {
            return nil
        }
        return memory?.isRecording
    }

    func stopRecordingWhenReady() async {
        guard await waitUntilReady() else {
            report("RaceBox introuvable : enregistrement non arrêté.", isError: true)
            return
        }
        await stopRecording()
    }

    /// Relance la recherche tant qu'il le faut, jusqu'à 25 s.
    private func waitUntilReady() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if isConnected, !isBusy { return true }
            if connection == .idle { ensureConnected() }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// `haptic` : vibration propre au démarrage / à l'arrêt, reconnaissable sans regarder l'écran.
    private func runCommand(payload: [UInt8], success: String, haptic: WKHapticType) async {
        guard isConnected else {
            report(WatchLinkError.notConnected.localizedDescription, isError: true)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: payload)
            isPaused = false
            report(success, isError: false, haptic: haptic)
            try? await refreshMemory()
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func report(_ text: String, isError: Bool, haptic: WKHapticType? = nil) {
        lastResult = CommandResult(text: text, isError: isError)
        WKInterfaceDevice.current().play(haptic ?? (isError ? .failure : .success))
    }

    // MARK: Suivi de l'état

    /// Relit la mémoire tout de suite, puis toutes les 15 s pendant un enregistrement (60 s sinon).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled, isConnected {
                if !isBusy {
                    isBusy = true
                    do {
                        try await refreshMemory()
                    } catch {
                        if memory == nil { memoryUnavailable = true }
                    }
                    isBusy = false
                }
                try? await Task.sleep(for: memory?.isRecording == true ? .seconds(15) : .seconds(60))
            }
        }
    }

    private func refreshMemory() async throws {
        inbox.removeAll()
        try await send(id: UBX.RaceBoxID.recordingStatus, payload: [])
        guard let reply = await nextFrame(timeout: .seconds(5), matching: {
            $0.cls == UBX.raceBoxClass && $0.id == UBX.RaceBoxID.recordingStatus
        }), let status = MemoryStatus(payload: reply.payload) else { throw WatchLinkError.noResponse }
        memory = status
        memoryUnavailable = false
        if !status.isRecording { isPaused = false }
    }

    /// Flux 25 Hz : on ne publie que ce qui change, pour ménager la batterie de la montre.
    private func handleLive(_ frame: UBXFrame) {
        guard let snapshot = LiveSnapshot(payload: frame.payload) else { return }
        if snapshot != live { live = snapshot }
        let reading = PowerReading(byte: snapshot.powerByte, isMicro: isMicro)
        guard reading != power else { return }
        power = reading
        trackBattery(reading)
    }

    /// Estime l'autonomie à partir de la pente de décharge entre deux changements de niveau.
    /// Le niveau initial est écarté : on ignore depuis combien de temps il était atteint.
    private func trackBattery(_ reading: PowerReading) {
        guard case .battery(let percent, let charging) = reading, !charging else {
            batteryHistory = []
            batteryTimeRemaining = nil
            return
        }
        batteryHistory.append((Date(), percent))
        let changes = batteryHistory.dropFirst()
        guard let first = changes.first, let last = changes.last, first.percent > last.percent else { return }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed >= 120 else { return }
        batteryTimeRemaining = Double(last.percent) * elapsed / Double(first.percent - last.percent)
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
        pollTask?.cancel()
        pollTask = nil
        memory = nil
        memoryUnavailable = false
        isPaused = false
        live = nil
        power = nil
        batteryTimeRemaining = nil
        batteryHistory = []
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
        if wasConnected {
            report(userRequestedDisconnect ? "Déconnecté" : "RaceBox déconnecté.", isError: !userRequestedDisconnect)
        }
        userRequestedDisconnect = false
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
        for frame in parser.feed(data) {
            switch (frame.cls, frame.id) {
            case (UBX.raceBoxClass, UBX.RaceBoxID.liveData):
                handleLive(frame)
            case (UBX.raceBoxClass, UBX.RaceBoxID.recordingStateChange):
                // 0 arrêté, 1 en cours, 2 en pause : on relit la mémoire pour rester à jour.
                isPaused = frame.payload.first == 2
                startPolling()
            default:
                receive(frame)
            }
        }
    }
}
