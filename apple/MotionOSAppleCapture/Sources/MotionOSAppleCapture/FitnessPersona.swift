import Foundation

public enum FitnessPersonaDimension: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case movement
    case cardiovascularResponse = "cardiovascular_response"
    case power
    case mobility
    case recovery
    case body

    public var displayName: String {
        switch self {
        case .movement:
            return "Movement"
        case .cardiovascularResponse:
            return "Cardio response"
        case .power:
            return "Power"
        case .mobility:
            return "Mobility"
        case .recovery:
            return "Recovery"
        case .body:
            return "Body"
        }
    }
}

public enum PersonaEvidenceProvenance: String, Codable, Sendable, Equatable, Hashable {
    case measured
    case derived
    case selfReported = "self_reported"
    case modelEstimated = "model_estimated"
}

public enum PersonaEvidenceSource: String, Codable, Sendable, Equatable, Hashable {
    case appleWatch = "apple_watch"
    case iPhoneVision = "iphone_vision"
    case iPhoneCamera = "iphone_camera"
    case equipment
    case healthKit = "healthkit"
    case user
}

public enum PersonaEvidenceCoverage: String, Codable, Sendable, Equatable, Hashable {
    case none
    case singleSession = "single_session"
    case repeated
    case longitudinal

    public static func from(sessionCount: Int) -> Self {
        switch sessionCount {
        case 0:
            return .none
        case 1:
            return .singleSession
        case 2...4:
            return .repeated
        default:
            return .longitudinal
        }
    }

    public var displayName: String {
        switch self {
        case .none:
            return "Not measured"
        case .singleSession:
            return "1 session"
        case .repeated:
            return "Repeated"
        case .longitudinal:
            return "Longitudinal"
        }
    }
}

public struct PersonaMetricObservation: Codable, Sendable, Equatable {
    public let dimension: FitnessPersonaDimension
    public let metricID: String
    public let label: String
    public let unit: String
    public let value: Double
    public let observedAt: Date
    public let contextKey: String
    public let provenance: PersonaEvidenceProvenance
    public let sourceSessionID: String

    public init(
        dimension: FitnessPersonaDimension,
        metricID: String,
        label: String,
        unit: String,
        value: Double,
        observedAt: Date,
        contextKey: String,
        provenance: PersonaEvidenceProvenance,
        sourceSessionID: String
    ) {
        self.dimension = dimension
        self.metricID = metricID
        self.label = label
        self.unit = unit
        self.value = value
        self.observedAt = observedAt
        self.contextKey = contextKey
        self.provenance = provenance
        self.sourceSessionID = sourceSessionID
    }
}

public struct PersonaSessionEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sport: String
    public let protocolID: String
    public let captureMode: String
    public let observedAt: Date
    public let completed: Bool
    public let sources: [PersonaEvidenceSource]
    public let metrics: [PersonaMetricObservation]

    public init(
        id: String,
        sport: String,
        protocolID: String,
        captureMode: String,
        observedAt: Date,
        completed: Bool,
        sources: [PersonaEvidenceSource],
        metrics: [PersonaMetricObservation]
    ) {
        self.id = id
        self.sport = sport
        self.protocolID = protocolID
        self.captureMode = captureMode
        self.observedAt = observedAt
        self.completed = completed
        self.sources = Array(Set(sources)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.metrics = metrics
    }

    public var comparisonContextKey: String {
        [
            sport,
            protocolID,
            captureMode,
        ].joined(separator: "|")
    }
}

