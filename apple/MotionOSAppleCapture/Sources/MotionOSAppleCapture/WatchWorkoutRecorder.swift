#if os(watchOS) && canImport(HealthKit)
import Foundation
import HealthKit

public final class WatchWorkoutRecorder: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    public var onHeartRateBPM: (@Sendable (Double, UInt64) -> Void)?

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

    public func start(activity: HKWorkoutActivityType = .other) throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = .outdoor
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
        let start = Date()
        session.startActivity(with: start)
        builder.beginCollection(withStart: start) { _, _ in }
    }

    public func stop() {
        session?.end()
    }

    public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .ended {
            builder?.endCollection(withEnd: date) { [weak self] _, _ in
                self?.builder?.finishWorkout { _, _ in }
            }
        }
    }

    public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {}

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
}
#endif
