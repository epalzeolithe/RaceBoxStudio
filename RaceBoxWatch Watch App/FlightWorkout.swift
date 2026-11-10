import Foundation
import HealthKit
import Observation

/// Séance d'entraînement HealthKit qui accompagne l'enregistrement RaceBox.
/// Elle garde l'app active poignet baissé (la liaison Bluetooth ne coupe pas)
/// et permet de piloter l'enregistrement depuis le bouton Action de l'Apple Watch Ultra.
@Observable
final class FlightWorkout: NSObject {
    static let shared = FlightWorkout()

    private(set) var isActive = false
    /// Fréquence cardiaque la plus récente, en battements par minute.
    private(set) var heartRate: Double?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    /// Démarre la séance (sans effet si elle tourne déjà).
    func start() throws {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder

        // La séance démarre tout de suite (délai de 30 s imposé au bouton Action) ;
        // l'autorisation et la collecte suivent.
        session.startActivity(with: .now)
        isActive = true
        Task {
            await requestAuthorization()
            try? await builder.beginCollection(at: .now)
            // Appui suivant sur le bouton Action : arrêter l'enregistrement.
            try? await StartFlightIntent().donate(result: .result(actionButtonIntent: StopFlightIntent()))
        }
    }

    /// Termine la séance et l'enregistre dans Santé.
    func end() async {
        guard let session, let builder else { return }
        session.end()
        try? await builder.endCollection(at: .now)
        _ = try? await builder.finishWorkout()
        reset()
    }

    private func reset() {
        session = nil
        builder = nil
        isActive = false
        heartRate = nil
    }

    private func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKQuantityType.workoutType()],
                                              read: [HKQuantityType(.heartRate)])
    }
}

// HealthKit appelle ces méthodes sur une file quelconque : on repasse sur l'acteur principal.
extension FlightWorkout: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        // Séance terminée par le système ou depuis le centre de contrôle.
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in
            if self.session === workoutSession, toState == .ended { self.reset() }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            if self.session === workoutSession { self.reset() }
        }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        Task { @MainActor in self.heartRate = bpm }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
