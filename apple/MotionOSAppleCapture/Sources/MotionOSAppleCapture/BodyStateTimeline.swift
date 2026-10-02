import Foundation

public enum BodyStateKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case bodyMassIndex = "body_mass_index"
    case height
    case waistCircumference = "waist_circumference"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariabilitySDNN = "heart_rate_variability_sdnn"
    case sleepStage = "sleep_stage"
    case workout = "workout"

    public var displayName: String {
        switch self {
        case .bodyMass:
            return "Body mass"
        case .bodyFatPercentage:
            return "Body fat"
        case .leanBodyMass:
            return "Lean body mass"
        case .bodyMassIndex:
            return "BMI"
        case .height:
            return "Height"
        case .waistCircumference:
            return "Waist"
        case .restingHeartRate:
            return "Resting heart rate"
        case .heartRateVariabilitySDNN:
            return "HRV (SDNN)"
        case .sleepStage:
            return "Sleep"
        case .workout:
            return "Workout"
        }
    }
}

public enum BodyStateProvenance: String, Codable, Sendable, Equatable, Hashable {
    /// A value reported by an external source. MotionOS does not infer whether
    /// a source-reported body-composition number was directly measured or
    /// estimated by that source.
    case sourceReported = "source_reported"
    case userReported = "user_reported"
    case derived
    case modelEstimated = "model_estimated"
}

public struct BodyStateSource: Codable, Sendable, Equatable, Hashable {
    public let bundleIdentifier: String?
    public let name: String?
    public let version: String?
    public let deviceName: String?
    public let manufacturer: String?
    public let model: String?
    public let hardwareVersion: String?
    public let softwareVersion: String?

    public init(
        bundleIdentifier: String?,
        name: String?,
        version: String?,
        deviceName: String?,
        manufacturer: String?,
        model: String?,
        hardwareVersion: String?,
        softwareVersion: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.deviceName = deviceName
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
    }
}

public struct BodyStateObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: BodyStateKind
    public let startDate: Date
    public let endDate: Date
    public let numericValue: Double?
    public let unit: String?
    public let categoryValue: String?
    public let provenance: BodyStateProvenance
    public let source: BodyStateSource
    public let metadata: [String: String]
    public let ingestedAt: Date

    public init(
        id: String,
        kind: BodyStateKind,
        startDate: Date,
        endDate: Date,
        numericValue: Double?,
        unit: String?,
        categoryValue: String?,
        provenance: BodyStateProvenance,
        source: BodyStateSource,
        metadata: [String: String] = [:],
        ingestedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.numericValue = numericValue
        self.unit = unit
        self.categoryValue = categoryValue
        self.provenance = provenance
        self.source = source
        self.metadata = metadata
        self.ingestedAt = ingestedAt
    }

    public var isValid: Bool {
        guard !id.isEmpty,
              endDate >= startDate
        else {
            return false
        }

        if let numericValue {
            return numericValue.isFinite
        }

        return categoryValue != nil
    }
}

