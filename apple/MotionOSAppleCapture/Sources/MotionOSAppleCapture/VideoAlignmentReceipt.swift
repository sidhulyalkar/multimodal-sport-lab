import Foundation

public struct VideoAlignmentAnchorV1:
    Codable,
    Equatable,
    Sendable {
    public let label: String
    public let videoPTSNS: UInt64
    public let referenceTimeNS: UInt64
    public let uncertaintyNS: UInt64
    public let source: String

    enum CodingKeys: String, CodingKey {
        case label
        case videoPTSNS = "video_pts_ns"
        case referenceTimeNS = "reference_time_ns"
        case uncertaintyNS = "uncertainty_ns"
        case source
    }

    public init(
        label: String,
        videoPTSNS: UInt64,
        referenceTimeNS: UInt64,
        uncertaintyNS: UInt64,
        source: String
    ) {
        self.label = label
        self.videoPTSNS = videoPTSNS
        self.referenceTimeNS = referenceTimeNS
        self.uncertaintyNS = uncertaintyNS
        self.source = source
    }
}

public struct VideoAlignmentCoverageV1:
    Codable,
    Equatable,
    Sendable {
    public let passed: Bool
    public let anchorCount: Int
    public let referenceStartNS: UInt64
    public let referenceEndNS: UInt64
    public let firstPositionFraction: Double
    public let lastPositionFraction: Double
    public let hasMiddleAnchor: Bool
    public let referenceSpanFraction: Double

    enum CodingKeys: String, CodingKey {
        case passed
        case anchorCount = "anchor_count"
        case referenceStartNS = "reference_start_ns"
        case referenceEndNS = "reference_end_ns"
        case firstPositionFraction =
            "first_position_fraction"
        case lastPositionFraction =
            "last_position_fraction"
        case hasMiddleAnchor = "has_middle_anchor"
        case referenceSpanFraction =
            "reference_span_fraction"
    }
}

public struct VideoAlignmentClockModelV1:
    Codable,
    Equatable,
    Sendable {
    public let slope: Double
    public let interceptNS: Double
    public let driftPPM: Double
    public let residualRMSNS: Double
    public let residualRMSMS: Double
    public let observationsUsed: Int

    enum CodingKeys: String, CodingKey {
        case slope
        case interceptNS = "intercept_ns"
        case driftPPM = "drift_ppm"
        case residualRMSNS = "residual_rms_ns"
        case residualRMSMS = "residual_rms_ms"
        case observationsUsed = "observations_used"
    }

    public func mapVideoPTS(
        _ value: UInt64
    ) -> UInt64 {
        let mapped =
            slope * Double(value)
                + interceptNS
        return UInt64(
            max(
                0,
                mapped.rounded(.toNearestOrEven)
            )
        )
    }

    public func mapReferenceTimeToVideoPTS(
        _ value: UInt64
    ) -> UInt64? {
        guard slope.isFinite,
              slope > 0
        else {
            return nil
        }
        let mapped =
            (
                Double(value)
                    - interceptNS
            ) / slope
        guard mapped.isFinite else {
            return nil
        }
        return UInt64(
            max(
                0,
                mapped.rounded(.toNearestOrEven)
            )
        )
    }
}

public struct VideoAlignmentSourceV1:
    Codable,
    Equatable,
    Sendable {
    public let filename: String
    public let sha256: String
    public let byteCount: UInt64
    public let durationNS: UInt64
    public let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case filename
        case sha256
        case byteCount = "byte_count"
        case durationNS = "duration_ns"
        case metadata
    }
}

public struct VideoAlignmentReferenceWindowV1:
    Codable,
    Equatable,
    Sendable {
    public let startNS: UInt64
    public let endNS: UInt64

    enum CodingKeys: String, CodingKey {
        case startNS = "start_ns"
        case endNS = "end_ns"
    }
}

public struct VideoAlignmentTrimWindowV1:
    Codable,
    Equatable,
    Sendable {
    public let videoStartNS: UInt64
    public let videoEndNS: UInt64

    enum CodingKeys: String, CodingKey {
        case videoStartNS = "video_start_ns"
        case videoEndNS = "video_end_ns"
    }
}

