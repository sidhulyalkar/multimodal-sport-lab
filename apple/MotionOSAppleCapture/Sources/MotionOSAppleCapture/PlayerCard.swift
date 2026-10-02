import Foundation

public struct PlayerCardDimensionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { dimension.rawValue }

    public let dimension: FitnessPersonaDimension
    public let coverage: PersonaEvidenceCoverage
    public let evidenceSessionCount: Int
    public let latestObservedAt: Date?

    public init(
        dimension: FitnessPersonaDimension,
        coverage: PersonaEvidenceCoverage,
        evidenceSessionCount: Int,
        latestObservedAt: Date?
    ) {
        self.dimension = dimension
        self.coverage = coverage
        self.evidenceSessionCount = evidenceSessionCount
        self.latestObservedAt = latestObservedAt
    }
}

public struct PlayerCardHighlight: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        dimension.rawValue + "|" + metricID
    }

    public let dimension: FitnessPersonaDimension
    public let metricID: String
    public let label: String
    public let unit: String
    public let value: Double
    public let observedAt: Date
    public let sampleCount: Int

    public init(
        dimension: FitnessPersonaDimension,
        metricID: String,
        label: String,
        unit: String,
        value: Double,
        observedAt: Date,
        sampleCount: Int
    ) {
        self.dimension = dimension
        self.metricID = metricID
        self.label = label
        self.unit = unit
        self.value = value
        self.observedAt = observedAt
        self.sampleCount = sampleCount
    }
}

public struct PlayerCardSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.player-card.v1"

    public let schemaVersion: String
    public let generatedAt: Date
    /// Conservative evidence depth derived only from share-safe dimensions.
    /// It is the maximum comparable-session count across Movement/Power/Mobility,
    /// not the total number of private Persona sessions.
    public let shareableEvidenceDepth: Int
    public let bodyModelCalibrated: Bool
    public let dimensions: [PlayerCardDimensionSummary]
    public let highlights: [PlayerCardHighlight]
    public let privacyBoundary: String
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        generatedAt: Date,
        shareableEvidenceDepth: Int,
        bodyModelCalibrated: Bool,
        dimensions: [PlayerCardDimensionSummary],
        highlights: [PlayerCardHighlight]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.shareableEvidenceDepth = shareableEvidenceDepth
        self.bodyModelCalibrated = bodyModelCalibrated
        self.dimensions = dimensions
        self.highlights = highlights
        self.privacyBoundary = (
            "Player Card v1 intentionally excludes HealthKit values, body "
                + "measurements, recovery values, cardiovascular metrics, "
                + "sleep, HRV, body composition, and raw sensor evidence."
        )
        self.claimBoundary = (
            "The card summarizes descriptive MotionOS movement evidence and "
                + "coverage. It is not a fitness score, medical assessment, "
                + "skill ranking, or claim that any displayed direction is better."
        )
    }
}

public enum PlayerCardEngine {
    /// The first share-card schema is intentionally performance/movement-only.
    /// Health and body-state dimensions can remain useful inside MotionOS
    /// without becoming social-share defaults.
    public static let shareableDimensions: [FitnessPersonaDimension] = [
        .movement,
        .power,
        .mobility,
    ]

    public static func build(
        from persona: FitnessPersonaSnapshot,
        generatedAt: Date = Date()
    ) -> PlayerCardSnapshot {
        let dimensionStates = shareableDimensions.map { dimension in
            let state = persona.state(for: dimension)
            return PlayerCardDimensionSummary(
                dimension: dimension,
                coverage: state?.coverage ?? .none,
                evidenceSessionCount:
                    state?.evidenceSessionCount ?? 0,
                latestObservedAt:
                    state?.latestObservedAt
            )
        }

        let highlights = shareableDimensions.compactMap { dimension in
            guard let state = persona.state(for: dimension) else {
                return nil
            }

            let baseline = state.baselines
                .filter {
                    $0.latestValue.isFinite
                }
                .sorted {
                    if $0.latestObservedAt != $1.latestObservedAt {
                        return $0.latestObservedAt > $1.latestObservedAt
                    }
                    if $0.sampleCount != $1.sampleCount {
                        return $0.sampleCount > $1.sampleCount
                    }
                    return $0.metricID < $1.metricID
                }
                .first

            guard let baseline else { return nil }

            return PlayerCardHighlight(
                dimension: dimension,
                metricID: baseline.metricID,
                label: baseline.label,
                unit: baseline.unit,
                value: baseline.latestValue,
                observedAt: baseline.latestObservedAt,
                sampleCount: baseline.sampleCount
            )
        }

        let shareableEvidenceDepth =
            dimensionStates.map(\.evidenceSessionCount).max() ?? 0

        return PlayerCardSnapshot(
            generatedAt: generatedAt,
            shareableEvidenceDepth: shareableEvidenceDepth,
            bodyModelCalibrated:
                persona.bodyModelVersion != nil,
            dimensions: dimensionStates,
            highlights: highlights
        )
    }
}

public enum PlayerCardStore {
    public static func write(
        _ snapshot: PlayerCardSnapshot,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: url,
            options: .atomic
        )
    }

    public static func load(
        from url: URL
    ) throws -> PlayerCardSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PlayerCardSnapshot.self,
            from: Data(contentsOf: url)
        )
    }
}
