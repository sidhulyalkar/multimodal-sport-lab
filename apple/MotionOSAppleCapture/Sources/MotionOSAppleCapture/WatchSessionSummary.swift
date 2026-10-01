import Foundation

public struct WatchSessionMotionPoint: Sendable, Equatable, Identifiable {
    public let elapsedSeconds: Double
    public let meanMotionDeltaG: Double
    public let peakMotionDeltaG: Double
    public let meanRotationRateRadS: Double

    public var id: Double { elapsedSeconds }

    public init(
        elapsedSeconds: Double,
        meanMotionDeltaG: Double,
        peakMotionDeltaG: Double,
        meanRotationRateRadS: Double
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.meanMotionDeltaG = meanMotionDeltaG
        self.peakMotionDeltaG = peakMotionDeltaG
        self.meanRotationRateRadS = meanRotationRateRadS
    }
}

public struct WatchSessionHeartPoint: Sendable, Equatable, Identifiable {
    public let elapsedSeconds: Double
    public let bpm: Double

    public var id: Double { elapsedSeconds }

    public init(elapsedSeconds: Double, bpm: Double) {
        self.elapsedSeconds = elapsedSeconds
        self.bpm = bpm
    }
}

public struct WatchSessionSummary: Sendable, Equatable {
    public let sessionID: String
    public let captureOrigin: String?
    public let watchModel: String?
    public let watchSystemVersion: String?
    public let wristLocation: String?
    public let durationSeconds: Double
    public let imuSampleCount: UInt64
    public let heartRateEventCount: UInt64
    public let effectiveIMUHz: Double
    public let medianIMUMilliseconds: Double?
    public let maxIMUMilliseconds: Double
    public let missingIMUSequences: UInt64
    public let nonMonotonicIMUTimestamps: UInt64
    public let motionDeltaGMedian: Double?
    public let motionDeltaGP95: Double?
    public let rotationRateMedianRadS: Double?
    public let rotationRateP95RadS: Double?
    public let heartRateMinBPM: Double?
    public let heartRateMedianBPM: Double?
    public let heartRateMaxBPM: Double?
    public let rollRangeDegrees: Double?
    public let pitchRangeDegrees: Double?
    public let yawRangeDegrees: Double?
    public let motionTimeline: [WatchSessionMotionPoint]
    public let heartRateTimeline: [WatchSessionHeartPoint]

    public init(
        sessionID: String,
        captureOrigin: String?,
        watchModel: String?,
        watchSystemVersion: String?,
        wristLocation: String?,
        durationSeconds: Double,
        imuSampleCount: UInt64,
        heartRateEventCount: UInt64,
        effectiveIMUHz: Double,
        medianIMUMilliseconds: Double?,
        maxIMUMilliseconds: Double,
        missingIMUSequences: UInt64,
        nonMonotonicIMUTimestamps: UInt64,
        motionDeltaGMedian: Double?,
        motionDeltaGP95: Double?,
        rotationRateMedianRadS: Double?,
        rotationRateP95RadS: Double?,
        heartRateMinBPM: Double?,
        heartRateMedianBPM: Double?,
        heartRateMaxBPM: Double?,
        rollRangeDegrees: Double?,
        pitchRangeDegrees: Double?,
        yawRangeDegrees: Double?,
        motionTimeline: [WatchSessionMotionPoint],
        heartRateTimeline: [WatchSessionHeartPoint]
    ) {
        self.sessionID = sessionID
        self.captureOrigin = captureOrigin
        self.watchModel = watchModel
        self.watchSystemVersion = watchSystemVersion
        self.wristLocation = wristLocation
        self.durationSeconds = durationSeconds
        self.imuSampleCount = imuSampleCount
        self.heartRateEventCount = heartRateEventCount
        self.effectiveIMUHz = effectiveIMUHz
        self.medianIMUMilliseconds = medianIMUMilliseconds
        self.maxIMUMilliseconds = maxIMUMilliseconds
        self.missingIMUSequences = missingIMUSequences
        self.nonMonotonicIMUTimestamps = nonMonotonicIMUTimestamps
        self.motionDeltaGMedian = motionDeltaGMedian
        self.motionDeltaGP95 = motionDeltaGP95
        self.rotationRateMedianRadS = rotationRateMedianRadS
        self.rotationRateP95RadS = rotationRateP95RadS
        self.heartRateMinBPM = heartRateMinBPM
        self.heartRateMedianBPM = heartRateMedianBPM
        self.heartRateMaxBPM = heartRateMaxBPM
        self.rollRangeDegrees = rollRangeDegrees
        self.pitchRangeDegrees = pitchRangeDegrees
        self.yawRangeDegrees = yawRangeDegrees
        self.motionTimeline = motionTimeline
        self.heartRateTimeline = heartRateTimeline
    }
}