public struct PersonaMetricBaseline: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        metricID + "|" + contextKey
    }

    public let metricID: String
    public let label: String
    public let unit: String
    public let dimension: FitnessPersonaDimension
    public let contextKey: String
    public let sampleCount: Int
    public let median: Double
    public let medianAbsoluteDeviation: Double?
    public let latestValue: Double
    public let latestObservedAt: Date
    public let latestDeltaFromMedian: Double
    public let trendPer30Days: Double?
    public let provenance: [PersonaEvidenceProvenance]

    public init(
        metricID: String,
        label: String,
        unit: String,
        dimension: FitnessPersonaDimension,
        contextKey: String,
        sampleCount: Int,
        median: Double,
        medianAbsoluteDeviation: Double?,
        latestValue: Double,
        latestObservedAt: Date,
        latestDeltaFromMedian: Double,
        trendPer30Days: Double?,
        provenance: [PersonaEvidenceProvenance]
    ) {
        self.metricID = metricID
        self.label = label
        self.unit = unit
        self.dimension = dimension
        self.contextKey = contextKey
        self.sampleCount = sampleCount
        self.median = median
        self.medianAbsoluteDeviation = medianAbsoluteDeviation
        self.latestValue = latestValue
        self.latestObservedAt = latestObservedAt
        self.latestDeltaFromMedian = latestDeltaFromMedian
        self.trendPer30Days = trendPer30Days
        self.provenance = provenance
    }
}

public struct FitnessPersonaDimensionState: Codable, Sendable, Equatable, Identifiable {
    public var id: String { dimension.rawValue }

    public let dimension: FitnessPersonaDimension
    public let coverage: PersonaEvidenceCoverage
    public let evidenceSessionCount: Int
    public let latestObservedAt: Date?
    public let sourceKinds: [PersonaEvidenceSource]
    public let baselines: [PersonaMetricBaseline]

    public init(
        dimension: FitnessPersonaDimension,
        coverage: PersonaEvidenceCoverage,
        evidenceSessionCount: Int,
        latestObservedAt: Date?,
        sourceKinds: [PersonaEvidenceSource],
        baselines: [PersonaMetricBaseline]
    ) {
        self.dimension = dimension
        self.coverage = coverage
        self.evidenceSessionCount = evidenceSessionCount
        self.latestObservedAt = latestObservedAt
        self.sourceKinds = sourceKinds
        self.baselines = baselines
    }
}

public struct FitnessPersonaSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.fitness-persona.v0"

    public let schemaVersion: String
    public let generatedAt: Date
    public let sourceSessionCount: Int
    public let bodyModelVersion: String?
    public let dimensions: [FitnessPersonaDimensionState]
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        generatedAt: Date,
        sourceSessionCount: Int,
        bodyModelVersion: String?,
        dimensions: [FitnessPersonaDimensionState]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceSessionCount = sourceSessionCount
        self.bodyModelVersion = bodyModelVersion
        self.dimensions = dimensions
        self.claimBoundary = (
            "Fitness Persona v0 summarizes repeated MotionOS evidence. "
                + "Coverage describes how much comparable evidence exists, not "
                + "how skilled or healthy a person is. Metric trends are "
                + "descriptive and are not medical, biomechanical, or "
                + "performance diagnoses."
        )
    }

    public var measuredDimensionCount: Int {
        dimensions.filter {
            $0.coverage != .none
        }.count
    }

    public var longitudinalDimensionCount: Int {
        dimensions.filter {
            $0.coverage == .longitudinal
        }.count
    }

    public func state(
        for dimension: FitnessPersonaDimension
    ) -> FitnessPersonaDimensionState? {
        dimensions.first { $0.dimension == dimension }
    }
}

public enum FitnessPersonaEngine {
    public static func build(
        evidence: [PersonaSessionEvidence],
        bodyModelVersion: String? = nil,
        generatedAt: Date = Date()
    ) -> FitnessPersonaSnapshot {
        let completed = deduplicatedCompletedEvidence(evidence)

        let dimensions = FitnessPersonaDimension.allCases.map { dimension in
            buildDimensionState(
                dimension,
                evidence: completed
            )
        }

        return FitnessPersonaSnapshot(
            generatedAt: generatedAt,
            sourceSessionCount: completed.count,
            bodyModelVersion: bodyModelVersion,
            dimensions: dimensions
        )
    }

