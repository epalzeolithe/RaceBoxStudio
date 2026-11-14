import SwiftUI
import CoreBluetooth
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Volets affichés dans la barre latérale.
private enum Pane: Hashable, CaseIterable {
    case connection, device, live, recording, settings, csvViewer, gpxViewer

    var title: String {
        switch self {
        case .connection: "Connexion"
        case .device: "Boîtier"
        case .live: "Temps réel"
        case .recording: "Enregistrement"
        case .settings: "Réglages"
        case .csvViewer: "Visionneuse CSV"
        case .gpxViewer: "Trajectoire GPX"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .device: "cpu"
        case .live: "gauge.with.dots.needle.67percent"
        case .recording: "record.circle"
        case .settings: "gearshape"
        case .csvViewer: "chart.xyaxis.line"
        case .gpxViewer: "rotate.3d"
        }
    }
}

struct ContentView: View {
    @State private var link = RaceBoxLink()
    @State private var pane: Pane? = .connection
    @State private var viewers = ViewerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(link: link, selection: $pane)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                NavigationStack {
                    detail
                        .navigationTitle(pane?.title ?? "RaceBoxStudio")
                        #if os(macOS)
                        .navigationSubtitle("Build \(BuildNumber.current)")
                        #endif
                }
                ConsoleView(link: link)
            }
        }
        // Une fois connecté on passe au boîtier ; à la déconnexion on revient à la connexion.
        // Vibration (iPhone) au démarrage et à l'arrêt de l'enregistrement, quelle qu'en soit l'origine.
        .sensoryFeedback(trigger: link.recordingStatus?.isRecording) { old, new in
            switch (old, new) {
            case (false, true): .start
            case (true, false): .stop
            default: nil
            }
        }
        .onChange(of: link.state) { _, new in
            // On ne sort pas l'utilisateur d'une visionneuse ou des réglages.
            switch new {
            case .connected where pane == .connection || pane == nil: pane = .device
            case .disconnected where [.device, .live, .recording].contains(pane): pane = .connection
            default: break
            }
        }
        #if os(iOS)
        // Sur iOS, « quitter » = passer en arrière-plan : on libère le boîtier, puis on le retrouve au retour.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // On ne coupe pas un téléchargement ou un effacement en cours.
                if link.disconnectOnQuit, !link.isDownloading, link.eraseProgress == nil { link.disconnect() }
            case .active:
                if link.autoConnect, link.state == .disconnected { link.startScanning() }
            default:
                break
            }
        }
        #endif
        .alert("Fichier illisible", isPresented: Binding(get: { viewers.errorMessage != nil },
                                                         set: { if !$0 { viewers.errorMessage = nil } }),
               presenting: viewers.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Erreur", isPresented: Binding(get: { link.errorMessage != nil },
                                              set: { if !$0 { link.errorMessage = nil } }),
               presenting: link.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .connection, nil:
            ConnectionPane(link: link)
        case .settings:
            SettingsPane(link: link)
        case .csvViewer:
            CSVViewerPane(store: viewers, sessions: link.sessions)
        case .gpxViewer:
            GPXViewerPane(store: viewers, sessions: link.sessions)
        case .device, .live, .recording:
            if link.state != .connected {
                ContentUnavailableView("Aucun boîtier connecté",
                                       systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Connecte un RaceBox depuis le volet Connexion."))
            } else if pane == .device {
                DeviceTab(link: link)
            } else if pane == .live {
                LiveTab(link: link)
            } else if link.supportsRecording {
                RecordingTab(link: link)
            } else {
                ContentUnavailableView("Enregistrement non disponible",
                                       systemImage: "record.circle",
                                       description: Text("Seuls les RaceBox Mini S et Micro enregistrent en autonome."))
            }
        }
    }
}

// MARK: - Barre latérale

private struct SidebarView: View {
    let link: RaceBoxLink
    @Binding var selection: Pane?