public enum WatchSessionSummaryAnalyzer {
    public enum AnalysisError: LocalizedError {
        case noWatchIMU
        case malformedLine(Int, String)
        case multipleSessions(String, String)

        public var errorDescription: String? {
            switch self {
            case .noWatchIMU:
                "The recovered journal contains no Watch IMU samples."
            case .malformedLine(let line, let message):
                "Journal line \(line) could not be decoded: \(message)"
            case .multipleSessions(let first, let next):
                "Journal contains multiple session IDs: \(first) and \(next)."
            }
        }
    }

    public static func summarizeJournal(
        at url: URL
    ) throws -> WatchSessionSummary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var builder = Builder()
        let decoder = JSONDecoder()
        var buffer = Data()
        var lineNumber = 0

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            let pieces = buffer.split(
                separator: 0x0A,
                omittingEmptySubsequences: false
            )
            guard let remainder = pieces.last else {
                continue
            }

            for piece in pieces.dropLast() where !piece.isEmpty {
                lineNumber += 1
                do {
                    let event = try decoder.decode(
                        SensorEnvelope.self,
                        from: Data(piece)
                    )
                    try builder.consume(event)
                } catch {
                    throw AnalysisError.malformedLine(
                        lineNumber,
                        error.localizedDescription
                    )
                }
            }
            buffer = Data(remainder)
        }

        if !buffer.isEmpty {
            lineNumber += 1
            do {
                let event = try decoder.decode(
                    SensorEnvelope.self,
                    from: buffer
                )
                try builder.consume(event)
            } catch {
                throw AnalysisError.malformedLine(
                    lineNumber,
                    error.localizedDescription
                )
            }
        }

        return try builder.finish()
    }
}

private extension WatchSessionSummaryAnalyzer {
    struct MotionBucket {
        var motionSum = 0.0
        var motionPeak = 0.0
        var rotationSum = 0.0
        var count: UInt64 = 0

        mutating func add(
            motionDeltaG: Double,
            rotationRate: Double
        ) {
            motionSum += motionDeltaG
            motionPeak = max(motionPeak, motionDeltaG)
            rotationSum += rotationRate
            count += 1
        }
    }

    struct TimedHeartSample {
        let timestampNS: UInt64
        let bpm: Double
    }

    struct Builder {
        private(set) var sessionID: String?
        private(set) var captureOrigin: String?
        private(set) var watchModel: String?
        private(set) var watchSystemVersion: String?
        private(set) var wristLocation: String?

        private var firstIMUTimestampNS: UInt64?
        private var lastIMUTimestampNS: UInt64?
        private var previousIMUTimestampNS: UInt64?
        private var previousIMUSequence: UInt64?
        private var imuCount: UInt64 = 0
        private var hrCount: UInt64 = 0
        private var missingIMUSequences: UInt64 = 0
        private var nonMonotonicIMUTimestamps: UInt64 = 0
        private var maxGapMS = 0.0
        private var intervalMS: [Double] = []

        private var motionDeltaG: [Double] = []
        private var rotationRate: [Double] = []
        private var heartRates: [Double] = []
        private var timedHeartSamples: [TimedHeartSample] = []

        private var rollMin: Double?
        private var rollMax: Double?
        private var pitchMin: Double?
        private var pitchMax: Double?
        private var yawMin: Double?
        private var yawMax: Double?