public struct BodyStateTimeline: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.body-state-timeline.v1"

    public let schemaVersion: String
    public private(set) var observations: [BodyStateObservation]
    public private(set) var lastUpdatedAt: Date?

    public init(
        schemaVersion: String = Self.schemaVersion,
        observations: [BodyStateObservation] = [],
        lastUpdatedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.observations = observations
        self.lastUpdatedAt = lastUpdatedAt
    }

    public mutating func apply(
        upserts: [BodyStateObservation],
        deletedIDs: Set<String> = [],
        at date: Date = Date()
    ) {
        var byID = Dictionary(
            uniqueKeysWithValues: observations.map { ($0.id, $0) }
        )

        for id in deletedIDs {
            byID.removeValue(forKey: id)
        }

        for observation in upserts where observation.isValid {
            byID[observation.id] = observation
        }

        observations = byID.values.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.id < $1.id
        }
        lastUpdatedAt = date
    }

    public func latest(
        _ kind: BodyStateKind,
        at date: Date = Date()
    ) -> BodyStateObservation? {
        observations
            .filter {
                $0.kind == kind
                    && $0.startDate <= date
            }
            .max {
                if $0.startDate != $1.startDate {
                    return $0.startDate < $1.startDate
                }
                return $0.ingestedAt < $1.ingestedAt
            }
    }

    public func values(
        _ kind: BodyStateKind,
        from start: Date? = nil,
        through end: Date? = nil
    ) -> [BodyStateObservation] {
        observations.filter { observation in
            guard observation.kind == kind else {
                return false
            }
            if let start, observation.endDate < start {
                return false
            }
            if let end, observation.startDate > end {
                return false
            }
            return true
        }
    }

    public func sourceNames(
        for kind: BodyStateKind
    ) -> [String] {
        Set(
            observations
                .filter { $0.kind == kind }
                .compactMap { $0.source.name ?? $0.source.bundleIdentifier }
        )
        .sorted()
    }

    public func sleepDuration(
        from start: Date,
        through end: Date
    ) -> TimeInterval {
        guard end > start else { return 0 }

        // Sleep can be written by multiple apps/devices. Summing samples
        // directly can double-count overlapping stages from different sources.
        // Use the union of all source-reported asleep intervals instead.
        let intervals = values(
            .sleepStage,
            from: start,
            through: end
        )
        .compactMap { observation -> (Date, Date)? in
            guard let stage = observation.categoryValue,
                  [
                    "asleep",
                    "asleepCore",
                    "asleepDeep",
                    "asleepREM",
                    "asleepUnspecified",
                  ].contains(stage)
            else {
                return nil
            }

            let clippedStart = max(start, observation.startDate)
            let clippedEnd = min(end, observation.endDate)
            guard clippedEnd > clippedStart else {
                return nil
            }
            return (clippedStart, clippedEnd)
        }
        .sorted { lhs, rhs in
            lhs.0 < rhs.0
        }

        guard let first = intervals.first else {
            return 0
        }

        var total: TimeInterval = 0
        var currentStart = first.0
        var currentEnd = first.1

        for interval in intervals.dropFirst() {
            if interval.0 <= currentEnd {
                currentEnd = max(
                    currentEnd,
                    interval.1
                )
            } else {
                total += currentEnd.timeIntervalSince(
                    currentStart
                )
                currentStart = interval.0
                currentEnd = interval.1
            }
        }

        total += currentEnd.timeIntervalSince(
            currentStart
        )
        return total
    }
}

public struct BodyStateContextSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.body-state-context.v1"

    public let schemaVersion: String
    public let capturedAt: Date
    public let latestBodyMass: BodyStateObservation?
    public let latestBodyFatPercentage: BodyStateObservation?
    public let latestLeanBodyMass: BodyStateObservation?
    public let latestRestingHeartRate: BodyStateObservation?
    public let latestHRV: BodyStateObservation?
    public let prior24HourSleepSeconds: TimeInterval
    public let sourceObservationIDs: [String]
    public let claimBoundary: String

    public init(
        capturedAt: Date,
        timeline: BodyStateTimeline
    ) {
        self.schemaVersion = Self.schemaVersion
        self.capturedAt = capturedAt
        self.latestBodyMass = timeline.latest(.bodyMass, at: capturedAt)
        self.latestBodyFatPercentage =
            timeline.latest(.bodyFatPercentage, at: capturedAt)
        self.latestLeanBodyMass =
            timeline.latest(.leanBodyMass, at: capturedAt)
        self.latestRestingHeartRate =
            timeline.latest(.restingHeartRate, at: capturedAt)
        self.latestHRV =
            timeline.latest(.heartRateVariabilitySDNN, at: capturedAt)

        let sleepStart = capturedAt.addingTimeInterval(-24 * 60 * 60)
        self.prior24HourSleepSeconds = timeline.sleepDuration(
            from: sleepStart,
            through: capturedAt
        )

        let observations: [BodyStateObservation?] = [
            latestBodyMass,
            latestBodyFatPercentage,
            latestLeanBodyMass,
            latestRestingHeartRate,
            latestHRV,
        ]
        self.sourceObservationIDs = observations.compactMap { $0?.id }

        self.claimBoundary = (
            "Body-state context contains source-reported longitudinal "
                + "observations. MotionOS does not treat smart-scale body "
                + "composition, sleep, HRV, or resting heart rate as diagnosis, "
                + "readiness, or causal explanations for session performance."
        )
    }
}


public enum BodyStateContextStore {
    public static let filename = "body-state-context.json"

    @discardableResult
    public static func write(
        _ snapshot: BodyStateContextSnapshot,
        to runDirectory: URL
    ) throws -> URL {
        let url = runDirectory.appendingPathComponent(
            filename
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: url,
            options: .atomic
        )
        return url
    }

    public static func load(
        from url: URL
    ) throws -> BodyStateContextSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            BodyStateContextSnapshot.self,
            from: Data(contentsOf: url)
        )
    }
}