public struct VideoAlignmentReceiptV1:
    Codable,
    Equatable,
    Sendable {
    public static let schemaVersion =
        "motionos.video-alignment.v1"

    public let schemaVersion: String
    public let runID: String
    public let sourceVideo: VideoAlignmentSourceV1
    public let referenceWindow:
        VideoAlignmentReferenceWindowV1
    public let anchors: [VideoAlignmentAnchorV1]
    public let coverage: VideoAlignmentCoverageV1
    public let clockModel: VideoAlignmentClockModelV1
    public let anchorResidualsNS: [Int64]
    public let trimWindow: VideoAlignmentTrimWindowV1
    public let mapping: String
    public let claimBoundary: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case sourceVideo = "source_video"
        case referenceWindow = "reference_window"
        case anchors
        case coverage
        case clockModel = "clock_model"
        case anchorResidualsNS = "anchor_residuals_ns"
        case trimWindow = "trim_window"
        case mapping
        case claimBoundary = "claim_boundary"
    }

    public func mapVideoPTS(
        _ value: UInt64
    ) -> UInt64 {
        clockModel.mapVideoPTS(value)
    }

    public func mapReferenceTimeToVideoPTS(
        _ value: UInt64
    ) -> UInt64? {
        clockModel.mapReferenceTimeToVideoPTS(value)
    }
}

public enum VideoAlignmentReceiptError:
    LocalizedError,
    Equatable {
    case invalidRunID
    case invalidSource
    case invalidDuration
    case invalidReferenceWindow
    case insufficientAnchors
    case duplicateAnchorLabel
    case anchorOutOfBounds
    case nonMonotonicAnchors
    case invalidClockModel
    case insufficientCoverage
    case emptyTrimWindow
    case invalidReceipt(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRunID:
            "Video alignment requires a run ID."
        case .invalidSource:
            "Video alignment source evidence is invalid."
        case .invalidDuration:
            "Video alignment requires a positive video duration."
        case .invalidReferenceWindow:
            "Video alignment reference window is invalid."
        case .insufficientAnchors:
            "Video alignment requires at least three anchors."
        case .duplicateAnchorLabel:
            "Video alignment anchor labels must be unique."
        case .anchorOutOfBounds:
            "A video alignment anchor lies outside the source/reference window."
        case .nonMonotonicAnchors:
            "Video alignment anchors must preserve temporal order."
        case .invalidClockModel:
            "Video alignment produced an invalid affine clock model."
        case .insufficientCoverage:
            "Video alignment anchors do not span early, middle, and late session time."
        case .emptyTrimWindow:
            "Video alignment produced an empty trim window."
        case .invalidReceipt(let detail):
            "Video alignment receipt failed validation: \(detail)"
        }
    }
}

public enum VideoAlignmentReceiptBuilderV1 {
    public static func build(
        runID: String,
        sourceFilename: String,
        sourceSHA256: String,
        sourceByteCount: UInt64,
        videoDurationNS: UInt64,
        referenceStartNS: UInt64,
        referenceEndNS: UInt64,
        anchors: [VideoAlignmentAnchorV1],
        sourceMetadata: [String: String] = [:]
    ) throws -> VideoAlignmentReceiptV1 {
        let cleanedRunID = runID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedRunID.isEmpty else {
            throw VideoAlignmentReceiptError.invalidRunID
        }
        guard !sourceFilename.isEmpty,
              sourceSHA256.count == 64,
              sourceByteCount > 0
        else {
            throw VideoAlignmentReceiptError.invalidSource
        }
        guard videoDurationNS > 0 else {
            throw VideoAlignmentReceiptError.invalidDuration
        }
        guard referenceEndNS > referenceStartNS else {
            throw VideoAlignmentReceiptError
                .invalidReferenceWindow
        }

        let ordered = try validateAndOrder(
            anchors,
            videoDurationNS: videoDurationNS,
            referenceStartNS: referenceStartNS,
            referenceEndNS: referenceEndNS
        )
        let coverage = try makeCoverage(
            ordered,
            referenceStartNS: referenceStartNS,
            referenceEndNS: referenceEndNS
        )
        guard coverage.passed else {
            throw VideoAlignmentReceiptError
                .insufficientCoverage
        }

        let model = try fitClock(ordered)
        let residuals = ordered.map { anchor in
            let mapped = model.mapVideoPTS(
                anchor.videoPTSNS
            )
            return Int64(anchor.referenceTimeNS)
                - Int64(mapped)
        }

        guard let trimStartRaw =
                model.mapReferenceTimeToVideoPTS(
                    referenceStartNS
                ),
              let trimEndRaw =
                model.mapReferenceTimeToVideoPTS(
                    referenceEndNS
                )
        else {
            throw VideoAlignmentReceiptError
                .invalidClockModel
        }

        let trimStart = min(
            videoDurationNS,
            trimStartRaw
        )
        let trimEnd = min(
            videoDurationNS,
            trimEndRaw
        )
        guard trimEnd > trimStart else {
            throw VideoAlignmentReceiptError
                .emptyTrimWindow
        }

        return VideoAlignmentReceiptV1(
            schemaVersion:
                VideoAlignmentReceiptV1
                    .schemaVersion,
            runID: cleanedRunID,
            sourceVideo: VideoAlignmentSourceV1(
                filename: sourceFilename,
                sha256: sourceSHA256,
                byteCount: sourceByteCount,
                durationNS: videoDurationNS,
                metadata: sourceMetadata
            ),
            referenceWindow:
                VideoAlignmentReferenceWindowV1(
                    startNS: referenceStartNS,
                    endNS: referenceEndNS
                ),
            anchors: ordered,
            coverage: coverage,
            clockModel: model,
            anchorResidualsNS: residuals,
            trimWindow: VideoAlignmentTrimWindowV1(
                videoStartNS: trimStart,
                videoEndNS: trimEnd
            ),
            mapping:
                "source video PTS -> MotionOS reference/session time",
            claimBoundary:
                "This receipt binds an imported video to a declared temporal alignment and derived trim window. It does not prove camera calibration, 3D geometry, biomechanics accuracy, or event labels."
        )
    }