    var body: some View {
        List(selection: $selection) {
            // `tag` plutôt que NavigationLink : le bouton de droite reste cliquable sans sélectionner la ligne.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label {
                        Text(Pane.connection.title).lineLimit(1).fixedSize()
                    } icon: {
                        Image(systemName: Pane.connection.systemImage)
                            .foregroundStyle(link.state == .connected ? Color.green : Color.accentColor)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    connectionButton
                }
                // Sur sa propre ligne : toute la largeur, sinon le % de batterie est tronqué sur iPad.
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 30)
            }
            .tag(Pane.connection)
            Section(link.deviceName ?? "Boîtier") {
                ForEach([Pane.device, .live, .recording], id: \.self) { pane in
                    NavigationLink(value: pane) {
                        Label(pane.title, systemImage: pane.systemImage)
                    }
                    .disabled(!isAvailable(pane))
                }
            }
            if link.state == .connected, link.supportsRecording {
                Section("Statut") {
                    RecordingStatusCard(link: link)
                }
            }
            // Visionneuses : utilisables sans boîtier connecté.
            Section("Fichiers") {
                ForEach([Pane.csvViewer, .gpxViewer], id: \.self) { pane in
                    NavigationLink(value: pane) {
                        Label(pane.title, systemImage: pane.systemImage)
                    }
                }
            }
        }
        .navigationTitle("RaceBoxStudio")
        // Suivi de la mémoire : toutes les 15 s pendant un enregistrement, sinon toutes les minutes
        // (un Micro peut démarrer avec son bouton).
        .task(id: link.state == .connected) {
            while link.state == .connected, !Task.isCancelled {
                let interval: Duration = link.recordingStatus?.isRecording == true ? .seconds(15) : .seconds(60)
                try? await Task.sleep(for: interval)
                await link.pollRecordingStatus()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    selection = .settings
                } label: {
                    Image(systemName: selection == .settings ? "gearshape.fill" : "gearshape")
                        .font(.title3)
                        .foregroundStyle(selection == .settings ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Réglages")
                .accessibilityLabel("Réglages")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// Action principale selon l'état : connecter, rechercher, arrêter la recherche ou déconnecter.
    @ViewBuilder private var connectionButton: some View {
        Group {
            switch link.state {
            case .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                Button("Déconnecter", role: .destructive) { link.disconnect() }
            case .disconnected:
                // Le RaceBox au meilleur signal, s'il y en a un à portée.
                if let nearest = link.devices.filter(\.isRaceBox).max(by: { $0.rssi < $1.rssi }) {
                    Button("Connecter") { Task { await link.connect(nearest) } }
                        .help("Se connecter à \(nearest.name)")
                } else if link.isScanning {
                    Button("Arrêter") { link.stopScanning() }
                } else {
                    Button("Rechercher") { link.startScanning() }
                        .disabled(link.bluetoothState != .poweredOn)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Ne jamais couper le libellé du bouton sur deux lignes (barre latérale étroite de l'iPad).
        .lineLimit(1)
        .fixedSize()
    }

    private func isAvailable(_ pane: Pane) -> Bool {
        guard link.state == .connected else { return false }
        return pane != .recording || link.supportsRecording
    }

    private var connectionSummary: String {
        switch link.state {
        case .connected:
            if case .battery(let percent, _) = link.power { return "Connecté · \(percent) %" }
            return "Connecté"
        case .connecting: return "Connexion…"
        case .disconnected: return link.isScanning ? "Recherche…" : "Déconnecté"
        }
    }
}

// MARK: - Statut d'enregistrement

/// Carte de la barre latérale : enregistrement en cours ou non, et place restante.
private struct RecordingStatusCard: View {
    let link: RaceBoxLink

    private enum Activity {
        case recording, paused, stopped, unknown

        var title: String {
            switch self {
            case .recording: "Enregistrement"
            case .paused: "En pause"
            case .stopped: "À l'arrêt"
            case .unknown: "État inconnu"
            }
        }
        var symbol: String {
            switch self {
            case .recording: "record.circle.fill"
            case .paused: "pause.circle.fill"
            case .stopped: "stop.circle"
            case .unknown: "questionmark.circle"
            }
        }
        var color: Color {
            switch self {
            case .recording: .red
            case .paused: .orange
            case .stopped, .unknown: .secondary
            }
        }
    }

    private var activity: Activity {
        guard let status = link.recordingStatus else { return .unknown }
        guard status.isRecording else { return .stopped }
        return link.recordingState == .paused ? .paused : .recording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: activity.symbol)
                    .font(.title2)
                    .foregroundStyle(activity.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: activity == .recording)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(activity.title).font(.headline)
                        if activity == .recording {
                            Text("REC")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.red, in: .capsule)
                        }
                    }
                    if activity == .paused {
                        Text("Filtre d'arrêt ou de fix actif").font(.caption).foregroundStyle(.secondary)
                    } else if let settings = link.recordingSettings, activity == .recording {
                        Text("\(settings.dataRate.hertz) Hz").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if link.recordingStatus?.isLocked == true {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Mémoire verrouillée")
                }
            }

            if let status = link.recordingStatus, status.memorySize > 0 {
                let free = max(status.memorySize - status.storedMessages, 0)
                let freeRatio = Double(free) / Double(status.memorySize)
                let hertz = link.recordingSettings?.dataRate.hertz ?? 25
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Place libre").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(freeRatio.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(memoryColor(freeRatio))
                    }
                    ProgressView(value: 1 - freeRatio)
                        .tint(memoryColor(freeRatio))
                    Text("\(free.formatted()) / \(status.memorySize.formatted()) messages")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("≈ \(durationText(status.remainingTime(hertz: hertz))) à \(hertz) Hz")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }

            recordingButton
        }
        .padding(.vertical, 4)
    }

    /// Démarre avec la dernière configuration connue du boîtier (réglable dans le volet Enregistrement).
    @ViewBuilder private var recordingButton: some View {
        let isRecording = link.recordingStatus?.isRecording == true
        let settings = link.recordingSettings ?? .aerobatics
        Button {
            Task {
                if isRecording {
                    await link.stopRecording()
                } else {
                    await link.startRecording(settings)
                }
            }
        } label: {
            RecordButtonLabel(isRecording: isRecording, isBusy: link.isBusy)
        }
        .buttonStyle(RecordButtonStyle(isRecording: isRecording))
        .help(isRecording ? "Arrêter l'enregistrement autonome" : "Démarre avec : \(settings.summary)")
        .disabled(link.isBusy || link.recordingStatus == nil || link.recordingStatus?.isLocked == true)
        .animation(.snappy, value: isRecording)
    }

    private func memoryColor(_ freeRatio: Double) -> Color {
        switch freeRatio {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .green
        }
    }
}

/// Pastille « enregistrer » (rond dans un anneau) ou « arrêter » (carré), façon magnétoscope.
private struct RecordButtonLabel: View {
    let isRecording: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                } else {
                    Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                    Circle().fill(.white).padding(4)
                }
            }
            .frame(width: 16, height: 16)
            Text(isRecording ? "Arrêter" : "Enregistrer")
                .contentTransition(.interpolate)
        }
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = isRecording ? Color(white: 0.22) : Color.red
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(fill.gradient, in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: fill.opacity(isEnabled ? 0.35 : 0), radius: 4, y: 2)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