        private var motionBuckets: [Int: MotionBucket] = [:]

        mutating func consume(_ event: SensorEnvelope) throws {
            try acceptSession(event.sessionID)

            switch event.stream {
            case "/meta/watch":
                captureOrigin = string(
                    event.payload["capture_origin"]
                ) ?? captureOrigin
                watchModel = string(
                    event.payload["model"]
                ) ?? watchModel
                watchSystemVersion = string(
                    event.payload["system_version"]
                ) ?? watchSystemVersion
                wristLocation = string(
                    event.payload["wrist_location"]
                ) ?? wristLocation

            case "/body/watch/imu":
                consumeIMU(event)

            case "/body/watch/hr":
                consumeHeartRate(event)

            default:
                break
            }
        }

        mutating func finish() throws -> WatchSessionSummary {
            guard let sessionID,
                  let first = firstIMUTimestampNS,
                  let last = lastIMUTimestampNS,
                  imuCount > 0
            else {
                throw AnalysisError.noWatchIMU
            }

            let durationSeconds = last >= first
                ? Double(last - first) / 1_000_000_000
                : 0
            let effectiveHz = durationSeconds > 0 && imuCount > 1
                ? Double(imuCount - 1) / durationSeconds
                : 0

            let motionTimeline = motionBuckets
                .keys
                .sorted()
                .compactMap { bucketIndex -> WatchSessionMotionPoint? in
                    guard let bucket = motionBuckets[bucketIndex],
                          bucket.count > 0
                    else {
                        return nil
                    }
                    return WatchSessionMotionPoint(
                        elapsedSeconds: Double(bucketIndex),
                        meanMotionDeltaG:
                            bucket.motionSum / Double(bucket.count),
                        peakMotionDeltaG: bucket.motionPeak,
                        meanRotationRateRadS:
                            bucket.rotationSum / Double(bucket.count)
                    )
                }

            let heartTimeline = timedHeartSamples.compactMap {
                sample -> WatchSessionHeartPoint? in
                guard sample.timestampNS >= first else {
                    return nil
                }
                return WatchSessionHeartPoint(
                    elapsedSeconds:
                        Double(sample.timestampNS - first)
                        / 1_000_000_000,
                    bpm: sample.bpm
                )
            }

            return WatchSessionSummary(
                sessionID: sessionID,
                captureOrigin: captureOrigin,
                watchModel: watchModel,
                watchSystemVersion: watchSystemVersion,
                wristLocation: wristLocation,
                durationSeconds: durationSeconds,
                imuSampleCount: imuCount,
                heartRateEventCount: hrCount,
                effectiveIMUHz: effectiveHz,
                medianIMUMilliseconds: percentile(intervalMS, 0.5),
                maxIMUMilliseconds: maxGapMS,
                missingIMUSequences: missingIMUSequences,
                nonMonotonicIMUTimestamps:
                    nonMonotonicIMUTimestamps,
                motionDeltaGMedian: percentile(motionDeltaG, 0.5),
                motionDeltaGP95: percentile(motionDeltaG, 0.95),
                rotationRateMedianRadS:
                    percentile(rotationRate, 0.5),
                rotationRateP95RadS:
                    percentile(rotationRate, 0.95),
                heartRateMinBPM: heartRates.min(),
                heartRateMedianBPM: percentile(heartRates, 0.5),
                heartRateMaxBPM: heartRates.max(),
                rollRangeDegrees: angularRangeDegrees(
                    minimum: rollMin,
                    maximum: rollMax
                ),
                pitchRangeDegrees: angularRangeDegrees(
                    minimum: pitchMin,
                    maximum: pitchMax
                ),
                yawRangeDegrees: angularRangeDegrees(
                    minimum: yawMin,
                    maximum: yawMax
                ),
                motionTimeline: motionTimeline,
                heartRateTimeline: heartTimeline
            )
        }

