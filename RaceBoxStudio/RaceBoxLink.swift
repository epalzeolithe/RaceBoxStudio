import CoreBluetooth
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

enum LinkError: LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case missingCharacteristic(String)
    /// Délai de connexion dépassé ; indique l'étape où le boîtier ne répondait plus.
    case timeout(String)
    case disconnected
    case noResponse
    case rejected(String)
    case firmwareTooOld(String)
    case memoryLocked
    case downloadStalled
    case unlockFailed

    var errorDescription: String? {
        switch self {
        case .memoryLocked: "La mémoire du boîtier est verrouillée par un code de sécurité."
        case .downloadStalled: "Le téléchargement s'est arrêté : plus de données reçues."
        case .unlockFailed: "Code refusé. Attention : plusieurs essais ratés peuvent bloquer le boîtier."
        case .bluetoothUnavailable: "Le Bluetooth n'est pas disponible ou n'est pas autorisé."
        case .notConnected: "Aucun boîtier connecté."
        case .missingCharacteristic(let uuid): "Caractéristique BLE introuvable : \(uuid)."
        case .timeout(let step):
            "Délai dépassé pendant : \(step). Si la LED est bleue fixe, le boîtier est peut-être déjà connecté "
                + "à un autre appareil (app RaceBox, montre…) : ferme-le, ou éteins/rallume le RaceBox."
        case .disconnected: "Le boîtier s'est déconnecté."
        case .noResponse: "Pas de réponse du boîtier."
        case .rejected(let detail): "Le boîtier a refusé la commande (NACK). \(detail)"
        case .firmwareTooOld(let version):
            "Cette fonction demande le firmware 3.3 ou plus (boîtier : \(version)). Mets-le à jour avec l'app RaceBox."
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
        /// Toujours connecté au système (app relancée sans déconnexion) : il n'émet plus d'annonce.
        var alreadyConnected = false
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
    private(set) var serialNumber: String?
    private(set) var hardwareRevision: String?
    /// Dernier message de données temps réel (rafraîchi 4 fois par seconde au plus).
    private(set) var liveSample: RaceBoxSample?
    /// Fréquence mesurée du flux temps réel, en Hz.
    private(set) var liveRate: Double = 0
    private(set) var power: PowerReading?
    /// Autonomie batterie estimée d'après la vitesse de décharge observée, en secondes.
    private(set) var batteryTimeRemaining: TimeInterval?
    private(set) var recordingSettings: RecordingSettings?
    /// Dernier changement d'état reçu en direct (0xFF 0x26) : permet de distinguer la pause d'un filtre.
    private(set) var recordingState: RecordingStateChange?
    /// Progression de l'effacement (0…100), nil hors effacement.
    private(set) var eraseProgress: Int?
    private(set) var gnssConfig: GNSSConfig?
    private(set) var chipInfo: ChipInfo?
    private(set) var isBusy = false
    private(set) var recordingStatus: RecordingStatus?
    private(set) var isDownloading = false
    /// Nombre d'échantillons reçus pendant le téléchargement (mis à jour par paliers).
    private(set) var downloadedCount = 0
    /// Nombre de messages annoncé par le boîtier au début du téléchargement.
    private(set) var downloadExpected = 0
    private(set) var sessions: [RecordingSession] = []
    private(set) var log: [LogEntry] = []
    var errorMessage: String?
    /// Affiche tous les appareils BLE alentour, pas seulement les RaceBox (aide au diagnostic).
    var showAllDevices = true

    // MARK: Réglages (conservés entre deux lancements)

    /// Se connecte tout seul au premier RaceBox trouvé pendant une recherche.
    var autoConnect = UserDefaults.standard.bool(forKey: "autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }
    /// Libère le boîtier quand on quitte l'app (macOS) ou qu'elle passe en arrière-plan (iOS).
    var disconnectOnQuit = UserDefaults.standard.object(forKey: "disconnectOnQuit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(disconnectOnQuit, forKey: "disconnectOnQuit") }
    }

    var isMicro: Bool { modelNumber?.localizedCaseInsensitiveContains("Micro") == true }
    /// Seuls les Mini S et Micro savent enregistrer en autonome.
    var supportsRecording: Bool {
        guard let modelNumber else { return false }
        return isMicro || modelNumber.localizedCaseInsensitiveContains("Mini S")
    }

    var visibleDevices: [Device] {
        (showAllDevices ? devices : devices.filter(\.isRaceBox)).sorted {
            $0.alreadyConnected != $1.alreadyConnected ? $0.alreadyConnected : $0.rssi > $1.rssi
        }
    }

    // MARK: Interne

    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // écriture vers le boîtier
    private static let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notifications du boîtier
    private static let modelUUID = CBUUID(string: "2A24")
    private static let firmwareUUID = CBUUID(string: "2A26")
    private static let serialUUID = CBUUID(string: "2A25")
    private static let hardwareUUID = CBUUID(string: "2A27")
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
    @ObservationIgnored private var downloadBuffer: [RaceBoxSample] = []
    @ObservationIgnored private var lastDownloadActivity = Date()
    /// Indices de `downloadBuffer` où un message 0xFF 0x26 (démarrage / arrêt) a été reçu.
    @ObservationIgnored private var downloadBoundaries: Set<Int> = []
    @ObservationIgnored private var lastLivePublish = Date.distantPast
    @ObservationIgnored private var liveWindowStart = Date()
    @ObservationIgnored private var liveWindowCount = 0
    /// Changements de niveau de batterie observés hors charge (date, %).
    @ObservationIgnored private var batteryHistory: [(date: Date, percent: Int)] = []
    @ObservationIgnored private var warnedEmptyBattery = false
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    @ObservationIgnored private var connectContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var discoveryContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var notifyContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var writeContinuation: CheckedContinuation<Void, Error>?
    private struct PendingRead {
        let id = UUID()
        let continuation: CheckedContinuation<Data, Error>
    }

    @ObservationIgnored private var readContinuations: [CBUUID: PendingRead] = [:]
    /// Étape de connexion en cours, pour expliquer un délai dépassé.
    @ObservationIgnored private var connectStep = ""

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        wantsScan = true // recherche automatique dès que le Bluetooth est prêt
        #if os(macOS)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.disconnectOnQuit else { return }
                self.disconnect()
            }
        }
        #endif
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
        addSystemConnectedDevices()
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { stopScanning() }
        }
    }

    /// Un RaceBox resté connecté au système (par exemple après un arrêt forcé de l'app) n'apparaît pas
    /// dans la recherche : on le récupère directement auprès de CoreBluetooth.
    private func addSystemConnectedDevices() {
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.uartService]) {
            let id = peripheral.identifier
            if let name = peripheral.name { knownNames[id] = name }
            let name = knownNames[id] ?? "RaceBox (\(id.uuidString.prefix(4)))"
            peripherals[id] = peripheral
            let device = Device(id: id, name: name, rssi: 0, isRaceBox: true, alreadyConnected: true)
            if let index = devices.firstIndex(where: { $0.id == id }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
            addLog("\(name) est encore connecté au système : il peut être repris.")
            if autoConnect, case .disconnected = state {
                addLog("Connexion automatique à \(name).")
                Task { await connect(device) }
            }
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
        var timedOut = false
        // Le délai ne couvre que les étapes Bluetooth ; les requêtes UBX ont leur propre délai de 5 s.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                timedOut = true
                central.cancelPeripheralConnection(target)
                failPending(LinkError.timeout(connectStep))
            }
        }
        defer { timeout.cancel() }
        func step(_ name: String) throws {
            if timedOut { throw LinkError.timeout(connectStep) }
            connectStep = name
            addLog("Connexion : \(name)…")
        }
        do {
            try step("liaison Bluetooth")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectContinuation = continuation
                central.connect(target)
            }
            peripheral = target
            try step("découverte des services")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                discoveryContinuation = continuation
                target.discoverServices(nil)
            }
            try step("lecture des informations du boîtier")
            modelNumber = try? await readString(Self.modelUUID)
            firmware = try? await readString(Self.firmwareUUID)
            serialNumber = try? await readString(Self.serialUUID)
            hardwareRevision = try? await readString(Self.hardwareUUID)
            try step("abonnement aux notifications")
            try await enableNotifications()
            try step("fin de connexion")
            timeout.cancel()
            deviceName = device.name
            // État de la mémoire dès la connexion, pour le résumé de la barre latérale.
            if supportsRecording {
                try? await refreshRecordingStatus()
                try? await fetchRecordingSettings(log: false)
            }
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

    func startRecording(_ settings: RecordingSettings) async {
        await perform {
            if settings.dataRate.needsFirmware33 { try requireFirmware() }
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: settings.enablePayload,
                                nackHint: "Mémoire verrouillée, pleine, ou boîtier non Mini S/Micro.")
            recordingSettings = settings
            recordingState = .running
            addLog("Enregistrement autonome démarré : \(settings.summary). Tu peux te déconnecter.")
            try? await refreshRecordingStatus()
        }
    }

    func stopRecording() async {
        await perform {
            try await expectAck(id: UBX.RaceBoxID.recordingConfig, payload: RecordingSettings.disablePayload)
            addLog("Enregistrement arrêté.")
            try? await refreshRecordingStatus()
        }
    }

    /// Lit la configuration d'enregistrement mémorisée par le boîtier (dernière utilisée).
    func readRecordingSettings() async {
        await perform {
            try await fetchRecordingSettings(log: true)
        }
    }

    /// Relecture discrète de l'état de la mémoire (sans journal ni alerte), pour le suivi périodique.
    func pollRecordingStatus() async {
        guard state == .connected, supportsRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        try? await refreshRecordingStatus(log: false)
    }

    /// Déverrouille la mémoire protégée. Le verrou revient à chaque nouvelle connexion.
    func unlockMemory(code: UInt32) async {
        await perform {
            let bytes = withUnsafeBytes(of: code.littleEndian, Array.init)
            try await expectAck(id: UBX.RaceBoxID.unlock, payload: bytes, nackHint: "Code de sécurité refusé.")
            try await refreshRecordingStatus()
            // Le boîtier répond ACK même si le code est faux quand la mémoire n'est pas protégée.
            if recordingStatus?.isLocked == true { throw LinkError.unlockFailed }
            addLog("Mémoire déverrouillée.")
        }
    }

    /// Efface toute la mémoire (peut prendre quelques minutes) ; la progression arrive en 0xFF 0x24.
    func eraseMemory() async {
        await perform {
            inbox.removeAll()
            eraseProgress = 0
            defer { eraseProgress = nil }
            try await send(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.erase, payload: [])
            addLog("Effacement de la mémoire…")
            while true {
                guard state == .connected else { throw LinkError.disconnected }
                guard let frame = await nextFrame(timeout: .seconds(30), matching: {
                    $0.cls == UBX.raceBoxClass
                        && (($0.id == UBX.RaceBoxID.erase && $0.payload.count == 1)
                            || (($0.id == UBX.RaceBoxID.ack || $0.id == UBX.RaceBoxID.nack)
                                && Array($0.payload.prefix(2)) == [UBX.raceBoxClass, UBX.RaceBoxID.erase]))
                }) else { throw LinkError.noResponse }
                if frame.id == UBX.RaceBoxID.erase {
                    eraseProgress = Int(frame.payload[0])
                } else if frame.id == UBX.RaceBoxID.nack {
                    throw LinkError.rejected("Mémoire verrouillée ou autre opération en cours.")
                } else {
                    break
                }
            }
            addLog("Effacement terminé.")
            try? await refreshRecordingStatus()
        }
    }

    /// Interrompt l'effacement ; la partie déjà effacée est perdue.
    func cancelErase() async {
        guard eraseProgress != nil else { return }
        try? await send(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.erase, payload: [0xFF])
    }

    func readRecordingStatus() async {
        await perform { try await refreshRecordingStatus() }
    }

    /// Télécharge toute la mémoire (messages 0xFF 0x21) puis la découpe en sessions.
    func downloadRecording() async {
        await perform {
            try await refreshRecordingStatus()
            guard let status = recordingStatus else { throw LinkError.noResponse }
            if status.storedMessages == 0 {
                addLog("La mémoire du boîtier est vide.")
                return
            }
            if status.isLocked { throw LinkError.memoryLocked }

            downloadBuffer = []
            downloadBoundaries = []
            downloadedCount = 0
            downloadExpected = status.storedMessages
            isDownloading = true
            defer { isDownloading = false }
            inbox.removeAll()
            try await send(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.download, payload: [])
            lastDownloadActivity = Date()
            addLog("Téléchargement de \(status.storedMessages) messages…")

            // Fin du flux : ACK du 0xFF 0x23. On laisse 1 s de grâce au cas où des données suivraient.
            while true {
                guard state == .connected else { throw LinkError.disconnected }
                let reply = await nextFrame(timeout: .seconds(5)) {
                    $0.cls == UBX.raceBoxClass
                        && ((($0.id == UBX.RaceBoxID.ack || $0.id == UBX.RaceBoxID.nack)
                             && Array($0.payload.prefix(2)) == [UBX.raceBoxClass, UBX.RaceBoxID.download])
                            || ($0.id == UBX.RaceBoxID.download && $0.payload.count == 4))
                }
                if let reply, reply.id == UBX.RaceBoxID.download {
                    // Accord du boîtier : nombre maximal de messages qui vont suivre.
                    downloadExpected = Int(reply.payload[0]) | Int(reply.payload[1]) << 8
                        | Int(reply.payload[2]) << 16 | Int(reply.payload[3]) << 24
                    continue
                }
                if let reply {
                    if reply.id == UBX.RaceBoxID.nack {
                        throw LinkError.rejected("Mémoire verrouillée ou téléchargement impossible.")
                    }
                    let seen = downloadBuffer.count
                    try? await Task.sleep(for: .seconds(1))
                    if downloadBuffer.count == seen { break }
                } else if Date().timeIntervalSince(lastDownloadActivity) > 5 {
                    throw LinkError.downloadStalled
                }
            }

            downloadedCount = downloadBuffer.count
            sessions = RecordingSession.split(downloadBuffer, boundaries: downloadBoundaries)
            downloadBuffer = []
            downloadBoundaries = []
            addLog("Téléchargement terminé : \(downloadedCount) échantillons, \(sessions.count) session(s).")
        }
    }

    /// Annule le téléchargement en cours ; les données déjà reçues sont conservées.
    func cancelDownload() async {
        guard isDownloading else { return }
        try? await send(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.download, payload: [0xFF])
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: Aides

    private func fetchRecordingSettings(log: Bool) async throws {
        guard let reply = try await request(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.recordingConfig),
              let decoded = RecordingSettings.fromConfigPayload(reply.payload) else { throw LinkError.noResponse }
        recordingSettings = decoded.settings
        if log {
            addLog("Configuration d'enregistrement (\(decoded.enabled ? "active" : "inactive")) : \(decoded.settings.summary)")
        }
    }

    private func refreshRecordingStatus(log: Bool = true) async throws {
        guard let reply = try await request(cls: UBX.raceBoxClass, id: UBX.RaceBoxID.recordingStatus),
              let status = RecordingStatus(payload: reply.payload) else { throw LinkError.noResponse }
        recordingStatus = status
        if !status.isRecording { recordingState = nil }
        guard log else { return }
        addLog("Mémoire : \(status.storedMessages) / \(status.memorySize) messages (\(status.memoryLevel) %)"
               + (status.isRecording ? ", enregistrement en cours" : "")
               + (status.isLocked ? ", verrouillée" : ""))
    }

    private func handleRecordedData(_ frame: UBXFrame) {
        guard let sample = RaceBoxSample(payload: frame.payload) else { return }
        downloadBuffer.append(sample)
        lastDownloadActivity = Date()
        if downloadBuffer.count % 250 == 0 { downloadedCount = downloadBuffer.count }
    }

    /// Message 0xFF 0x26 : pendant un téléchargement il délimite les sessions, sinon on le signale.
    private func handleStateChange(_ frame: UBXFrame) {
        guard let change = RecordingStateChange(payload: frame.payload) else { return }
        if isDownloading {
            if change != .paused { downloadBoundaries.insert(downloadBuffer.count) }
        } else {
            addLog("Enregistrement autonome \(change.label).")
            recordingState = change
            Task { await pollRecordingStatus() }
        }
    }

    /// Flux temps réel 0xFF 0x01 (25 Hz) : on n'en publie que 4 par seconde pour ménager l'interface.
    private func handleLiveData(_ frame: UBXFrame) {
        guard let sample = RaceBoxSample(payload: frame.payload) else { return }
        let now = Date()
        liveWindowCount += 1
        let window = now.timeIntervalSince(liveWindowStart)
        if window >= 2 {
            liveRate = Double(liveWindowCount) / window
            liveWindowCount = 0
            liveWindowStart = now
        }
        let reading = PowerReading(byte: sample.powerByte, isMicro: isMicro)
        if reading != power {
            power = reading
            trackBattery(reading, at: now)
        }
        if now.timeIntervalSince(lastLivePublish) >= 0.25 {
            liveSample = sample
            lastLivePublish = now
        }
    }

    /// Estime l'autonomie à partir de la pente de décharge entre deux changements de niveau.
    /// Le niveau initial est écarté : on ignore depuis combien de temps il était atteint.
    private func trackBattery(_ reading: PowerReading, at date: Date) {
        guard case .battery(let percent, let charging) = reading else {
            batteryHistory = []
            batteryTimeRemaining = nil
            return
        }
        if charging {
            batteryHistory = []
            batteryTimeRemaining = nil
            return
        }
        if percent == 0, !warnedEmptyBattery, recordingStatus?.isRecording != true {
            // La doc conseille de se déconnecter au plus vite à 0 %, sauf pendant un enregistrement.
            warnedEmptyBattery = true
            addLog("⚠️ Batterie vide : déconnecte le boîtier et recharge-le.")
            errorMessage = "Batterie du RaceBox vide (0 %). Déconnecte-le et recharge-le."
        }
        batteryHistory.append((date, percent))
        let changes = batteryHistory.dropFirst()
        guard let first = changes.first, let last = changes.last, first.percent > last.percent else {
            batteryTimeRemaining = nil
            return
        }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed >= 120 else { return }
        let ratePerSecond = Double(first.percent - last.percent) / elapsed
        batteryTimeRemaining = Double(last.percent) / ratePerSecond
    }

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
        serialNumber = nil
        hardwareRevision = nil
        liveSample = nil
        liveRate = 0
        power = nil
        batteryTimeRemaining = nil
        batteryHistory = []
        warnedEmptyBattery = false
        recordingSettings = nil
        recordingState = nil
        eraseProgress = nil
        gnssConfig = nil
        chipInfo = nil
        recordingStatus = nil
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
        for pending in readContinuations.values { pending.continuation.resume(throwing: error) }
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
            let pending = PendingRead(continuation: continuation)
            readContinuations[uuid] = pending
            peripheral.readValue(for: characteristic)
            // Une caractéristique facultative qui ne répond pas ne doit pas bloquer la connexion.
            Task {
                try? await Task.sleep(for: .seconds(3))
                if readContinuations[uuid]?.id == pending.id {
                    readContinuations.removeValue(forKey: uuid)?.continuation.resume(throwing: LinkError.noResponse)
                }
            }
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
            if old.alreadyConnected { return }
            if old.name != device.name || old.isRaceBox != device.isRaceBox || abs(old.rssi - device.rssi) >= 5 {
                devices[index] = device
            }
        } else {
            devices.append(device)
        }
        // Connexion automatique : uniquement un vrai RaceBox (nom annoncé), jamais un appareil quelconque.
        if autoConnect, isScanning, case .disconnected = state, known?.hasPrefix("RaceBox") == true {
            addLog("Connexion automatique à \(device.name).")
            Task { await connect(device) }
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
            for frame in parser.feed(data) {
                guard frame.cls == UBX.raceBoxClass else {
                    receive(frame)
                    continue
                }
                switch frame.id {
                case UBX.RaceBoxID.liveData:
                    handleLiveData(frame)
                case UBX.RaceBoxID.recordedData where isDownloading:
                    handleRecordedData(frame)
                case UBX.RaceBoxID.recordingStateChange:
                    handleStateChange(frame)
                default:
                    receive(frame)
                }
            }
        } else if let continuation = readContinuations.removeValue(forKey: characteristic.uuid)?.continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
        }
    }
}