// MARK: - Console

/// Journal des échanges, visible sous tous les volets et repliable.
private struct ConsoleView: View {
    let link: RaceBoxLink
    /// Repliée par défaut sur iPhone, où la place manque.
    @AppStorage("consoleExpanded") private var isExpanded = ConsoleView.expandedByDefault

    private static var expandedByDefault: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Label("Console", systemImage: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text("\(link.log.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if isExpanded {
                    Button("Effacer", systemImage: "trash") { link.clearLog() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(link.log.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if isExpanded {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(link.log) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .foregroundStyle(entry.text.hasPrefix("→") ? Color.secondary : Color.primary)
                            }
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(height: 160)
                .scrollPosition($scrollPosition)
                // Ouvre la console sur les derniers messages…
                .defaultScrollAnchor(.bottom)
                // …et y redescend à chaque nouveau message (une fois la ligne mise en page).
                .onChange(of: link.log.last?.id) {
                    Task { withAnimation(.easeOut(duration: 0.15)) { scrollPosition.scrollTo(edge: .bottom) } }
                }
            }
        }
        .background(.bar)
    }
}

// MARK: - Volet Réglages

private struct SettingsPane: View {
    @Bindable var link: RaceBoxLink

    var body: some View {
        Form {
            Section {
                Toggle("Connexion automatique", isOn: $link.autoConnect)
                Toggle(disconnectLabel, isOn: $link.disconnectOnQuit)
            } header: {
                Text("Connexion")
            } footer: {
                Text("La connexion automatique choisit le premier boîtier dont le nom commence par « RaceBox » "
                     + "pendant une recherche (au lancement ou via « Rechercher »). "
                     + "Se déconnecter libère le boîtier pour un autre appareil ; un enregistrement autonome en cours continue.")
            }
        }
        .formStyle(.grouped)
    }