    public static func validate(
        _ receipt: VideoAlignmentReceiptV1,
        sourceDigest: FileEvidenceDigest
    ) throws {
        guard receipt.schemaVersion
                == VideoAlignmentReceiptV1
                    .schemaVersion
        else {
            throw VideoAlignmentReceiptError.invalidReceipt(
                "unsupported schema"
            )
        }
        guard sourceDigest.sha256
                == receipt.sourceVideo.sha256,
              sourceDigest.byteCount
                == receipt.sourceVideo.byteCount
        else {
            throw VideoAlignmentReceiptError.invalidReceipt(
                "source hash/size mismatch"
            )
        }

        let recomputed = try build(
            runID: receipt.runID,
            sourceFilename:
                receipt.sourceVideo.filename,
            sourceSHA256:
                receipt.sourceVideo.sha256,
            sourceByteCount:
                receipt.sourceVideo.byteCount,
            videoDurationNS:
                receipt.sourceVideo.durationNS,
            referenceStartNS:
                receipt.referenceWindow.startNS,
            referenceEndNS:
                receipt.referenceWindow.endNS,
            anchors: receipt.anchors,
            sourceMetadata:
                receipt.sourceVideo.metadata
        )

        guard recomputed.coverage
                == receipt.coverage,
              recomputed.clockModel.slope
                == receipt.clockModel.slope,
              recomputed.clockModel.interceptNS
                == receipt.clockModel.interceptNS,
              recomputed.clockModel.residualRMSNS
                == receipt.clockModel.residualRMSNS,
              recomputed.anchorResidualsNS
                == receipt.anchorResidualsNS,
              recomputed.trimWindow
                == receipt.trimWindow
        else {
            throw VideoAlignmentReceiptError.invalidReceipt(
                "derived fields do not recompute"
            )
        }
    }

