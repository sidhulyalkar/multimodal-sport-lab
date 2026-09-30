#if os(watchOS) && canImport(HealthKit)
import Foundation
import HealthKit

@MainActor
public final class WatchWorkoutRecorder: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case running
        case paused
        case ending
        case ended
        case failed(String)
    }

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    public var onHeartRateBPM: ((Double, UInt64) -> Void)?
    public var onStateChange: ((State) -> Void)?
    public var onWorkoutFinished: ((HKWorkout?) -> Void)?

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public var workoutAuthorizationStatus: HKAuthorizationStatus {
        healthStore.authorizationStatus(for: HKObjectType.workoutType())
    }

    public func requestAuthorization() async throws {
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        try await healthStore.requestAuthorization(
            toShare: [HKObjectType.workoutType()],
            read: [heartRate]
        )
    }

    public func start(
        configuration: HKWorkoutConfiguration,
        mirrorToCompanion: Bool = true
    ) async throws {
        guard session == nil else { throw RecorderError.alreadyRunning }
        onStateChange?(.starting)

        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: configuration
        )
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder

        // Prepare first. This keeps the primary session in a valid pre-running
        // state before mirroring and avoids known intermittent mirroring failures
        // observed on recent iOS/watchOS releases.
        session.prepare()

        if mirrorToCompanion {
            do {
                try await session.startMirroringToCompanionDevice()
            } catch {
                self.session = nil
                self.builder = nil
                onStateChange?(.failed(error.localizedDescription))
                throw error
            }
        }

        let start = Date()
        session.startActivity(with: start)
        do {
            try await builder.beginCollection(at: start)
        } catch {
            session.end()
            self.session = nil
            self.builder = nil
            onStateChange?(.failed(error.localizedDescription))
            throw error
        }
    }

    public func start(
        activity: HKWorkoutActivityType = .other
    ) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = .outdoor
        try await start(
            configuration: configuration,
            mirrorToCompanion: false
        )
    }

    public func pause() {
        session?.pause()
    }

    public func resume() {
        session?.resume()
    }

    public func stop() {
        guard session != nil else { return }
        onStateChange?(.ending)
        session?.end()
    }

    public nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        switch toState {
        case .running:
            Task { @MainActor [weak self] in
                self?.onStateChange?(.running)
            }
        case .paused:
            Task { @MainActor [weak self] in
                self?.onStateChange?(.paused)
            }
        case .ended:
            Task { @MainActor [weak self] in
                await self?.finishWorkout(at: date)
            }
        default:
            break
        }
    }

    public nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onStateChange?(.failed(message))
        }
    }

    public nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRate),
              let statistics = workoutBuilder.statistics(for: heartRate),
              let value = statistics.mostRecentQuantity()
        else { return }

        let bpm = value.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())
        )
        let timestamp = MonotonicClock.nowNS()
        Task { @MainActor [weak self] in
            self?.onHeartRateBPM?(bpm, timestamp)
        }
    }

    public nonisolated func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {}

    private func finishWorkout(at date: Date) async {
        guard let builder else {
            onStateChange?(.failed("Workout builder missing at session end."))
            onWorkoutFinished?(nil)
            session = nil
            return
        }

        defer {
            session = nil
            self.builder = nil
        }

        do {
            try await builder.endCollection(at: date)
            let workout = try await builder.finishWorkout()
            onStateChange?(.ended)
            onWorkoutFinished?(workout)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            onWorkoutFinished?(nil)
        }
    }

    public enum RecorderError: Error {
        case alreadyRunning
    }
}
#endif
