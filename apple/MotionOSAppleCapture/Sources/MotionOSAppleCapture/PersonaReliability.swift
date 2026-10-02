import Foundation

public struct PersonaMetricReliability: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        dimension.rawValue + "|" + metricID + "|" + contextKey + "|" + unit
    }

    public let dimension: FitnessPersonaDimension
    public let metricID: String
    public let label: String
    public let unit: String
    public let contextKey: String
    public let sampleCount: Int
    public let sourceSessionCount: Int
    public let median: Double
    public let medianAbsoluteDeviation: Double
    public let minimum: Double
    public let maximum: Double
    public let latestValue: Double
    public let latestObservedAt: Date
    public let latestDeltaFromMedian: Double
    public let spanDays: Double
    public let maximumSameDayRepeatCount: Int
    public let relativeMADFraction: Double?
    public let provenance: [PersonaEvidenceProvenance]

    public init(
        dimension: FitnessPersonaDimension,
        metricID: String,
        label: String,
        unit: String,
        contextKey: String,
        sampleCount: Int,
        sourceSessionCount: Int,
        median: Double,
        medianAbsoluteDeviation: Double,
        minimum: Double,
        maximum: Double,
        latestValue: Double,
        latestObservedAt: Date,
        latestDeltaFromMedian: Double,
        spanDays: Double,
        maximumSameDayRepeatCount: Int,
        relativeMADFraction: Double?,
        provenance: [PersonaEvidenceProvenance]
    ) {
        self.dimension = dimension
        self.metricID = metricID
        self.label = label
        self.unit = unit
        self.contextKey = contextKey
        self.sampleCount = sampleCount
        self.sourceSessionCount = sourceSessionCount
        self.median = median
        self.medianAbsoluteDeviation = medianAbsoluteDeviation
        self.minimum = minimum
        self.maximum = maximum
        self.latestValue = latestValue
        self.latestObservedAt = latestObservedAt
        self.latestDeltaFromMedian = latestDeltaFromMedian
        self.spanDays = spanDays
        self.maximumSameDayRepeatCount = maximumSameDayRepeatCount
        self.relativeMADFraction = relativeMADFraction
        self.provenance = provenance
    }

    public var coverage: PersonaEvidenceCoverage {
        PersonaEvidenceCoverage.from(
            sessionCount: sourceSessionCount
        )
    }
}

public struct PersonaReliabilitySnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion =
        "motionos.persona-reliability.v1"

    public let schemaVersion: String
    public let generatedAt: Date
    public let contributingSessionCount: Int
    public let series: [PersonaMetricReliability]
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        generatedAt: Date,
        contributingSessionCount: Int,
        series: [PersonaMetricReliability]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.contributingSessionCount = contributingSessionCount
        self.series = series
        self.claimBoundary = (
            "Repeatability describes how tightly repeated comparable MotionOS "
                + "observations cluster. It is not measurement accuracy, sensor "
                + "validation, biological stability, medical certainty, or a "
                + "performance score."
        )
    }

    public var repeatedSeriesCount: Int {
        series.filter {
            $0.sourceSessionCount >= 2
        }.count
    }

    public var sameDayTriplicateSeriesCount: Int {
        series.filter {
            $0.maximumSameDayRepeatCount >= 3
        }.count
    }
}

public enum PersonaReliabilityEngine {
    public static func build(
        evidence: [PersonaSessionEvidence],
        generatedAt: Date = Date()
    ) -> PersonaReliabilitySnapshot {
        let completed =
            deduplicatedCompletedEvidence(
                evidence
            )
        var groups: [MetricKey: [PersonaMetricObservation]] = [:]

        for session in completed {
            for metric in session.metrics
            where metric.value.isFinite {
                let key = MetricKey(
                    dimension: metric.dimension,
                    metricID: metric.metricID,
                    unit: metric.unit,
                    contextKey: metric.contextKey
                )
                groups[key, default: []].append(
                    metric
                )
            }
        }

        let series = groups.values.compactMap {
            makeSeries($0)
        }
        .sorted {
            if $0.sourceSessionCount
                != $1.sourceSessionCount {
                return $0.sourceSessionCount
                    > $1.sourceSessionCount
            }
            if $0.latestObservedAt
                != $1.latestObservedAt {
                return $0.latestObservedAt
                    > $1.latestObservedAt
            }
            return $0.label < $1.label
        }

        let contributingSessionCount = Set(
            completed
                .filter { !$0.metrics.isEmpty }
                .map { $0.id }
        ).count

        return PersonaReliabilitySnapshot(
            generatedAt: generatedAt,
            contributingSessionCount:
                contributingSessionCount,
            series: series
        )
    }

