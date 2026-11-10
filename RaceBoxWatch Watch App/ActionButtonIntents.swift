import AppIntents

// Bouton Action de l'Apple Watch Ultra (Réglages > Bouton Action > Entraînement > RaceBoxWatch) :
// premier appui = démarre la séance et l'enregistrement, appui suivant = arrête les deux.
// Ces intentions doivent rester dans l'app montre, pas dans une extension.

enum FlightStyle: String, AppEnum {
    case flight

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Séance"
    static let caseDisplayRepresentations: [FlightStyle: DisplayRepresentation] = [
        .flight: DisplayRepresentation(title: "Vol RaceBox", subtitle: "Enregistrement autonome 25 Hz"),
    ]
}

struct StartFlightIntent: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Démarrer l'enregistrement RaceBox"
    static let suggestedWorkouts: [StartFlightIntent] = [StartFlightIntent()]

    @Parameter(title: "Séance")
    var workoutStyle: FlightStyle

    init() {
        workoutStyle = .flight
    }

    var displayRepresentation: DisplayRepresentation {
        FlightStyle.caseDisplayRepresentations[workoutStyle] ?? DisplayRepresentation(title: "Vol RaceBox")
    }

    func perform() async throws -> some IntentResult {
        // La séance doit démarrer dans les 30 s : on la lance d'abord, la connexion BLE suit.
        try await MainActor.run { try FlightWorkout.shared.start() }
        Task { @MainActor in await WatchRaceBoxLink.shared.startRecordingWhenReady() }
        return .result()
    }
}

struct StopFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrêter l'enregistrement RaceBox"

    func perform() async throws -> some IntentResult {
        await WatchRaceBoxLink.shared.stopRecordingWhenReady()
        await FlightWorkout.shared.end()
        return .result()
    }
}
