import Foundation

public struct BodyPoseTrajectorySample: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        frame.sessionID + ":" + String(frame.sequence)
    }

    public let progress: Double
    public let elapsedSeconds: Double
    public let frame: BodyMovementFrame

    public init(
        progress: Double,
        elapsedSeconds: Double,
        frame: BodyMovementFrame
    ) {
        self.progress = min(1, max(0, progress))
        self.elapsedSeconds = max(0, elapsedSeconds)
        self.frame = frame
    }
}

public struct BodyPoseTrajectory: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.body-pose-trajectory.v1"

    public let schemaVersion: String
    public let sessionID: String
    public let sourceJournalSHA256: String?
    public let sourceFrameCount: Int
    public let durationSeconds: Double
    public let samples: [BodyPoseTrajectorySample]
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        sessionID: String,
        sourceJournalSHA256: String?,
        sourceFrameCount: Int,
        durationSeconds: Double,
        samples: [BodyPoseTrajectorySample]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sourceJournalSHA256 = sourceJournalSHA256
        self.sourceFrameCount = sourceFrameCount
        self.durationSeconds = durationSeconds
        self.samples = samples
        self.claimBoundary = (
            "This trajectory is a compact time-normalized representation of "
                + "Vision 3D pose evidence. It does not replace the camera "
                + "journal and does not establish performance quality."
        )
    }
}

public enum BodyPoseTrajectoryBuilder {
    public static func build(
        journalURL: URL,
        sourceJournalSHA256: String? = nil,
        targetSampleCount: Int = 90
    ) throws -> BodyPoseTrajectory {
        guard targetSampleCount >= 2 else {
            throw BuildError.invalidTargetSampleCount
        }

        let decoder = JSONDecoder()
        var frames: [BodyMovementFrame] = []
        var resolvedSessionID: String?

        try forEachLine(in: journalURL) { data in
            let event = try decoder.decode(
                SensorEnvelope.self,
                from: data
            )

            guard event.stream == "/camera/pose3d" else {
                return
            }

            if let session = resolvedSessionID,
               session != event.sessionID {
                throw BuildError.mixedSessionIDs
            }
            resolvedSessionID =
                resolvedSessionID ?? event.sessionID

            guard let frame = BodyMovementFrameParser.parseVisionPose(
                payload: event.payload,
                sessionID: event.sessionID,
                sequence: event.sequence,
                deviceTimeNS: event.deviceTimeNS
            ) else {
                return
            }

            frames.append(frame)
        }

        guard let sessionID = resolvedSessionID,
              frames.count >= 2
        else {
            throw BuildError.insufficientPoseFrames
        }

        frames.sort {
            if $0.deviceTimeNS != $1.deviceTimeNS {
                return $0.deviceTimeNS < $1.deviceTimeNS
            }
            return $0.sequence < $1.sequence
        }

        let firstTime = frames.first!.deviceTimeNS
        let lastTime = frames.last!.deviceTimeNS
        guard lastTime > firstTime else {
            throw BuildError.nonIncreasingTime
        }

        let durationSeconds =
            Double(lastTime - firstTime)
                / 1_000_000_000

        let targetCount = min(
            targetSampleCount,
            frames.count
        )

        var samples: [BodyPoseTrajectorySample] = []
        samples.reserveCapacity(targetCount)

        var searchIndex = 0
        for targetIndex in 0..<targetCount {
            let targetProgress =
                Double(targetIndex)
                    / Double(targetCount - 1)
            let targetTime =
                Double(firstTime)
                    + targetProgress
                    * Double(lastTime - firstTime)

            while searchIndex + 1 < frames.count {
                let currentDistance = abs(
                    Double(frames[searchIndex].deviceTimeNS)
                        - targetTime
                )
                let nextDistance = abs(
                    Double(frames[searchIndex + 1].deviceTimeNS)
                        - targetTime
                )
                guard nextDistance <= currentDistance else {
                    break
                }
                searchIndex += 1
            }

            let frame = frames[searchIndex]
            let elapsed =
                Double(frame.deviceTimeNS - firstTime)
                    / 1_000_000_000
            let progress = elapsed / durationSeconds

            if samples.last?.frame.sequence
                == frame.sequence {
                continue
            }

            samples.append(
                BodyPoseTrajectorySample(
                    progress: progress,
                    elapsedSeconds: elapsed,
                    frame: frame
                )
            )
        }

        guard samples.count >= 2 else {
            throw BuildError.insufficientPoseFrames
        }

        return BodyPoseTrajectory(
            sessionID: sessionID,
            sourceJournalSHA256: sourceJournalSHA256,
            sourceFrameCount: frames.count,
            durationSeconds: durationSeconds,
            samples: samples
        )
    }