    private var disconnectLabel: String {
        #if os(macOS)
        "Déconnecter en quittant l'app"
        #else
        "Déconnecter quand l'app passe en arrière-plan"
        #endif
    }
}

// MARK: - Volet Connexion

private struct ConnectionPane: View {
    @Bindable var link: RaceBoxLink

    var body: some View {
        Form {
            Section("Bluetooth") {
                Text(bluetoothStatus)
                    .foregroundStyle(link.bluetoothState == .poweredOn ? Color.secondary : Color.red)
            }
            Section("Boîtiers") {
                switch link.state {
                case .connecting(let name):
                    Label("Connexion à \(name)…", systemImage: "hourglass")
                case .connected:
                    if let name = link.deviceName {
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Déconnecter", role: .destructive) { link.disconnect() }
                case .disconnected:
                    Toggle("Afficher tous les appareils BLE", isOn: $link.showAllDevices)
                    ForEach(link.visibleDevices) { device in
                        Button {
                            Task { await link.connect(device) }
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                if device.alreadyConnected {
                                    Text("Encore connecté · reprendre").foregroundStyle(.secondary)
                                } else {
                                    Text("\(device.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    if link.visibleDevices.isEmpty {
                        Text(link.isScanning ? "Recherche en cours…" : "Aucun boîtier trouvé")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if link.state == .disconnected {
                Section {
                    Text("Allume le RaceBox et ferme l'app RaceBox du téléphone : le boîtier n'accepte qu'un seul client.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            if link.state == .disconnected {
                ToolbarItem {
                    Button(link.isScanning ? "Arrêter" : "Rechercher",
                           systemImage: link.isScanning ? "stop.circle" : "dot.radiowaves.left.and.right") {
                        link.isScanning ? link.stopScanning() : link.startScanning()
                    }
                }
            }
        }
    }

    private var bluetoothStatus: String {
        switch link.bluetoothState {
        case .poweredOn: "Activé"
        case .poweredOff: "Désactivé"
        case .unauthorized: "Non autorisé (Réglages Système > Confidentialité)"
        case .unsupported: "Non pris en charge"
        default: "Initialisation…"
        }
    }
}

/// Texte court pour une durée : « 3 h 12 min ».
private func durationText(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

// MARK: - Volet Boîtier

private struct DeviceTab: View {
    let link: RaceBoxLink
    @State private var draft = GNSSConfig.aerobatics
    @State private var confirmApply = false

    var body: some View {
        Form {
            Section("Boîtier") {
                LabeledContent("Nom", value: link.deviceName ?? "—")
                LabeledContent("Modèle", value: link.modelNumber ?? "—")
                LabeledContent("Firmware", value: link.firmware ?? "—")
                LabeledContent("N° de série", value: link.serialNumber ?? "—")
                LabeledContent("Révision matérielle", value: link.hardwareRevision ?? "—")
            }

            PowerSection(link: link)

            Section("Configuration GNSS") {
                if let current = link.gnssConfig {
                    LabeledContent("Actuel", value: "\(DynamicModel.name(for: current.dynamicModel)) · "
                                   + "\(current.speed3D ? "vitesse 3D" : "vitesse sol") · \(current.minAccuracy) m")
                }
                Picker("Modèle dynamique", selection: $draft.dynamicModel) {
                    ForEach(DynamicModel.all) { Text($0.name).tag($0.id) }
                }
                Toggle("Vitesse 3D", isOn: $draft.speed3D)
                Stepper("Précision min. : \(draft.minAccuracy) m",
                        value: Binding(get: { Int(draft.minAccuracy) },
                                       set: { draft.minAccuracy = UInt8(clamping: $0) }),
                        in: 1...255)
                HStack {
                    Button("Lire") { Task { await link.readGNSSConfig() } }
                    Spacer()
                    Button("Appliquer au boîtier…") { confirmApply = true }
                }
                .disabled(link.isBusy)
            }

            Section("Puce GNSS") {
                if let chip = link.chipInfo {
                    LabeledContent("Logiciel", value: chip.software)
                    LabeledContent("Matériel", value: chip.hardware)
                    ForEach(chip.extensions, id: \.self) { Text($0).font(.callout.monospaced()) }
                }
                Button("Interroger la puce") { Task { await link.queryChip() } }
                    .disabled(link.isBusy)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Modifier la configuration GNSS du boîtier ?", isPresented: $confirmApply) {
            Button("Appliquer") { Task { await link.applyGNSSConfig(draft) } }
        } message: {
            Text("Le réglage est conservé après redémarrage du RaceBox.")
        }
        .onChange(of: link.gnssConfig) { _, new in
            if let new { draft = new }
        }
        .task { await link.readGNSSConfig() }
    }
}

private struct PowerSection: View {
    let link: RaceBoxLink

    var body: some View {
        Section("Alimentation") {
            switch link.power {
            case .battery(let percent, let charging):
                LabeledContent("Batterie") {
                    Label("\(percent) %" + (charging ? " · en charge" : ""), systemImage: batterySymbol(percent, charging))
                        .foregroundStyle(percent <= 10 && !charging ? Color.red : Color.primary)
                        .monospacedDigit()
                }
                LabeledContent("Autonomie estimée") {
                    if charging {
                        Text("—")
                    } else if let remaining = link.batteryTimeRemaining {
                        Text("≈ " + durationText(remaining)).monospacedDigit()
                    } else {
                        Text("Mesure en cours (après deux baisses de niveau)").foregroundStyle(.secondary)
                    }
                }
            case .inputVoltage(let volts):
                LabeledContent("Tension d'entrée", value: String(format: "%.1f V", volts))
                Text("Le RaceBox Micro n'a pas de batterie : il est alimenté par le véhicule.")
                    .font(.caption).foregroundStyle(.secondary)
            case nil:
                Text("En attente des données temps réel…").foregroundStyle(.secondary)
            }
        }
    }

    private func batterySymbol(_ percent: Int, _ charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Volet Temps réel

private struct LiveTab: View {
    let link: RaceBoxLink

    var body: some View {
        Form {
            PowerSection(link: link)
            if let s = link.liveSample {
                Section("GNSS") {
                    LabeledContent("Fix") {
                        Label(fixText(s), systemImage: s.hasGoodFix ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(s.hasGoodFix ? Color.green : Color.orange)
                    }
                    LabeledContent("Satellites", value: "\(s.satellites)")
                    LabeledContent("Précision", value: String(format: "H %.1f m · V %.1f m · PDOP %.1f",
                                                               s.horizontalAccuracy, s.verticalAccuracy, s.pdop))
                    if s.hasValidPosition {
                        LabeledContent("Position", value: String(format: "%.6f, %.6f", s.latitude, s.longitude))
                        LabeledContent("Altitude", value: String(format: "%.0f m", s.altitudeMSL))
                    }
                    if let date = s.date {
                        LabeledContent("Heure UTC", value: date.formatted(date: .omitted, time: .standard))
                    }
                    LabeledContent("Fréquence reçue", value: String(format: "%.0f Hz", link.liveRate))
                }
                Section("Mouvement") {
                    LabeledContent("Vitesse", value: String(format: "%.1f km/h (± %.1f)", s.speed * 3.6, s.speedAccuracy * 3.6))
                    LabeledContent("Cap", value: String(format: "%.0f°", s.heading))
                    LabeledContent("Accélération", value: String(format: "X %+.2f · Y %+.2f · Z %+.2f g", s.gForceX, s.gForceY, s.gForceZ))
                    LabeledContent("Facteur de charge", value: String(format: "%.2f g", s.totalG))
                    LabeledContent("Rotation", value: String(format: "roulis %+.0f · tangage %+.0f · lacet %+.0f °/s",
                                                             s.rotationX, s.rotationY, s.rotationZ))
                }
                .monospacedDigit()
            } else {
                Section {
                    Text(link.isDownloading || link.eraseProgress != nil
                         ? "Flux temps réel suspendu pendant le transfert mémoire."
                         : "En attente des données temps réel…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func fixText(_ s: RaceBoxSample) -> String {
        switch s.fixStatus {
        case 3: s.hasGoodFix ? "3D" : "3D (précision insuffisante)"
        case 2: "2D"
        default: "Pas de fix"
        }
    }
}

// MARK: - Volet Enregistrement

private struct RecordingTab: View {
    let link: RaceBoxLink
    @State private var settings = RecordingSettings.aerobatics
    @State private var unlockCode = ""
    @State private var confirmErase = false
    @State private var exportFile = ExportFile(text: "")
    @State private var exportType = UTType.commaSeparatedText
    @State private var exportName = "racebox"
    @State private var showExporter = false

    private func export(_ text: String, type: UTType, name: String) {
        exportFile = ExportFile(text: text)
        exportType = type
        exportName = name
        showExporter = true
    }

    /// Lie un champ UInt16 des réglages à un Stepper entier.
    private func value(_ keyPath: WritableKeyPath<RecordingSettings, UInt16>) -> Binding<Int> {
        Binding(get: { Int(settings[keyPath: keyPath]) },
                set: { settings[keyPath: keyPath] = UInt16(clamping: $0) })
    }

    private var stationaryKmh: Binding<Int> {
        Binding(get: { Int((Double(settings.stationarySpeed) * 0.0036).rounded()) },
                set: { settings.stationarySpeed = UInt16(clamping: Int((Double($0) / 0.0036).rounded())) })
    }

    var body: some View {
        Form {
            Section("Mémoire") {
                if let status = link.recordingStatus {
                    LabeledContent("Occupation", value: "\(status.storedMessages) / \(status.memorySize) messages (\(status.memoryLevel) %)")
                    ProgressView(value: Double(status.memoryLevel), total: 100)
                    LabeledContent("État", value: status.isRecording ? "Enregistrement en cours"
                                   : status.isLocked ? "Verrouillée" : "À l'arrêt")
                    LabeledContent("Autonomie mémoire à \(settings.dataRate.hertz) Hz",
                                   value: durationText(status.remainingTime(hertz: settings.dataRate.hertz)))
                    if status.isLocked {
                        HStack {
                            SecureField("Code de sécurité", text: $unlockCode)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                            Button("Déverrouiller") {
                                guard let code = UInt32(unlockCode) else { return }
                                Task { await link.unlockMemory(code: code) }
                            }
                            .disabled(UInt32(unlockCode) == nil || link.isBusy)
                        }
                    }
                }
                Button("Lire l'état") { Task { await link.readRecordingStatus() } }
                    .disabled(link.isBusy)
            }

            Section("Enregistrement autonome") {
                if let current = link.recordingSettings {
                    LabeledContent("Dernière config", value: current.summary)
                }
                Picker("Fréquence", selection: $settings.dataRate) {
                    ForEach(RecordingSettings.DataRate.ordered) { Text("\($0.hertz) Hz").tag($0) }
                }
                Toggle("Attendre le fix GNSS avant d'enregistrer", isOn: $settings.waitForFix)
                Toggle("Filtre d'arrêt (pause à l'arrêt)", isOn: $settings.stationaryFilter)
                if settings.stationaryFilter {
                    Stepper("Sous \(stationaryKmh.wrappedValue) km/h", value: stationaryKmh, in: 1...100)
                    Stepper("Pendant \(settings.stationaryInterval) s", value: value(\.stationaryInterval), in: 1...3600, step: 5)
                }
                Toggle("Filtre No-Fix (pause sans fix)", isOn: $settings.noFixFilter)
                if settings.noFixFilter {
                    Stepper("Après \(settings.noFixInterval) s sans fix", value: value(\.noFixInterval), in: 1...3600, step: 5)
                    Text("Déconseillé en voltige : un vol dos prolongé peut faire perdre le fix.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Extinction automatique", isOn: $settings.autoShutdown)
                if settings.autoShutdown {
                    Stepper("Après \(durationText(Double(settings.shutdownInterval))) sans donnée",
                            value: value(\.shutdownInterval), in: 60...3600, step: 60)
                    Toggle("Pas d'extinction avant la première donnée", isOn: $settings.waitForDataBeforeShutdown)
                    if !settings.stationaryFilter && !settings.noFixFilter && !settings.waitForFix {
                        Text("Sans filtre ni attente de fix, l'extinction automatique ne se déclenche jamais.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Lire") { Task { await link.readRecordingSettings() } }
                    Spacer()
                    Button("Démarrer") { Task { await link.startRecording(settings) } }
                    Button("Arrêter") { Task { await link.stopRecording() } }
                }
                .disabled(link.isBusy)
            }

            Section("Données enregistrées") {
                HStack {
                    Button("Télécharger la mémoire") { Task { await link.downloadRecording() } }
                    Spacer()
                    if link.isDownloading {
                        Button("Annuler", role: .cancel) { Task { await link.cancelDownload() } }
                    }
                }
                .disabled(link.isBusy && !link.isDownloading)
                .buttonStyle(.bordered)
                if link.isDownloading {
                    ProgressView(value: Double(min(link.downloadedCount, max(link.downloadExpected, 1))),
                                 total: Double(max(link.downloadExpected, 1))) {
                        Text("\(link.downloadedCount) / \(link.downloadExpected) échantillons reçus")
                            .font(.caption).monospacedDigit()
                    }
                }
                if !link.sessions.isEmpty {
                    Text("Données gardées en mémoire dans l'app jusqu'à sa fermeture : exporte les sessions à conserver.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(link.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title).font(.headline)
                        Text("\(session.samples.count) échantillons · \(Int(session.duration)) s · "
                             + "vitesse max \(Int(session.maxSpeedKmh)) km/h · "
                             + String(format: "%.1f g max", session.maxG))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Exporter CSV") {
                                export(session.csv(), type: .commaSeparatedText, name: session.fileStem + ".csv")
                            }
                            Button("Exporter GPX") {
                                export(session.gpx(), type: ExportFile.gpxType, name: session.fileStem + ".gpx")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("Effacement") {
                if let progress = link.eraseProgress {
                    ProgressView(value: Double(progress), total: 100) {
                        Text("Effacement : \(progress) %").font(.caption).monospacedDigit()
                    }
                    Button("Interrompre", role: .cancel) { Task { await link.cancelErase() } }
                } else {
                    Button("Effacer la mémoire…", role: .destructive) { confirmErase = true }
                        .disabled(link.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Effacer toute la mémoire du boîtier ?", isPresented: $confirmErase) {
            Button("Effacer", role: .destructive) { Task { await link.eraseMemory() } }
        } message: {
            Text("Les enregistrements non téléchargés seront perdus. L'opération peut durer quelques minutes.")
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: exportType,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result { link.errorMessage = error.localizedDescription }
        }
        .onChange(of: link.recordingSettings) { _, new in
            if let new { settings = new }
        }
        .task {
            await link.readRecordingStatus()
            await link.readRecordingSettings()
        }
    }
}

#Preview("Bouton d'enregistrement") {
    VStack(spacing: 12) {
        Button {} label: { RecordButtonLabel(isRecording: false, isBusy: false) }
            .buttonStyle(RecordButtonStyle(isRecording: false))
        Button {} label: { RecordButtonLabel(isRecording: true, isBusy: false) }
            .buttonStyle(RecordButtonStyle(isRecording: true))
        Button {} label: { RecordButtonLabel(isRecording: false, isBusy: true) }
            .buttonStyle(RecordButtonStyle(isRecording: false))
            .disabled(true)
    }
    .padding()
    .frame(width: 230)
}

#Preview {
    ContentView()
}
