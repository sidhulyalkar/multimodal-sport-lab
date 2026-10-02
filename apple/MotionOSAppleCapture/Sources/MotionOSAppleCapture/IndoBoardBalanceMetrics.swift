import Foundation

public struct IndoBoardBalanceMetrics:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.indo-balance-metrics.v1"

    public let schemaVersion: String
    public let sampleCount: Int
    public let meanConfidence: Double
    public let centerTimeFraction: Double
    public let rollerExcursionP90: Double
    public let edgeApproachCount: Int
    public let directionChangeCount: Int
    public let recoveryCount: Int
    public let meanRecoveryTimeMS: Double?
    public let p90RecoveryTimeMS: Double?
    public let claimBoundary: String

    public init(
        sampleCount: Int,
        meanConfidence: Double,
        centerTimeFraction: Double,
        rollerExcursionP90: Double,
        edgeApproachCount: Int,
        directionChangeCount: Int,
        recoveryCount: Int,
        meanRecoveryTimeMS: Double?,
        p90RecoveryTimeMS: Double?
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sampleCount = max(0, sampleCount)
        self.meanConfidence = min(
            1,
            max(0, meanConfidence)
        )
        self.centerTimeFraction = min(
            1,
            max(0, centerTimeFraction)
        )
        self.rollerExcursionP90 =
            max(0, rollerExcursionP90)
        self.edgeApproachCount =
            max(0, edgeApproachCount)
        self.directionChangeCount =
            max(0, directionChangeCount)
        self.recoveryCount = max(0, recoveryCount)
        self.meanRecoveryTimeMS = meanRecoveryTimeMS
        self.p90RecoveryTimeMS = p90RecoveryTimeMS
        self.claimBoundary = (
            "Metrics are derived from image-plane deck/roller geometry. "
                + "They are balance-control proxies until camera and "
                + "equipment calibration are separately qualified."
        )
    }
}

@MainActor
public final class IndoBoardBalanceMetricAccumulator {
    private struct Sample: Sendable {
        let elapsedSeconds: Double
        let position: Double
        let confidence: Double
    }

    private var samples: [Sample] = []
    private var recoveryStart: Sample?
    private var recoveryDurations: [Double] = []
    private var wasNearEdge = false

    public init() {}

    public func reset() {
        samples.removeAll(keepingCapacity: true)
        recoveryStart = nil
        recoveryDurations.removeAll(keepingCapacity: true)
        wasNearEdge = false
    }

    public func ingest(
        _ state: IndoBoardBalanceState,
        elapsedSeconds: Double
    ) {
        guard state.confidence >= 0.35,
              elapsedSeconds.isFinite
        else {
            return
        }

        let sample = Sample(
            elapsedSeconds: max(0, elapsedSeconds),
            position: state.rollerAlongDeck,
            confidence: state.confidence
        )
        samples.append(sample)

        let absolute = abs(sample.position)

        if recoveryStart == nil,
           absolute >= 0.55 {
            recoveryStart = sample
        } else if let recoveryStart,
                  absolute <= 0.25,
                  sample.elapsedSeconds
                    > recoveryStart.elapsedSeconds {
            recoveryDurations.append(
                sample.elapsedSeconds
                    - recoveryStart.elapsedSeconds
            )
            self.recoveryStart = nil
        } else if let recoveryStart,
                  sample.elapsedSeconds
                    - recoveryStart.elapsedSeconds > 5 {
            // Do not let an occlusion or prolonged instability turn into
            // an arbitrarily long "recovery" measurement.
            self.recoveryStart = nil
        }

        let nearEdge = absolute >= 0.75
        wasNearEdge = nearEdge

        if samples.count > 8_000 {
            samples.removeFirst(
                samples.count - 8_000
            )
        }
        if recoveryDurations.count > 500 {
            recoveryDurations.removeFirst(
                recoveryDurations.count - 500
            )
        }
    }

    public func makeMetrics()
        -> IndoBoardBalanceMetrics? {
        guard samples.count >= 20 else {
            return nil
        }

        let positions = samples.map {
            abs($0.position)
        }
        let centerCount = positions.filter {
            $0 <= 0.25
        }.count
        let meanConfidence =
            samples.map(\.confidence)
                .reduce(0, +)
                / Double(samples.count)

        return IndoBoardBalanceMetrics(
            sampleCount: samples.count,
            meanConfidence: meanConfidence,
            centerTimeFraction:
                Double(centerCount)
                    / Double(samples.count),
            rollerExcursionP90:
                percentile(positions, q: 0.90)
                    ?? 0,
            edgeApproachCount:
                edgeApproachCount(),
            directionChangeCount:
                directionChangeCount(),
            recoveryCount:
                recoveryDurations.count,
            meanRecoveryTimeMS:
                recoveryDurations.isEmpty
                    ? nil
                    : (
                        recoveryDurations.reduce(0, +)
                            / Double(
                                recoveryDurations.count
                            )
                    ) * 1_000,
            p90RecoveryTimeMS:
                percentile(
                    recoveryDurations,
                    q: 0.90
                ).map { $0 * 1_000 }
        )
    }

    private func edgeApproachCount() -> Int {
        guard samples.count >= 2 else {
            return 0
        }

        var count = 0
        var previousNearEdge =
            abs(samples[0].position) >= 0.75

        for sample in samples.dropFirst() {
            let nearEdge =
                abs(sample.position) >= 0.75
            if nearEdge && !previousNearEdge {
                count += 1
            }
            previousNearEdge = nearEdge
        }
        return count
    }

    private func directionChangeCount() -> Int {
        guard samples.count >= 4 else {
            return 0
        }

        var signs: [Int] = []
        for pair in zip(
            samples,
            samples.dropFirst()
        ) {
            let dt = max(
                0.02,
                pair.1.elapsedSeconds
                    - pair.0.elapsedSeconds
            )
            let speed =
                (pair.1.position - pair.0.position)
                    / dt

            guard abs(speed) >= 0.20 else {
                continue
            }
            signs.append(speed > 0 ? 1 : -1)
        }

        guard signs.count >= 2 else {
            return 0
        }

        return zip(
            signs,
            signs.dropFirst()
        )
        .filter { $0.0 != $0.1 }
        .count
    }

    private func percentile(
        _ values: [Double],
        q: Double
    ) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let ordered = values.sorted()
        guard ordered.count > 1 else {
            return ordered[0]
        }

        let position =
            Double(ordered.count - 1)
                * min(1, max(0, q))
        let lower = Int(floor(position))
        let upper = Int(ceil(position))

        if lower == upper {
            return ordered[lower]
        }

        let fraction =
            position - Double(lower)
        return ordered[lower] * (1 - fraction)
            + ordered[upper] * fraction
    }
}
