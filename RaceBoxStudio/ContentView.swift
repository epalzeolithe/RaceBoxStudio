import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var link = RaceBoxLink()

    var body: some View {
        NavigationSplitView {
            DeviceListView(link: link)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if link.state == .connected {
                DeviceDetailView(link: link)
            } else {
                ContentUnavailableView("Aucun boîtier connecté",
                                       systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Allume le RaceBox, ferme l'app RaceBox du téléphone, puis lance la recherche."))
            }
        }
        .navigationTitle("RaceBoxStudio")
        .alert("Erreur", isPresented: Binding(get: { link.errorMessage != nil },
                                              set: { if !$0 { link.errorMessage = nil } }),
               presenting: link.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Liste des boîtiers

private struct DeviceListView: View {
    @Bindable var link: RaceBoxLink

    var body: some View {
        List {
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
                                Text("\(device.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    if link.visibleDevices.isEmpty {
                        Text(link.isScanning ? "Recherche en cours…" : "Aucun boîtier trouvé")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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

// MARK: - Détail du boîtier

private struct DeviceDetailView: View {
    let link: RaceBoxLink
    @State private var draft = GNSSConfig.aerobatics
    @State private var confirmApply = false

    var body: some View {
        Form {
            Section("Boîtier") {
                LabeledContent("Nom", value: link.deviceName ?? "—")
                LabeledContent("Modèle", value: link.modelNumber ?? "—")
                LabeledContent("Firmware", value: link.firmware ?? "—")
            }

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
                    Button("Réglage voltige") { draft = .aerobatics }
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

            Section("Enregistrement autonome (25 Hz)") {
                HStack {
                    Button("Démarrer") { Task { await link.startRecording() } }
                    Button("Arrêter") { Task { await link.stopRecording() } }
                }
                .disabled(link.isBusy)
            }

            Section("Journal") {
                ForEach(link.log.reversed()) { entry in
                    Text(entry.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
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

#Preview {
    ContentView()
}