    private static func makeSeries(
        _ observations: [PersonaMetricObservation]
    ) -> PersonaMetricReliability? {
        let valid = observations
            .filter { $0.value.isFinite }
            .sorted {
                if $0.observedAt != $1.observedAt {
                    return $0.observedAt
                        < $1.observedAt
                }
                return $0.sourceSessionID
                    < $1.sourceSessionID
            }

        guard let first = valid.first,
              let latest = valid.last
        else {
            return nil
        }

        let values = valid.map { $0.value }
        let center = median(values)
        let mad = median(
            values.map {
                abs($0 - center)
            }
        )

        let sourceSessionCount = Set(
            valid.map { $0.sourceSessionID }
        ).count

        let minimum = values.min() ?? center
        let maximum = values.max() ?? center

        let spanDays: Double
        if let earliest = valid.first?.observedAt {
            spanDays = max(
                0,
                latest.observedAt
                    .timeIntervalSince(earliest)
                    / 86_400
            )
        } else {
            spanDays = 0
        }

        let relativeMADFraction: Double?
        if abs(center) > 1e-9 {
            relativeMADFraction =
                mad / abs(center)
        } else {
            relativeMADFraction = nil
        }

        let provenance = Set(
            valid.map { $0.provenance }
        )
        .sorted {
            $0.rawValue < $1.rawValue
        }

        return PersonaMetricReliability(
            dimension: first.dimension,
            metricID: first.metricID,
            label: first.label,
            unit: first.unit,
            contextKey: first.contextKey,
            sampleCount: valid.count,
            sourceSessionCount:
                sourceSessionCount,
            median: center,
            medianAbsoluteDeviation: mad,
            minimum: minimum,
            maximum: maximum,
            latestValue: latest.value,
            latestObservedAt:
                latest.observedAt,
            latestDeltaFromMedian:
                latest.value - center,
            spanDays: spanDays,
            maximumSameDayRepeatCount:
                maximumSameDayRepeatCount(valid),
            relativeMADFraction:
                relativeMADFraction,
            provenance: provenance
        )
    }

    private static func maximumSameDayRepeatCount(
        _ observations: [PersonaMetricObservation]
    ) -> Int {
        var calendar = Calendar(
            identifier: .gregorian
        )
        if let utc = TimeZone(
            secondsFromGMT: 0
        ) {
            calendar.timeZone = utc
        }

        var sessionsByDay:
            [DateComponents: Set<String>] = [:]

        for observation in observations {
            let day = calendar.dateComponents(
                [.year, .month, .day],
                from: observation.observedAt
            )
            sessionsByDay[
                day,
                default: []
            ].insert(
                observation.sourceSessionID
            )
        }

        return sessionsByDay.values
            .map { $0.count }
            .max() ?? 0
    }

    private static func deduplicatedCompletedEvidence(
        _ evidence: [PersonaSessionEvidence]
    ) -> [PersonaSessionEvidence] {
        var byID:
            [String: PersonaSessionEvidence] = [:]

        for item in evidence
        where item.completed
            && !item.id.isEmpty {
            if let existing = byID[item.id],
               existing.observedAt
                >= item.observedAt {
                continue
            }
            byID[item.id] = item
        }

        return byID.values.sorted {
            $0.observedAt < $1.observedAt
        }
    }

    private static func median(
        _ values: [Double]
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return 0
        }

        let middle = sorted.count / 2
        if sorted.count.isMultiple(
            of: 2
        ) {
            return (
                sorted[middle - 1]
                    + sorted[middle]
            ) / 2
        }
        return sorted[middle]
    }

    private struct MetricKey: Hashable {
        let dimension:
            FitnessPersonaDimension
        let metricID: String
        let unit: String
        let contextKey: String
    }
}

public enum PersonaReliabilityStore {
    public static func write(
        _ snapshot: PersonaReliabilitySnapshot,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        encoder.dateEncodingStrategy =
            .iso8601
        try encoder.encode(snapshot).write(
            to: url,
            options: .atomic
        )
    }

    public static func load(
        from url: URL
    ) throws -> PersonaReliabilitySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy =
            .iso8601
        return try decoder.decode(
            PersonaReliabilitySnapshot.self,
            from: Data(contentsOf: url)
        )
    }
}
