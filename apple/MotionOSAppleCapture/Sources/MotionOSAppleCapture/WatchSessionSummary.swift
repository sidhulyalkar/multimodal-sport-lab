import Foundation

public struct WatchSessionTracePoint: Codable, Equatable, Sendable {
    public let elapsedSeconds: Double
    public let meanUserAccelerationG: Double
    public let peakUserAccelerationG: Double
    public let meanRotationRateRadS: Double
    public let peakRotationRateRadS: Double
}

public struct WatchIMUSummary: Codable, Equatable, Sendable {
    public let count: UInt64
    public let durationSeconds: Double
    public let effectiveHz: Double
    public let maxGapMS: Double
    public let missingSequences: UInt64
    public let nonMonotonicSequences: UInt64
    public let nonMonotonicTimestamps: UInt64
}

public struct WatchHeartRateSummary: Codable, Equatable, Sendable {
    public let count: UInt64
    public let minimumBPM: Double?
    public let meanBPM: Double?
    public let maximumBPM: Double?
}

public struct WatchMotionSummary: Codable, Equatable, Sendable {
    public let userAccelerationRMSG: Double?
    public let userAccelerationP95G: Double?
    public let rotationRateRMSRadS: Double?
    public let rotationRateP95RadS: Double?
}

public struct WatchSessionSummary: Codable, Equatable, Sendable {
    public static let protocolVersion = "motionos.watch-session-summary.v1"

    public let protocolVersion: String
    public let sessionID: String
    public let sourceJournalSHA256: String
    public let imu: WatchIMUSummary
    public let heartRate: WatchHeartRateSummary
    public let motion: WatchMotionSummary
    public let trace: [WatchSessionTracePoint]
    public let claimBoundary: String

    public init(
        sessionID: String,
        sourceJournalSHA256: String,
        imu: WatchIMUSummary,
        heartRate: WatchHeartRateSummary,
        motion: WatchMotionSummary,
        trace: [WatchSessionTracePoint]
    ) {
        self.protocolVersion = Self.protocolVersion
        self.sessionID = sessionID
        self.sourceJournalSHA256 = sourceJournalSHA256
        self.imu = imu
        self.heartRate = heartRate
        self.motion = motion
        self.trace = trace
        self.claimBoundary = (
            "Derived display summary from the sealed Apple Watch journal. "
                + "It is not raw evidence, does not replace the journal, and "
                + "does not qualify biomechanics or physiological accuracy."
        )
    }
}

