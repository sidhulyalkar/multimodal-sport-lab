import Foundation

public struct ExternalVideoPoseFrame:
    Codable,
    Equatable,
    Sendable,
    Identifiable {
    public let sourcePTSNS: UInt64
    public let joints: [BodyJoint2D]
    public let meanConfidence: Double

    public var id: UInt64 { sourcePTSNS }

    enum CodingKeys: String, CodingKey {
        case sourcePTSNS = "source_pts_ns"
        case joints
        case meanConfidence = "mean_confidence"
    }

    public init(
        sourcePTSNS: UInt64,
        joints: [BodyJoint2D],
        meanConfidence: Double? = nil
    ) {
        let ordered = joints.sorted { $0.id < $1.id }
        self.sourcePTSNS = sourcePTSNS
        self.joints = ordered

        if let meanConfidence {
            self.meanConfidence = min(
                1,
                max(0, meanConfidence)
            )
        } else if ordered.isEmpty {
            self.meanConfidence = 0
        } else {
            self.meanConfidence =
                ordered.map(\.confidence)
                    .reduce(0, +)
                    / Double(ordered.count)
        }
    }

    public var jointMap: [String: BodyJoint2D] {
        Dictionary(
            uniqueKeysWithValues:
                joints.map { ($0.id, $0) }
        )
    }
}

public struct ExternalVideoPoseTrack:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.external-video-pose-track.v1"

    public let schemaVersion: String
    public let runID: String
    public let sourceID: String
    public let sourceVideoSHA256: String
    public let sourceVideoByteCount: UInt64
    public let sourceDurationNS: UInt64
    public let analyzerID: String
    public let analyzerVersion: String
    public let sampleIntervalSeconds: Double
    public let coordinateFrame: String
    public let frames: [ExternalVideoPoseFrame]
    public let createdAtUTC: String
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case sourceID = "source_id"
        case sourceVideoSHA256 =
            "source_video_sha256"
        case sourceVideoByteCount =
            "source_video_byte_count"
        case sourceDurationNS =
            "source_duration_ns"
        case analyzerID = "analyzer_id"
        case analyzerVersion = "analyzer_version"
        case sampleIntervalSeconds =
            "sample_interval_seconds"
        case coordinateFrame =
            "coordinate_frame"
        case frames
        case createdAtUTC = "created_at_utc"
        case claimBoundary = "claim_boundary"
    }

    public init(
        runID: String,
        sourceID: String,
        sourceVideoSHA256: String,
        sourceVideoByteCount: UInt64,
        sourceDurationNS: UInt64,
        analyzerID: String,
        analyzerVersion: String,
        sampleIntervalSeconds: Double,
        coordinateFrame: String,
        frames: [ExternalVideoPoseFrame],
        createdAtUTC: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.sourceID = sourceID
        self.sourceVideoSHA256 =
            sourceVideoSHA256
        self.sourceVideoByteCount =
            sourceVideoByteCount
        self.sourceDurationNS =
            sourceDurationNS
        self.analyzerID = analyzerID
        self.analyzerVersion =
            analyzerVersion
        self.sampleIntervalSeconds =
            sampleIntervalSeconds
        self.coordinateFrame =
            coordinateFrame
        self.frames = frames.sorted {
            $0.sourcePTSNS < $1.sourcePTSNS
        }
        self.createdAtUTC = createdAtUTC
        self.claimBoundary = (
            "This track contains source-camera image-space body pose "
                + "derived from RGB frames. Coordinates are normalized "
                + "within the source image after orientation handling. "
                + "It does not establish metric camera calibration, "
                + "world geometry, center of mass, force, muscle "
                + "activation, or medical validity."
        )
    }

    public var frameCount: Int {
        frames.count
    }

    public var meanConfidence: Double {
        guard !frames.isEmpty else {
            return 0
        }
        return frames
            .map(\.meanConfidence)
            .reduce(0, +)
            / Double(frames.count)
    }

    public var temporalCoverageFraction: Double {
        guard sourceDurationNS > 0,
              let first = frames.first,
              let last = frames.last,
              last.sourcePTSNS
                >= first.sourcePTSNS
        else {
            return 0
        }
        let span = Double(
            last.sourcePTSNS
                - first.sourcePTSNS
        )
        return min(
            1,
            max(
                0,
                span
                    / Double(sourceDurationNS)
            )
        )
    }

    public func interpolatedFrame(
        at sourcePTSNS: UInt64,
        maximumBracketGapNS: UInt64 =
            450_000_000,
        maximumNearestDistanceNS: UInt64 =
            180_000_000
    ) -> ExternalVideoPoseFrame? {
        guard !frames.isEmpty else {
            return nil
        }

        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].sourcePTSNS
                < sourcePTSNS {
                low = middle + 1
            } else {
                high = middle
            }
        }

        if low < frames.count,
           frames[low].sourcePTSNS
                == sourcePTSNS {
            return frames[low]
        }

        let previous =
            low > 0
                ? frames[low - 1]
                : nil
        let next =
            low < frames.count
                ? frames[low]
                : nil

        if let previous,
           let next,
           next.sourcePTSNS
                > previous.sourcePTSNS {
            let bracket =
                next.sourcePTSNS
                    - previous.sourcePTSNS
            let leftDistance =
                sourcePTSNS
                    >= previous.sourcePTSNS
                    ? sourcePTSNS
                        - previous.sourcePTSNS
                    : UInt64.max
            let rightDistance =
                next.sourcePTSNS
                    >= sourcePTSNS
                    ? next.sourcePTSNS
                        - sourcePTSNS
                    : UInt64.max

            if bracket <= maximumBracketGapNS,
               leftDistance <= bracket,
               rightDistance <= bracket {
                let fraction =
                    Double(leftDistance)
                        / Double(bracket)
                let previousMap =
                    previous.jointMap
                let nextMap =
                    next.jointMap

                let commonIDs =
                    Set(previousMap.keys)
                        .intersection(nextMap.keys)
                        .sorted()

                let joints =
                    commonIDs.compactMap {
                        id -> BodyJoint2D? in
                        guard let lhs =
                                previousMap[id],
                              let rhs =
                                nextMap[id]
                        else {
                            return nil
                        }

                        return BodyJoint2D(
                            id: id,
                            x:
                                lhs.x
                                + (
                                    rhs.x - lhs.x
                                ) * fraction,
                            y:
                                lhs.y
                                + (
                                    rhs.y - lhs.y
                                ) * fraction,
                            confidence:
                                lhs.confidence
                                + (
                                    rhs.confidence
                                        - lhs.confidence
                                ) * fraction
                        )
                    }

                if !joints.isEmpty {
                    return ExternalVideoPoseFrame(
                        sourcePTSNS:
                            sourcePTSNS,
                        joints: joints
                    )
                }
            }
        }

        let candidates =
            [previous, next]
                .compactMap { $0 }
        guard let nearest =
                candidates.min(by: {
                    distance(
                        $0.sourcePTSNS,
                        sourcePTSNS
                    )
                        < distance(
                            $1.sourcePTSNS,
                            sourcePTSNS
                        )
                }),
              distance(
                nearest.sourcePTSNS,
                sourcePTSNS
              ) <= maximumNearestDistanceNS
        else {
            return nil
        }

        return nearest
    }

    private func distance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs
            ? lhs - rhs
            : rhs - lhs
    }
}