    private static func validateAndOrder(
        _ anchors: [VideoAlignmentAnchorV1],
        videoDurationNS: UInt64,
        referenceStartNS: UInt64,
        referenceEndNS: UInt64
    ) throws -> [VideoAlignmentAnchorV1] {
        guard anchors.count >= 3 else {
            throw VideoAlignmentReceiptError
                .insufficientAnchors
        }

        let labels = anchors.map {
            $0.label.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        guard labels.allSatisfy({ !$0.isEmpty }),
              Set(labels).count == labels.count
        else {
            throw VideoAlignmentReceiptError
                .duplicateAnchorLabel
        }

        let ordered = anchors.sorted {
            $0.referenceTimeNS
                < $1.referenceTimeNS
        }

        var previousVideo: UInt64?
        var previousReference: UInt64?
        for anchor in ordered {
            guard anchor.videoPTSNS <= videoDurationNS,
                  anchor.referenceTimeNS
                    >= referenceStartNS,
                  anchor.referenceTimeNS
                    <= referenceEndNS
            else {
                throw VideoAlignmentReceiptError
                    .anchorOutOfBounds
            }

            if let previousVideo,
               anchor.videoPTSNS <= previousVideo {
                throw VideoAlignmentReceiptError
                    .nonMonotonicAnchors
            }
            if let previousReference,
               anchor.referenceTimeNS
                    <= previousReference {
                throw VideoAlignmentReceiptError
                    .nonMonotonicAnchors
            }
            previousVideo = anchor.videoPTSNS
            previousReference =
                anchor.referenceTimeNS
        }

        return ordered
    }

    private static func makeCoverage(
        _ anchors: [VideoAlignmentAnchorV1],
        referenceStartNS: UInt64,
        referenceEndNS: UInt64
    ) throws -> VideoAlignmentCoverageV1 {
        guard anchors.count >= 3,
              referenceEndNS > referenceStartNS
        else {
            throw VideoAlignmentReceiptError
                .insufficientAnchors
        }

        let duration = Double(
            referenceEndNS - referenceStartNS
        )
        let positions = anchors.map {
            Double(
                $0.referenceTimeNS
                    - referenceStartNS
            ) / duration
        }
        guard let first = positions.first,
              let last = positions.last
        else {
            throw VideoAlignmentReceiptError
                .insufficientAnchors
        }

        let hasMiddle = positions
            .dropFirst()
            .dropLast()
            .contains {
                $0 >= 0.30 && $0 <= 0.70
            }
        let span = Double(
            anchors.last!.referenceTimeNS
                - anchors.first!.referenceTimeNS
        ) / duration
        let passed =
            positions.allSatisfy {
                $0 >= 0 && $0 <= 1
            }
            && first <= 0.20
            && hasMiddle
            && last >= 0.80

        return VideoAlignmentCoverageV1(
            passed: passed,
            anchorCount: anchors.count,
            referenceStartNS: referenceStartNS,
            referenceEndNS: referenceEndNS,
            firstPositionFraction: first,
            lastPositionFraction: last,
            hasMiddleAnchor: hasMiddle,
            referenceSpanFraction: span
        )
    }

    private static func fitClock(
        _ anchors: [VideoAlignmentAnchorV1]
    ) throws -> VideoAlignmentClockModelV1 {
        guard anchors.count >= 3 else {
            throw VideoAlignmentReceiptError
                .insufficientAnchors
        }

        let x0 = anchors[0].videoPTSNS
        let y0 = anchors[0].referenceTimeNS
        let xs = anchors.map {
            Double($0.videoPTSNS - x0)
        }
        let ys = anchors.map {
            Double($0.referenceTimeNS - y0)
        }
        let count = Double(anchors.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        let denominator = xs.reduce(0) {
            $0 + ($1 - meanX) * ($1 - meanX)
        }
        guard denominator > 0 else {
            throw VideoAlignmentReceiptError
                .invalidClockModel
        }

        let numerator = zip(xs, ys).reduce(0.0) {
            partial,
            pair in
            partial
                + (pair.0 - meanX)
                    * (pair.1 - meanY)
        }
        let slope = numerator / denominator
        guard slope.isFinite,
              slope > 0
        else {
            throw VideoAlignmentReceiptError
                .invalidClockModel
        }

        let localIntercept =
            meanY - slope * meanX
        let intercept =
            Double(y0)
                + localIntercept
                - slope * Double(x0)
        let residuals = zip(xs, ys).map {
            pair in
            pair.1
                - (
                    slope * pair.0
                        + localIntercept
                )
        }
        let rms = sqrt(
            residuals.reduce(0.0) {
                $0 + $1 * $1
            } / count
        )

        guard intercept.isFinite,
              rms.isFinite
        else {
            throw VideoAlignmentReceiptError
                .invalidClockModel
        }

        return VideoAlignmentClockModelV1(
            slope: slope,
            interceptNS: intercept,
            driftPPM:
                (slope - 1) * 1_000_000,
            residualRMSNS: rms,
            residualRMSMS: rms / 1_000_000,
            observationsUsed: anchors.count
        )
    }
}
