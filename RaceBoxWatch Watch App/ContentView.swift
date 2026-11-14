import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var link = WatchRaceBoxLink.shared
    @State private var workout = FlightWorkout.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.footnote)
                    .foregroundStyle(link.isConnected ? Color.green : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if link.isConnected {
                    StatusPanel(link: link, heartRate: workout.heartRate)
                }

                if link.bluetoothState == .unauthorized {
                    Text(authorizationHelp)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if link.isConnected {
                    recordingButton
                }

                if let result = link.lastResult {
                    Text(result.text)
                        .font(.footnote)
                        .foregroundStyle(result.isError ? Color.red : Color.green)
                        .multilineTextAlignment(.center)
                }

                if link.connection == .idle, link.bluetoothState == .poweredOn {
                    Button("Rechercher") { link.ensureConnected() }
                        .font(.footnote)
                }

                if link.isConnected {
                    // Libère le boîtier pour un autre appareil (Mac, téléphone). Il se reconnecte au retour dans l'app.
                    Button(role: .destructive) {
                        link.disconnect()
                    } label: {
                        Label("Déconnecter", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy)
        }
        // Enregistrement arrêté ailleurs (Mac, bouton du Micro, extinction auto) : on clôt la séance.
        .onChange(of: link.memory?.isRecording) { old, new in
            if old == true, new == false, workout.isActive {
                Task { await workout.end() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.ensureConnected() }
        }
    }

    /// Un seul bouton, selon l'état réel du RaceBox (relu régulièrement).
    @ViewBuilder private var recordingButton: some View {
        if let memory = link.memory {
            if memory.isRecording {
                Button {
                    Task {
                        await link.stopRecording()
                        await workout.end()
                    }
                } label: {
                    Label("Arrêter", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Button {
                    // La séance garde l'app active poignet baissé et arme le bouton Action pour l'arrêt.
                    try? workout.start()
                    Task { await link.startRecording() }
                } label: {
                    Label("Démarrer", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
        } else if link.memoryUnavailable {
            Text("Ce RaceBox n'enregistre pas en autonome (Mini S ou Micro requis).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            ProgressView("Lecture de l'état…")
                .font(.footnote)
        }
    }

    private var statusText: String {
        switch link.bluetoothState {
        case .poweredOn: break
        case .unauthorized: return "Bluetooth non autorisé"
        case .poweredOff: return "Bluetooth désactivé"
        default: return "Bluetooth…"
        }
        switch link.connection {
        case .idle: return "Non connecté"
        case .searching: return "Recherche…"
        case .connecting(let name): return "Connexion à \(name)…"
        case .connected(let name): return name
        }
    }

    /// watchOS ne redemande jamais l'accès après un refus : il faut l'activer à la main.
    private var authorizationHelp: String {
        switch CBManager.authorization {
        case .restricted:
            "Bluetooth bloqué par une restriction (Temps d'écran ou profil de gestion)."
        default:
            "Sur la montre : Réglages > Confidentialité et sécurité > Bluetooth, active RaceBoxWatch. "
                + "Sinon, supprime l'app de la montre puis réinstalle-la pour revoir la demande."
        }
    }

    private var statusSymbol: String {
        link.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
    }
}

#Preview {
    ContentView()
}

// MARK: - Infos du boîtier

/// Cœur rose suivi de la valeur, compact pour tenir à droite de la batterie.
private struct HeartLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(.pink)
            configuration.title
        }
    }
}

/// Résumé compact : enregistrement, batterie, mémoire, GPS.
private struct StatusPanel: View {
    let link: WatchRaceBoxLink
    let heartRate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            recordingRow
            powerRow
            if let memory = link.memory {
                row(symbol: "internaldrive", color: memoryColor(memory.freeRatio),
                    title: memory.freeRatio.formatted(.percent.precision(.fractionLength(0))) + " libre",
                    detail: "≈ " + durationText(memory.remainingTime))
            }
            if let live = link.live {
                row(symbol: live.hasGoodFix ? "location.fill" : "location.slash",
                    color: live.hasGoodFix ? .green : .orange,
                    title: live.hasGoodFix ? "GPS 3D" : live.fixStatus == 0 ? "Pas de fix" : "Fix faible",
                    detail: "\(live.satellites) sat.")
            }
        }
        .font(.footnote)
        .monospacedDigit()
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var recordingRow: some View {
        if let memory = link.memory {
            if memory.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: link.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(link.isPaused ? .orange : .red)
                        .symbolEffect(.pulse, options: .repeating, isActive: !link.isPaused)
                    Text(link.isPaused ? "En pause" : "Enregistre").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if !link.isPaused {
                        Text("REC")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 4)
                            .background(.red, in: .capsule)
                    }
                }
            } else {
                row(symbol: memory.isLocked ? "lock.fill" : "stop.circle", color: .secondary,
                    title: memory.isLocked ? "Mémoire verrouillée" : "À l'arrêt", detail: nil)
            }
        }
    }

    /// Batterie (ou tension du Micro) à gauche, fréquence cardiaque de la séance à droite.
    @ViewBuilder private var powerRow: some View {
        if link.power != nil || heartRate != nil {
            HStack(spacing: 6) {
                switch link.power {
                case .battery(let percent, let charging):
                    Image(systemName: charging ? "battery.100percent.bolt" : batterySymbol(percent))
                        .foregroundStyle(percent <= 10 && !charging ? .red : percent <= 25 && !charging ? .orange : .green)
                        .frame(width: 18)
                    Text("\(percent) %")
                    if let detail = charging ? "en charge" : link.batteryTimeRemaining.map({ "≈ " + durationText($0) }) {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .inputVoltage(let volts):
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow).frame(width: 18)
                    Text(String(format: "%.1f V", volts))
                case nil:
                    EmptyView()
                }
                Spacer(minLength: 4)
                if let heartRate {
                    Label("\(Int(heartRate))", systemImage: "heart.fill")
                        .labelStyle(HeartLabelStyle())
                        .accessibilityLabel("\(Int(heartRate)) battements par minute")
                }
            }
        }
    }

    private func row(symbol: String, color: Color, title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func memoryColor(_ freeRatio: Double) -> Color {
        switch freeRatio {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .green
        }
    }

    /// « 1 h 26 min ».
    private func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