        private mutating func acceptSession(
            _ candidate: String
        ) throws {
            if let sessionID, sessionID != candidate {
                throw AnalysisError.multipleSessions(
                    sessionID,
                    candidate
                )
            }
            sessionID = sessionID ?? candidate
        }

        private mutating func consumeIMU(
            _ event: SensorEnvelope
        ) {
            let timestamp = event.deviceTimeNS
            firstIMUTimestampNS = firstIMUTimestampNS ?? timestamp
            lastIMUTimestampNS = timestamp
            imuCount += 1

            if let previous = previousIMUTimestampNS {
                if timestamp <= previous {
                    nonMonotonicIMUTimestamps += 1
                } else {
                    let gapMS =
                        Double(timestamp - previous) / 1_000_000
                    intervalMS.append(gapMS)
                    maxGapMS = max(maxGapMS, gapMS)
                }
            }
            previousIMUTimestampNS = timestamp

            if let previousSequence = previousIMUSequence,
               event.sequence > previousSequence + 1 {
                missingIMUSequences +=
                    event.sequence - previousSequence - 1
            }
            previousIMUSequence = event.sequence

            guard let ax = number(event.payload["ax"]),
                  let ay = number(event.payload["ay"]),
                  let az = number(event.payload["az"]),
                  let gx = number(event.payload["gx"]),
                  let gy = number(event.payload["gy"]),
                  let gz = number(event.payload["gz"])
            else {
                return
            }

            let standardGravity = 9.80665
            let accelerationMagnitude =
                sqrt(ax * ax + ay * ay + az * az)
            let deltaG = abs(
                accelerationMagnitude / standardGravity - 1
            )
            let rotation = sqrt(gx * gx + gy * gy + gz * gz)

            motionDeltaG.append(deltaG)
            rotationRate.append(rotation)

            if let first = firstIMUTimestampNS,
               timestamp >= first {
                let bucket = Int(
                    (timestamp - first) / 1_000_000_000
                )
                motionBuckets[bucket, default: MotionBucket()].add(
                    motionDeltaG: deltaG,
                    rotationRate: rotation
                )
            }

            Self.updateRange(
                value: number(event.payload["roll"]),
                minimum: &rollMin,
                maximum: &rollMax
            )
            Self.updateRange(
                value: number(event.payload["pitch"]),
                minimum: &pitchMin,
                maximum: &pitchMax
            )
            Self.updateRange(
                value: number(event.payload["yaw"]),
                minimum: &yawMin,
                maximum: &yawMax
            )
        }

        private mutating func consumeHeartRate(
            _ event: SensorEnvelope
        ) {
            guard let bpm = number(event.payload["bpm"]) else {
                return
            }
            hrCount += 1
            heartRates.append(bpm)
            timedHeartSamples.append(
                TimedHeartSample(
                    timestampNS: event.deviceTimeNS,
                    bpm: bpm
                )
            )
        }

        private func number(_ value: JSONValue?) -> Double? {
            guard case .number(let number) = value else {
                return nil
            }
            return number
        }

        private func string(_ value: JSONValue?) -> String? {
            guard case .string(let string) = value else {
                return nil
            }
            return string
        }

        private func percentile(
            _ values: [Double],
            _ fraction: Double
        ) -> Double? {
            guard !values.isEmpty else {
                return nil
            }

            let sorted = values.sorted()
            let clamped = min(max(fraction, 0), 1)
            let position =
                Double(sorted.count - 1) * clamped
            let lower = Int(floor(position))
            let upper = Int(ceil(position))
            if lower == upper {
                return sorted[lower]
            }
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight)
                + sorted[upper] * weight
        }

        private func angularRangeDegrees(
            minimum: Double?,
            maximum: Double?
        ) -> Double? {
            guard let minimum, let maximum else {
                return nil
            }
            return (maximum - minimum) * 180 / .pi
        }

        private static func updateRange(
            value: Double?,
            minimum: inout Double?,
            maximum: inout Double?
        ) {
            guard let value else {
                return
            }
            minimum = min(minimum ?? value, value)
            maximum = max(maximum ?? value, value)
        }
    }
}