    private static func forEachLine(
        in url: URL,
        _ body: (Data) throws -> Void
    ) throws {
        let handle = try FileHandle(
            forReadingFrom: url
        )
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk =
                try handle.read(
                    upToCount: 64 * 1024
                )
                ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(
                of: 0x0A
            ) {
                let line = Data(
                    buffer[..<newline]
                )
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

    public enum BuildError: LocalizedError, Equatable {
        case invalidTargetSampleCount
        case insufficientPoseFrames
        case mixedSessionIDs
        case nonIncreasingTime

        public var errorDescription: String? {
            switch self {
            case .invalidTargetSampleCount:
                return "Pose trajectory needs at least two target samples."
            case .insufficientPoseFrames:
                return "Camera journal does not contain enough valid 3D pose frames."
            case .mixedSessionIDs:
                return "Camera journal contains pose frames from multiple sessions."
            case .nonIncreasingTime:
                return "Camera pose timestamps do not span a positive duration."
            }
        }
    }
}

public struct GhostJointDifference: Codable, Sendable, Equatable, Identifiable {
    public let jointID: String
    public let sampleCount: Int
    public let meanDistanceM: Double
    public let p95DistanceM: Double

    public var id: String { jointID }

    public init(
        jointID: String,
        sampleCount: Int,
        meanDistanceM: Double,
        p95DistanceM: Double
    ) {
        self.jointID = jointID
        self.sampleCount = sampleCount
        self.meanDistanceM = meanDistanceM
        self.p95DistanceM = p95DistanceM
    }
}

public struct GhostComparisonSummary: Codable, Sendable, Equatable {
    public static let schemaVersion = "motionos.ghost-comparison.v1"

    public let schemaVersion: String
    public let currentSessionID: String
    public let referenceSessionID: String
    public let samplePairCount: Int
    public let jointObservationCount: Int
    public let meanJointDistanceM: Double?
    public let medianJointDistanceM: Double?
    public let jointDifferences: [GhostJointDifference]
    public let claimBoundary: String

    public init(
        schemaVersion: String = Self.schemaVersion,
        currentSessionID: String,
        referenceSessionID: String,
        samplePairCount: Int,
        jointObservationCount: Int,
        meanJointDistanceM: Double?,
        medianJointDistanceM: Double?,
        jointDifferences: [GhostJointDifference]
    ) {
        self.schemaVersion = schemaVersion
        self.currentSessionID = currentSessionID
        self.referenceSessionID = referenceSessionID
        self.samplePairCount = samplePairCount
        self.jointObservationCount = jointObservationCount
        self.meanJointDistanceM = meanJointDistanceM
        self.medianJointDistanceM = medianJointDistanceM
        self.jointDifferences = jointDifferences
        self.claimBoundary = (
            "Ghost comparison time-normalizes two Vision pose trajectories and "
                + "reports descriptive root-relative geometry differences. "
                + "A smaller or larger distance is not automatically better."
        )
    }
}

public enum GhostComparisonEngine {
    public static func compare(
        current: BodyPoseTrajectory,
        reference: BodyPoseTrajectory
    ) -> GhostComparisonSummary {
        var allDistances: [Double] = []
        var byJoint: [String: [Double]] = [:]
        var pairCount = 0

        for currentSample in current.samples {
            guard let referenceSample = nearestSample(
                to: currentSample.progress,
                in: reference.samples
            ) else {
                continue
            }
            pairCount += 1

            let currentMap = currentSample.frame.jointMap
            let referenceMap = referenceSample.frame.jointMap
            let common = Set(currentMap.keys)
                .intersection(referenceMap.keys)

            for jointID in common {
                guard let lhs = currentMap[jointID]?.position,
                      let rhs = referenceMap[jointID]?.position
                else {
                    continue
                }

                let value = distance(lhs, rhs)
                guard value.isFinite else { continue }
                allDistances.append(value)
                byJoint[jointID, default: []].append(
                    value
                )
            }
        }

        let differences = byJoint.compactMap {
            jointID,
            values -> GhostJointDifference? in
            guard !values.isEmpty else { return nil }

            return GhostJointDifference(
                jointID: jointID,
                sampleCount: values.count,
                meanDistanceM:
                    values.reduce(0, +)
                        / Double(values.count),
                p95DistanceM:
                    percentile(
                        values,
                        fraction: 0.95
                    )
            )
        }
        .sorted {
            if $0.meanDistanceM
                != $1.meanDistanceM {
                return $0.meanDistanceM
                    > $1.meanDistanceM
            }
            return $0.jointID < $1.jointID
        }

        let mean: Double?
        if allDistances.isEmpty {
            mean = nil
        } else {
            mean =
                allDistances.reduce(0, +)
                    / Double(allDistances.count)
        }

        return GhostComparisonSummary(
            currentSessionID: current.sessionID,
            referenceSessionID: reference.sessionID,
            samplePairCount: pairCount,
            jointObservationCount: allDistances.count,
            meanJointDistanceM: mean,
            medianJointDistanceM:
                allDistances.isEmpty
                    ? nil
                    : percentile(
                        allDistances,
                        fraction: 0.5
                    ),
            jointDifferences: differences
        )
    }

    public static func nearestSample(
        to progress: Double,
        in samples: [BodyPoseTrajectorySample]
    ) -> BodyPoseTrajectorySample? {
        samples.min {
            abs($0.progress - progress)
                < abs($1.progress - progress)
        }
    }

    private static func distance(
        _ lhs: MotionVector3,
        _ rhs: MotionVector3
    ) -> Double {
        sqrt(
            pow(lhs.x - rhs.x, 2)
                + pow(lhs.y - rhs.y, 2)
                + pow(lhs.z - rhs.z, 2)
        )
    }

    private static func percentile(
        _ values: [Double],
        fraction: Double
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(1, max(0, fraction))
        let index = Int(
            (
                Double(sorted.count - 1)
                    * clamped
            ).rounded()
        )
        return sorted[index]
    }
}