public enum WatchSessionSummaryBuilder {
    public static func build(
        journalURL: URL,
        sourceJournalSHA256: String,
        bucketSeconds: Double = 5.0
    ) throws -> WatchSessionSummary {
        guard bucketSeconds > 0 else {
            throw SummaryError.invalidBucketDuration
        }

        let decoder = JSONDecoder()
        var sessionID: String?
        var imuCount: UInt64 = 0
        var hrCount: UInt64 = 0
        var firstIMUTimestamp: UInt64?
        var lastIMUTimestamp: UInt64?
        var previousIMUTimestamp: UInt64?
        var previousIMUSequence: UInt64?
        var missingSequences: UInt64 = 0
        var nonMonotonicSequences: UInt64 = 0
        var nonMonotonicTimestamps: UInt64 = 0
        var maxGapNS: UInt64 = 0

        var accelerationValues: [Double] = []
        var rotationValues: [Double] = []
        var heartRates: [Double] = []
        var buckets: [Int: BucketAccumulator] = [:]

        try forEachLine(in: journalURL) { line in
            let event = try decoder.decode(SensorEnvelope.self, from: line)
            sessionID = sessionID ?? event.sessionID

            guard event.sessionID == sessionID else {
                throw SummaryError.mixedSessionIDs
            }

            switch event.stream {
            case "/body/watch/imu":
                imuCount &+= 1
                firstIMUTimestamp = firstIMUTimestamp ?? event.deviceTimeNS
                lastIMUTimestamp = event.deviceTimeNS

                if let previousSequence = previousIMUSequence {
                    if event.sequence > previousSequence {
                        let delta = event.sequence - previousSequence
                        if delta > 1 {
                            missingSequences &+= delta - 1
                        }
                    } else {
                        nonMonotonicSequences &+= 1
                    }
                }
                previousIMUSequence = event.sequence

                if let previousTimestamp = previousIMUTimestamp {
                    if event.deviceTimeNS > previousTimestamp {
                        maxGapNS = max(
                            maxGapNS,
                            event.deviceTimeNS - previousTimestamp
                        )
                    } else {
                        nonMonotonicTimestamps &+= 1
                    }
                }
                previousIMUTimestamp = event.deviceTimeNS

                guard let derived = WatchMotionDerivation.derive(
                    payload: event.payload
                )
                else {
                    return
                }

                let accelerationG = derived.userAccelerationG
                let rotationRate = derived.rotationRateRadS
                accelerationValues.append(accelerationG)
                rotationValues.append(rotationRate)

                if let start = firstIMUTimestamp,
                   event.deviceTimeNS >= start {
                    let elapsed = Double(event.deviceTimeNS - start)
                        / 1_000_000_000
                    let bucket = Int(elapsed / bucketSeconds)
                    buckets[bucket, default: BucketAccumulator()]
                        .observe(
                            accelerationG: accelerationG,
                            rotationRateRadS: rotationRate
                        )
                }

            case "/body/watch/hr":
                if case .number(let bpm) = event.payload["bpm"],
                   bpm.isFinite,
                   bpm > 0 {
                    hrCount &+= 1
                    heartRates.append(bpm)
                }

            default:
                break
            }
        }

        guard let resolvedSessionID = sessionID else {
            throw SummaryError.emptyJournal
        }

        let durationSeconds: Double
        if let first = firstIMUTimestamp,
           let last = lastIMUTimestamp,
           last >= first {
            durationSeconds = Double(last - first) / 1_000_000_000
        } else {
            durationSeconds = 0
        }

        let effectiveHz = durationSeconds > 0 && imuCount > 1
            ? Double(imuCount - 1) / durationSeconds
            : 0

        let trace = buckets
            .keys
            .sorted()
            .compactMap { key -> WatchSessionTracePoint? in
                guard let bucket = buckets[key],
                      bucket.count > 0
                else {
                    return nil
                }
                return WatchSessionTracePoint(
                    elapsedSeconds: Double(key) * bucketSeconds,
                    meanUserAccelerationG:
                        bucket.accelerationSum / Double(bucket.count),
                    peakUserAccelerationG: bucket.accelerationPeak,
                    meanRotationRateRadS:
                        bucket.rotationSum / Double(bucket.count),
                    peakRotationRateRadS: bucket.rotationPeak
                )
            }

        return WatchSessionSummary(
            sessionID: resolvedSessionID,
            sourceJournalSHA256: sourceJournalSHA256,
            imu: WatchIMUSummary(
                count: imuCount,
                durationSeconds: durationSeconds,
                effectiveHz: effectiveHz,
                maxGapMS: Double(maxGapNS) / 1_000_000,
                missingSequences: missingSequences,
                nonMonotonicSequences: nonMonotonicSequences,
                nonMonotonicTimestamps: nonMonotonicTimestamps
            ),
            heartRate: WatchHeartRateSummary(
                count: hrCount,
                minimumBPM: heartRates.min(),
                meanBPM: mean(heartRates),
                maximumBPM: heartRates.max()
            ),
            motion: WatchMotionSummary(
                userAccelerationRMSG: rms(accelerationValues),
                userAccelerationP95G: percentile95(accelerationValues),
                rotationRateRMSRadS: rms(rotationValues),
                rotationRateP95RadS: percentile95(rotationValues)
            ),
            trace: trace
        )
    }

    public static func write(
        _ summary: WatchSessionSummary,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: url, options: .atomic)
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func rms(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let meanSquare = values.reduce(0) { partial, value in
            partial + value * value
        } / Double(values.count)
        return sqrt(meanSquare)
    }

    private static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(
            (Double(sorted.count - 1) * 0.95).rounded(.toNearestOrAwayFromZero)
        )
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func forEachLine(
        in url: URL,
        _ body: (Data) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty {
                    try body(line)
                }
            }
        }

        if !buffer.isEmpty {
            try body(buffer)
        }
    }

    private struct BucketAccumulator {
        var count = 0
        var accelerationSum = 0.0
        var accelerationPeak = 0.0
        var rotationSum = 0.0
        var rotationPeak = 0.0

        mutating func observe(
            accelerationG: Double,
            rotationRateRadS: Double
        ) {
            count += 1
            accelerationSum += accelerationG
            accelerationPeak = max(accelerationPeak, accelerationG)
            rotationSum += rotationRateRadS
            rotationPeak = max(rotationPeak, rotationRateRadS)
        }
    }

    public enum SummaryError: LocalizedError, Equatable {
        case invalidBucketDuration
        case emptyJournal
        case mixedSessionIDs

        public var errorDescription: String? {
            switch self {
            case .invalidBucketDuration:
                "Watch summary bucket duration must be positive."
            case .emptyJournal:
                "Watch journal contained no decodable MotionOS events."
            case .mixedSessionIDs:
                "Watch journal contained events from multiple session IDs."
            }
        }
    }
}
