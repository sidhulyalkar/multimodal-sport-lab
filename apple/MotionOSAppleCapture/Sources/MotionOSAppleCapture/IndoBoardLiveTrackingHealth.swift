import Foundation

public struct IndoBoardLiveTrackingHealth:
    Equatable,
    Sendable {
    public let sampleCount: Int
    public let trackedSampleCount: Int
    public let coverageFraction: Double
    public let meanConfidence: Double

    public init(
        sampleCount: Int,
        trackedSampleCount: Int,
        coverageFraction: Double,
        meanConfidence: Double
    ) {
        self.sampleCount = max(0, sampleCount)
        self.trackedSampleCount = max(0, trackedSampleCount)
        self.coverageFraction = min(
            1,
            max(0, coverageFraction)
        )
        self.meanConfidence = min(
            1,
            max(0, meanConfidence)
        )
    }

    public static let empty =
        IndoBoardLiveTrackingHealth(
            sampleCount: 0,
            trackedSampleCount: 0,
            coverageFraction: 0,
            meanConfidence: 0
        )

    public var isStable: Bool {
        sampleCount >= 8
            && coverageFraction
                >= IndoBoardEvidenceQualityThresholds
                    .minimumBlockCoverage
            && meanConfidence
                >= IndoBoardEvidenceQualityThresholds
                    .minimumStateConfidence
    }
}

@MainActor
public final class IndoBoardLiveTrackingWindow {
    private struct Sample: Sendable {
        let confidence: Double?
    }

    private let capacity: Int
    private var samples: [Sample] = []

    public init(capacity: Int = 30) {
        self.capacity = max(8, capacity)
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public func ingest(
        _ state: IndoBoardBalanceState?
    ) -> IndoBoardLiveTrackingHealth {
        let confidence = state?.confidence
        samples.append(
            Sample(
                confidence: confidence
            )
        )
        if samples.count > capacity {
            samples.removeFirst(
                samples.count - capacity
            )
        }
        return makeHealth()
    }

    public func makeHealth()
        -> IndoBoardLiveTrackingHealth {
        guard !samples.isEmpty else {
            return .empty
        }

        let tracked = samples.compactMap {
            $0.confidence
        }
        let coverage =
            Double(tracked.count)
                / Double(samples.count)
        let meanConfidence =
            tracked.isEmpty
                ? 0
                : tracked.reduce(0, +)
                    / Double(tracked.count)

        return IndoBoardLiveTrackingHealth(
            sampleCount: samples.count,
            trackedSampleCount: tracked.count,
            coverageFraction: coverage,
            meanConfidence: meanConfidence
        )
    }
}
