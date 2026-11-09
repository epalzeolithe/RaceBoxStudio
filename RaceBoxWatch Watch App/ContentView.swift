import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var link = WatchRaceBoxLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.footnote)
                    .foregroundStyle(link.isConnected ? Color.green : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await link.startRecording() }
                } label: {
                    Label("Démarrer", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)

                Button {
                    Task { await link.stopRecording() }
                } label: {
                    Label("Arrêter", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

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
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.ensureConnected() }
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

    private var statusSymbol: String {
        link.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
    }
}

#Preview {
    ContentView()
}
