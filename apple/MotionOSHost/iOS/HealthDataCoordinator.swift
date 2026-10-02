import Combine
import Foundation
import HealthKit
import MotionOSAppleCapture

@MainActor
final class HealthDataCoordinator: ObservableObject {
    enum State: Equatable {
        case unavailable
        case notRequested
        case requesting
        case syncing
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .unavailable:
                return "Unavailable"
            case .notRequested:
                return "Connect Health"
            case .requesting:
                return "Requesting access"
            case .syncing:
                return "Syncing"
            case .ready:
                return "Connected"
            case .failed:
                return "Needs attention"
            }
        }
    }

    @Published private(set) var state: State
    @Published private(set) var timeline: BodyStateTimeline
    @Published private(set) var timelineURL: URL?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var importedObservationCount = 0

    private let healthStore: HKHealthStore
    private let anchorStore = HealthKitAnchorStore()
    private var observerQueries: [HKObserverQuery] = []
    private var requestedAccessThisInstall = false
    private let accessRequestedKey =
        "motionos.healthkit.access-requested.v1"

    init(
        healthStore: HKHealthStore = HKHealthStore()
    ) {
        self.healthStore = healthStore

        if let loaded = Self.loadTimeline() {
            timeline = loaded.timeline
            timelineURL = loaded.url
            importedObservationCount = loaded.timeline.observations.count
        } else {
            timeline = BodyStateTimeline()
            timelineURL = nil
        }

        if HKHealthStore.isHealthDataAvailable() {
            let previouslyRequested = UserDefaults.standard.bool(
                forKey: accessRequestedKey
            )
            state = previouslyRequested ? .ready : .notRequested
            installObserverQueries()

            if previouslyRequested {
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
        } else {
            state = .unavailable
        }
    }

    var supportedKinds: [BodyStateKind] {
        Self.descriptors.compactMap { $0.kind }
    }

    var latestContext: BodyStateContextSnapshot {
        BodyStateContextSnapshot(
            capturedAt: Date(),
            timeline: timeline
        )
    }

    func requestAccessAndSync() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .unavailable
            return
        }

        state = .requesting
        lastError = nil

        do {
            try await healthStore.requestAuthorization(
                toShare: [],
                read: Set(Self.descriptors.map(\.type))
            )
            requestedAccessThisInstall = true
            UserDefaults.standard.set(
                true,
                forKey: accessRequestedKey
            )
            await enableBackgroundDelivery()
            await syncAll()
        } catch {
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .unavailable
            return
        }

        // HealthKit intentionally doesn't expose whether the user granted each
        // read permission. A refresh is safe even when some types are denied:
        // those queries simply return no readable samples.
        await syncAll()
    }

    func contextSnapshot(
        at date: Date
    ) -> BodyStateContextSnapshot {
        BodyStateContextSnapshot(
            capturedAt: date,
            timeline: timeline
        )
    }

    private func installObserverQueries() {
        guard observerQueries.isEmpty else { return }

        for descriptor in Self.descriptors {
            let query = HKObserverQuery(
                sampleType: descriptor.type,
                predicate: nil
            ) { [weak self] _, completion, error in
                guard let self else {
                    completion()
                    return
                }

                if let error {
                    Task { @MainActor in
                        self.lastError = error.localizedDescription
                        switch self.state {
                        case .requesting, .syncing:
                            self.state = .failed(
                                error.localizedDescription
                            )
                        default:
                            // Keep existing data and the connect affordance
                            // usable. HealthKit may invoke observers before the
                            // user has granted any read access.
                            break
                        }
                        completion()
                    }
                    return
                }

                Task { @MainActor in
                    await self.sync(
                        descriptor,
                        markGlobalState: false
                    )
                    completion()
                }
            }

            observerQueries.append(query)
            healthStore.execute(query)
        }
    }

    private func enableBackgroundDelivery() async {
        for descriptor in Self.descriptors {
            await withCheckedContinuation { continuation in
                healthStore.enableBackgroundDelivery(
                    for: descriptor.type,
                    frequency: descriptor.backgroundFrequency
                ) { [weak self] success, error in
                    Task { @MainActor in
                        if !success, let error {
                            // Foreground/manual sync still works. Surface this
                            // as a diagnostic rather than discarding access.
                            self?.lastError = (
                                "Health background delivery: "
                                    + error.localizedDescription
                            )
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func syncAll() async {
        state = .syncing

        for descriptor in Self.descriptors {
            await sync(
                descriptor,
                markGlobalState: false
            )
        }

        importedObservationCount = timeline.observations.count
        lastSyncAt = Date()

        do {
            timelineURL = try persistTimeline()
            state = .ready
            if requestedAccessThisInstall {
                requestedAccessThisInstall = false
            }
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func sync(
        _ descriptor: HealthKitSampleDescriptor,
        markGlobalState: Bool
    ) async {
        if markGlobalState {
            state = .syncing
        }

        do {
            let anchor = anchorStore.anchor(
                for: descriptor.anchorKey
            )
            let result = try await executeAnchoredQuery(
                descriptor: descriptor,
                anchor: anchor
            )

            timeline.apply(
                upserts: result.observations,
                deletedIDs: result.deletedIDs,
                at: result.ingestedAt
            )

            if let newAnchor = result.newAnchor {
                anchorStore.set(
                    newAnchor,
                    for: descriptor.anchorKey
                )
            }

            importedObservationCount = timeline.observations.count
            lastSyncAt = result.ingestedAt
            timelineURL = try persistTimeline()

            if markGlobalState {
                state = .ready
            }
        } catch {
            lastError = (
                descriptor.kind?.displayName
                    ?? descriptor.anchorKey
            )
                + ": "
                + error.localizedDescription

            if markGlobalState {
                state = .failed(
                    error.localizedDescription
                )
            }
        }
    }

    private func executeAnchoredQuery(
        descriptor: HealthKitSampleDescriptor,
        anchor: HKQueryAnchor?
    ) async throws -> (
        observations: [BodyStateObservation],
        deletedIDs: Set<String>,
        newAnchor: HKQueryAnchor?,
        ingestedAt: Date
    ) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: descriptor.type,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(
                        throwing: error
                    )
                    return
                }

                // Convert HealthKit objects on HealthKit's callback queue.
                // Only compact Sendable MotionOS observations cross back to
                // the MainActor, avoiding a large first-sync transform there.
                let ingestedAt = Date()
                let observations = (samples ?? []).compactMap {
                    Self.observation(
                        from: $0,
                        descriptor: descriptor,
                        ingestedAt: ingestedAt
                    )
                }
                let deletedIDs = Set(
                    (deleted ?? []).map {
                        $0.uuid.uuidString
                    }
                )

                continuation.resume(
                    returning: (
                        observations,
                        deletedIDs,
                        newAnchor,
                        ingestedAt
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    private func persistTimeline() throws -> URL {
        let directory = try Self.timelineDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent(
            "body-state-timeline.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(timeline).write(
            to: url,
            options: .atomic
        )
        return url
    }

    private static func loadTimeline()
        -> (timeline: BodyStateTimeline, url: URL)? {
        guard let directory = try? timelineDirectory() else {
            return nil
        }

        let url = directory.appendingPathComponent(
            "body-state-timeline.json"
        )
        guard FileManager.default.fileExists(
            atPath: url.path
        ),
        let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let timeline = try? decoder.decode(
            BodyStateTimeline.self,
            from: data
        ) else {
            return nil
        }

        return (timeline, url)
    }

    private static func timelineDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "MotionOSBodyState",
            isDirectory: true
        )
    }

    private static func observation(
        from sample: HKSample,
        descriptor: HealthKitSampleDescriptor,
        ingestedAt: Date
    ) -> BodyStateObservation? {
        let sourceRevision = sample.sourceRevision
        let device = sample.device

        let source = BodyStateSource(
            bundleIdentifier:
                sourceRevision.source.bundleIdentifier,
            name: sourceRevision.source.name,
            version: sourceRevision.version,
            deviceName: device?.name,
            manufacturer: device?.manufacturer,
            model: device?.model,
            hardwareVersion: device?.hardwareVersion,
            softwareVersion: device?.softwareVersion
        )

        if let quantity = sample as? HKQuantitySample,
           let kind = descriptor.kind,
           let unit = descriptor.unit {
            let value = quantity.quantity.doubleValue(
                for: unit.healthKitUnit
            )
            guard value.isFinite else {
                return nil
            }

            return BodyStateObservation(
                id: sample.uuid.uuidString,
                kind: kind,
                startDate: sample.startDate,
                endDate: sample.endDate,
                numericValue: value,
                unit: unit.storageLabel,
                categoryValue: nil,
                provenance: .sourceReported,
                source: source,
                ingestedAt: ingestedAt
            )
        }

        if let sleep = sample as? HKCategorySample,
           descriptor.kind == .sleepStage {
            return BodyStateObservation(
                id: sample.uuid.uuidString,
                kind: .sleepStage,
                startDate: sample.startDate,
                endDate: sample.endDate,
                numericValue: nil,
                unit: nil,
                categoryValue: sleepStageLabel(sleep.value),
                provenance: .sourceReported,
                source: source,
                ingestedAt: ingestedAt
            )
        }

        if let workout = sample as? HKWorkout,
           descriptor.kind == .workout {
            return BodyStateObservation(
                id: sample.uuid.uuidString,
                kind: .workout,
                startDate: sample.startDate,
                endDate: sample.endDate,
                numericValue: workout.duration,
                unit: "s",
                categoryValue:
                    String(workout.workoutActivityType.rawValue),
                provenance: .sourceReported,
                source: source,
                metadata: [
                    "activity_type_raw":
                        String(workout.workoutActivityType.rawValue),
                ],
                ingestedAt: ingestedAt
            )
        }

        return nil
    }

    private static func sleepStageLabel(
        _ rawValue: Int
    ) -> String {
        guard let value = HKCategoryValueSleepAnalysis(
            rawValue: rawValue
        ) else {
            return "unknown:\(rawValue)"
        }

        switch value {
        case .inBed:
            return "inBed"
        case .awake:
            return "awake"
        case .asleepUnspecified:
            return "asleepUnspecified"
        case .asleepCore:
            return "asleepCore"
        case .asleepDeep:
            return "asleepDeep"
        case .asleepREM:
            return "asleepREM"
        @unknown default:
            return "unknown:\(rawValue)"
        }
    }

    private static let descriptors: [HealthKitSampleDescriptor] = {
        var values: [HealthKitSampleDescriptor] = []

        func quantity(
            _ identifier: HKQuantityTypeIdentifier,
            kind: BodyStateKind,
            unit: HealthKitCanonicalUnit,
            frequency: HKUpdateFrequency
        ) {
            guard let type = HKObjectType.quantityType(
                forIdentifier: identifier
            ) else {
                return
            }
            values.append(
                HealthKitSampleDescriptor(
                    anchorKey: identifier.rawValue,
                    kind: kind,
                    type: type,
                    unit: unit,
                    backgroundFrequency: frequency
                )
            )
        }

        quantity(
            .bodyMass,
            kind: .bodyMass,
            unit: .kilogram,
            frequency: .immediate
        )
        quantity(
            .bodyFatPercentage,
            kind: .bodyFatPercentage,
            unit: .percent,
            frequency: .immediate
        )
        quantity(
            .leanBodyMass,
            kind: .leanBodyMass,
            unit: .kilogram,
            frequency: .immediate
        )
        quantity(
            .bodyMassIndex,
            kind: .bodyMassIndex,
            unit: .count,
            frequency: .immediate
        )
        quantity(
            .height,
            kind: .height,
            unit: .meter,
            frequency: .immediate
        )
        quantity(
            .waistCircumference,
            kind: .waistCircumference,
            unit: .meter,
            frequency: .immediate
        )
        quantity(
            .restingHeartRate,
            kind: .restingHeartRate,
            unit: .beatsPerMinute,
            frequency: .hourly
        )
        quantity(
            .heartRateVariabilitySDNN,
            kind: .heartRateVariabilitySDNN,
            unit: .millisecond,
            frequency: .hourly
        )

        if let sleep = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) {
            values.append(
                HealthKitSampleDescriptor(
                    anchorKey:
                        HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                    kind: .sleepStage,
                    type: sleep,
                    unit: nil,
                    backgroundFrequency: .hourly
                )
            )
        }

        values.append(
            HealthKitSampleDescriptor(
                anchorKey: "HKWorkoutType",
                kind: .workout,
                type: HKObjectType.workoutType(),
                unit: nil,
                backgroundFrequency: .hourly
            )
        )

        return values
    }()
}

private struct HealthKitSampleDescriptor {
    let anchorKey: String
    let kind: BodyStateKind?
    let type: HKSampleType
    let unit: HealthKitCanonicalUnit?
    let backgroundFrequency: HKUpdateFrequency
}

private enum HealthKitCanonicalUnit {
    case kilogram
    case percent
    case count
    case meter
    case beatsPerMinute
    case millisecond

    var healthKitUnit: HKUnit {
        switch self {
        case .kilogram:
            return HKUnit.gramUnit(with: .kilo)
        case .percent:
            return HKUnit.percent()
        case .count:
            return HKUnit.count()
        case .meter:
            return HKUnit.meter()
        case .beatsPerMinute:
            return HKUnit.count().unitDivided(
                by: HKUnit.minute()
            )
        case .millisecond:
            return HKUnit.secondUnit(with: .milli)
        }
    }

    var storageLabel: String {
        switch self {
        case .kilogram:
            return "kg"
        case .percent:
            // HealthKit percent values are fractions in [0, 1].
            return "fraction"
        case .count:
            return "count"
        case .meter:
            return "m"
        case .beatsPerMinute:
            return "bpm"
        case .millisecond:
            return "ms"
        }
    }
}

private final class HealthKitAnchorStore {
    private let defaults: UserDefaults
    private let prefix = "motionos.healthkit.anchor.v1."

    init(
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
    }

    func anchor(
        for key: String
    ) -> HKQueryAnchor? {
        guard let data = defaults.data(
            forKey: prefix + key
        ) else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        )
    }

    func set(
        _ anchor: HKQueryAnchor,
        for key: String
    ) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        ) else {
            return
        }
        defaults.set(
            data,
            forKey: prefix + key
        )
    }
}
