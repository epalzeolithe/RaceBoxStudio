import CoreBluetooth
import Foundation
import Observation

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

enum LinkError: LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case missingCharacteristic(String)
    case timeout
    case disconnected
    case noResponse
    case rejected(String)
    case firmwareTooOld(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Le Bluetooth n'est pas disponible ou n'est pas autorisé."
        case .notConnected: "Aucun boîtier connecté."
        case .missingCharacteristic(let uuid): "Caractéristique BLE introuvable : \(uuid)."
        case .timeout: "Délai dépassé."
        case .disconnected: "Le boîtier s'est déconnecté."
        case .noResponse: "Pas de réponse du boîtier."
        case .rejected(let detail): "Le boîtier a refusé la commande (NACK). \(detail)"
        case .firmwareTooOld(let version):
            "La configuration GNSS demande le firmware 3.3 ou plus (boîtier : \(version)). Mets-le à jour avec l'app RaceBox."
        }
    }
}

/// Connexion BLE à un RaceBox Mini / Mini S / Micro, et commandes de configuration.
/// Ferme l'app RaceBox du téléphone avant de te connecter : le boîtier n'accepte qu'un seul client.
@Observable
final class RaceBoxLink: NSObject {
    struct Device: Identifiable, Hashable {
        let id: UUID
        var name: String
        var rssi: Int
        /// Nom "RaceBox…" ou service UART Nordic annoncé.
        var isRaceBox: Bool
    }

    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected
    }

    // MARK: État observable

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var devices: [Device] = []
    private(set) var state: State = .disconnected
    private(set) var deviceName: String?
    private(set) var modelNumber: String?
    private(set) var firmware: String?
    private(set) var gnssConfig: GNSSConfig?
    private(set) var chipInfo: ChipInfo?
    private(set) var isBusy = false
    private(set) var log: [LogEntry] = []
    var errorMessage: String?
    /// Affiche tous les appareils BLE alentour, pas seulement les RaceBox (aide au diagnostic).
    var showAllDevices = false

    var visibleDevices: [Device] {
        (showAllDevices ? devices : devices.filter(\.isRaceBox)).sorted { $0.rssi > $1.rssi }
    }

    // MARK: Interne

    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // écriture vers le boîtier
    private static let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notifications du boîtier
    private static let modelUUID = CBUUID(string: "2A24")
    private static let firmwareUUID = CBUUID(string: "2A26")
    private static let writeChunkSize = 20 // MTU faible : la doc autorise le découpage

    private struct Waiter {
        let id = UUID()
        let predicate: (UBXFrame) -> Bool
        let continuation: CheckedContinuation<UBXFrame?, Never>
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var knownNames: [UUID: String] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var parser = UBXParser()
    @ObservationIgnored private var inbox: [UBXFrame] = []
    @ObservationIgnored private var waiter: Waiter?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var pendingServiceDiscoveries = 0

    @ObservationIgnored private var connectContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var discoveryContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var notifyContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var writeContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        wantsScan = true // recherche automatique dès que le Bluetooth est prêt
    }

    // MARK: Recherche et connexion

    func startScanning() {
        guard case .disconnected = state else { return }
        guard central.state == .poweredOn else {
            wantsScan = true
            return
        }
        wantsScan = false
        devices.removeAll()
        peripherals.removeAll()
        // Doublons autorisés : le nom peut n'arriver que dans un second paquet (réponse de scan).
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { stopScanning() }
        }
    }

    func stopScanning() {
        wantsScan = false
        scanTask?.cancel()
        scanTask = nil
        if isScanning { central.stopScan() }
        isScanning = false
    }

    func connect(_ device: Device) async {
        guard case .disconnected = state, let target = peripherals[device.id] else { return }
        stopScanning()
        state = .connecting(device.name)
        target.delegate = self
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                central.cancelPeripheralConnection(target)
                failPending(LinkError.timeout)
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
                target.discoverServices(nil)
            }
            modelNumber = try? await readString(Self.modelUUID)
            firmware = try? await readString(Self.firmwareUUID)
            try await enableNotifications()
            deviceName = device.name
            state = .connected
            addLog("Connecté à \(device.name) — modèle \(modelNumber ?? "?"), firmware \(firmware ?? "?")")
        } catch {
            central.cancelPeripheralConnection(target)
            resetConnection()
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: Commandes

    func readGNSSConfig() async {
        await perform {
            try requireFirmware()
            guard let reply = try await request(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.gnssConfig),
                  let config = GNSSConfig(payload: reply.payload) else { throw LinkError.noResponse }
            gnssConfig = config
            addLog("Configuration GNSS : modèle \(config.dynamicModel) – \(DynamicModel.name(for: config.dynamicModel)), "
                   + "vitesse \(config.speed3D ? "3D" : "sol (2D)"), précision min. \(config.minAccuracy) m")
        }
    }

    func applyGNSSConfig(_ config: GNSSConfig) async {
        await perform {
            try requireFirmware()
            try await expectAck(id: UBX.RaceBoxID.gnssConfig, payload: config.payload)
            addLog("ACK reçu. Relecture…")
            guard let reply = try await request(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.gnssConfig),
                  let readBack = GNSSConfig(payload: reply.payload) else { throw LinkError.noResponse }
            gnssConfig = readBack
            if readBack == config {
                addLog("Réglage appliqué ; d'après la doc, il est conservé après redémarrage.")
            } else {
                addLog("⚠️ La relecture ne correspond pas à ce qui a été envoyé.")
            }
        }
    }

    func queryChip() async {
        await perform {
            guard let reply = try await request(cls: UBX.monClass, id: UBX.monVersionID, timeout: .seconds(6)),
                  let info = ChipInfo(payload: reply.payload) else { throw LinkError.noResponse }
            chipInfo = info
            addLog("Puce GNSS : \(info.software) / \(info.hardware) / \(info.extensions.joined(separator: ", "))")
        }
    }

    func startRecording() async {
        await perform {
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: RecordingConfig.start,
                                nackHint: "Mémoire verrouillée, pleine, ou boîtier non Mini S/Micro.")
            addLog("Enregistrement autonome démarré (25 Hz). Tu peux te déconnecter.")
        }
    }

    func stopRecording() async {
        await perform {
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: RecordingConfig.stop)
            addLog("Enregistrement arrêté.")
        }
    }

    // MARK: Aides

    /// Exécute une opération en série (une seule à la fois) et remonte l'erreur à l'interface.
    private func perform(_ body: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await body()
        } catch {
            addLog("Erreur : \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func requireFirmware() throws {
        let version = firmware ?? ""
        let parsed = parseFirmwareVersion(version)
        if (parsed.major, parsed.minor) < (3, 3) { throw LinkError.firmwareTooOld(version.isEmpty ? "inconnu" : version) }
    }

    private func addLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func resetConnection() {
        peripheral = nil
        characteristics = [:]
        parser = UBXParser()
        inbox = []
        state = .disconnected
        deviceName = nil
        modelNumber = nil
        firmware = nil
        gnssConfig = nil
        chipInfo = nil
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
        for continuation in readContinuations.values { continuation.resume(throwing: error) }
        readContinuations = [:]
        if let waiter {
            waiter.continuation.resume(returning: nil)
            self.waiter = nil
        }
    }

    private func readString(_ uuid: CBUUID) async throws -> String {
        guard let peripheral, let characteristic = characteristics[uuid] else {
            throw LinkError.missingCharacteristic(uuid.uuidString)
        }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            readContinuations[uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
        // Le boîtier peut terminer ces chaînes par un octet nul.
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    private func enableNotifications() async throws {
        guard let peripheral, let characteristic = characteristics[Self.uartTX] else {
            throw LinkError.missingCharacteristic(Self.uartTX.uuidString)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notifyContinuation = continuation
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    // MARK: Échanges UBX

    private func send(cls: UInt8, id: UInt8, payload: [UInt8]) async throws {
        guard let peripheral, let characteristic = characteristics[Self.uartRX] else { throw LinkError.notConnected }
        let bytes = UBX.packet(cls: cls, id: id, payload: payload)
        addLog("→ \(bytes.hexString)")
        for start in stride(from: 0, to: bytes.count, by: Self.writeChunkSize) {
            let chunk = Data(bytes[start..<min(start + Self.writeChunkSize, bytes.count)])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeContinuation = continuation
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
        }
    }

    /// Envoie une requête et attend la réponse de même classe et même id.
    private func request(cls: UInt8, id: UInt8, payload: [UInt8] = [],
                         timeout: Duration = .seconds(5)) async throws -> UBXFrame? {
        inbox.removeAll()
        try await send(cls: cls, id: id, payload: payload)
        return await nextFrame(timeout: timeout) { $0.cls == cls && $0.id == id }
    }

    /// Envoie une commande 0xFF et attend l'ACK/NACK correspondant.
    private func expectAck(id: UInt8, payload: [UInt8], nackHint: String = "") async throws {
        inbox.removeAll()
        try await send(cls: UBX.raceBoxClass, id: id, payload: payload)
        let reply = await nextFrame(timeout: .seconds(5)) {
            $0.cls == UBX.raceBoxClass
                && ($0.id == UBX.RaceBoxID.ack || $0.id == UBX.RaceBoxID.nack)
                && Array($0.payload.prefix(2)) == [UBX.raceBoxClass, id]
        }
        guard let reply else { throw LinkError.noResponse }
        if reply.id == UBX.RaceBoxID.nack { throw LinkError.rejected(nackHint) }
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
}

// MARK: - CoreBluetooth

// CoreBluetooth appelle ces méthodes sur la file principale (voir `init`).
extension RaceBoxLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn, wantsScan { startScanning() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        if let announced = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) {
            knownNames[id] = announced
        }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let known = knownNames[id]
        let device = Device(id: id,
                            name: known ?? "Appareil sans nom (\(id.uuidString.prefix(4)))",
                            rssi: RSSI.intValue,
                            isRaceBox: known?.hasPrefix("RaceBox") == true || services.contains(Self.uartService))
        peripherals[id] = peripheral
        if let index = devices.firstIndex(where: { $0.id == id }) {
            // Les doublons arrivent en rafale : on ne met à jour que si quelque chose change vraiment.
            let old = devices[index]
            if old.name != device.name || old.isRaceBox != device.isRaceBox || abs(old.rssi - device.rssi) >= 5 {
                devices[index] = device
            }
        } else {
            devices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failPending(error ?? LinkError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failPending(error ?? LinkError.disconnected)
        if self.peripheral == peripheral || state != .connected {
            let wasConnected = state == .connected
            resetConnection()
            if wasConnected { addLog("Déconnecté.") }
        }
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
            discoveryContinuation?.resume()
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
        if characteristic.uuid == Self.uartTX {
            guard error == nil, let data = characteristic.value else { return }
            // On ignore le flux de données temps réel (0xFF 0x01, 25 Hz).
            for frame in parser.feed(data) where !(frame.cls == UBX.raceBoxClass && frame.id == UBX.RaceBoxID.liveData) {
                receive(frame)
            }
        } else if let continuation = readContinuations.removeValue(forKey: characteristic.uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
        }
    }
}