    private static func deduplicatedCompletedEvidence(
        _ evidence: [PersonaSessionEvidence]
    ) -> [PersonaSessionEvidence] {
        var byID: [String: PersonaSessionEvidence] = [:]

        for item in evidence where item.completed {
            guard !item.id.isEmpty else { continue }

            if let existing = byID[item.id],
               existing.observedAt >= item.observedAt {
                continue
            }
            byID[item.id] = item
        }

        return byID.values.sorted {
            $0.observedAt < $1.observedAt
        }
    }

    private static func buildDimensionState(
        _ dimension: FitnessPersonaDimension,
        evidence: [PersonaSessionEvidence]
    ) -> FitnessPersonaDimensionState {
        let relevant = evidence.filter { session in
            session.metrics.contains { metric in
                metric.dimension == dimension
                    && metric.value.isFinite
            }
        }

        let sessionIDs = Set(relevant.map(\.id))
        let latest = relevant.map(\.observedAt).max()
        let sources = Set(
            relevant.flatMap(\.sources)
        )
        .sorted { $0.rawValue < $1.rawValue }

        var groups: [MetricContextKey: [PersonaMetricObservation]] = [:]

        for session in relevant {
            for metric in session.metrics
            where metric.dimension == dimension
                && metric.value.isFinite {
                let key = MetricContextKey(
                    metricID: metric.metricID,
                    contextKey: metric.contextKey
                )
                groups[key, default: []].append(metric)
            }
        }

        let baselines = groups.values.compactMap {
            makeBaseline($0)
        }
        .sorted {
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            if $0.latestObservedAt != $1.latestObservedAt {
                return $0.latestObservedAt > $1.latestObservedAt
            }
            return $0.label < $1.label
        }

        return FitnessPersonaDimensionState(
            dimension: dimension,
            coverage: .from(sessionCount: sessionIDs.count),
            evidenceSessionCount: sessionIDs.count,
            latestObservedAt: latest,
            sourceKinds: sources,
            baselines: baselines
        )
    }

    private static func makeBaseline(
        _ observations: [PersonaMetricObservation]
    ) -> PersonaMetricBaseline? {
        let valid = observations
            .filter { $0.value.isFinite }
            .sorted { $0.observedAt < $1.observedAt }

        guard let first = valid.first,
              let latest = valid.last
        else {
            return nil
        }

        let values = valid.map(\.value)
        let center = median(values)
        let mad: Double?
        if values.count >= 2 {
            mad = median(
                values.map {
                    abs($0 - center)
                }
            )
        } else {
            mad = nil
        }

        let provenance = Set(valid.map(\.provenance))
            .sorted { $0.rawValue < $1.rawValue }

        return PersonaMetricBaseline(
            metricID: first.metricID,
            label: first.label,
            unit: first.unit,
            dimension: first.dimension,
            contextKey: first.contextKey,
            sampleCount: valid.count,
            median: center,
            medianAbsoluteDeviation: mad,
            latestValue: latest.value,
            latestObservedAt: latest.observedAt,
            latestDeltaFromMedian: latest.value - center,
            trendPer30Days: robustTrendPer30Days(valid),
            provenance: provenance
        )
    }

    private static func median(
        _ values: [Double]
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }

        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (
                sorted[middle - 1]
                    + sorted[middle]
            ) / 2
        }
        return sorted[middle]
    }

    /// Theil-Sen style median pairwise slope. This is a descriptive trend,
    /// not an improvement score. The value is expressed per 30 days.
    private static func robustTrendPer30Days(
        _ observations: [PersonaMetricObservation]
    ) -> Double? {
        guard observations.count >= 3 else {
            return nil
        }

        var slopes: [Double] = []
        for i in observations.indices {
            for j in observations.indices where j > i {
                let days = observations[j].observedAt
                    .timeIntervalSince(observations[i].observedAt)
                    / 86_400
                guard days > 0 else { continue }
                slopes.append(
                    (
                        observations[j].value
                            - observations[i].value
                    ) / days * 30
                )
            }
        }

        guard !slopes.isEmpty else {
            return nil
        }
        return median(slopes)
    }

    private struct MetricContextKey: Hashable {
        let metricID: String
        let contextKey: String
    }
}
