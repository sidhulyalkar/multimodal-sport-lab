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

    public func start(activity: HKWorkoutActivityType = .other) throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = .outdoor

        Task {
            try await start(configuration: configuration, mirrorToCompanion: false)
        }
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

    public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        switch toState {
        case .running:
            onStateChange?(.running)
        case .paused:
            onStateChange?(.paused)
        case .ended:
            let builder = builder
            builder?.endCollection(withEnd: date) { [weak self] _, _ in
                builder?.finishWorkout { workout, error in
                    guard let self else { return }
                    if let error {
                        self.onStateChange?(.failed(error.localizedDescription))
                    } else {
                        self.onStateChange?(.ended)
                    }
                    self.onWorkoutFinished?(workout)
                    self.session = nil
                    self.builder = nil
                }
            }
        default:
            break
        }
    }

    public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        onStateChange?(.failed(error.localizedDescription))
    }

    public func workoutBuilder(
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
        onHeartRateBPM?(bpm, MonotonicClock.nowNS())
    }

    public func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {}

    public enum RecorderError: Error {
        case alreadyRunning
    }
}
#endif
