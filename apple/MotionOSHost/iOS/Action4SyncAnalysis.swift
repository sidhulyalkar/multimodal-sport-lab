import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import MotionOSAppleCapture
import Vision

enum Action4SyncAnalysisError: LocalizedError {
    case missingExternalVideo
    case missingIPhoneEvidence
    case missingProductManifest
    case missingCameraCueAnchors
    case cameraSourceHashMismatch
    case externalSourceHashMismatch
    case insufficientReferenceMotion
    case insufficientExternalMotion
    case noPlausibleProposal

    var errorDescription: String? {
        switch self {
        case .missingExternalVideo:
            "Import the original Action 4 movie before analyzing sync."
        case .missingIPhoneEvidence:
            "This run needs its sealed iPhone video and camera journal."
        case .missingProductManifest:
            "The sealed product-session manifest is unavailable."
        case .missingCameraCueAnchors:
            "This run does not contain iPhone camera timestamps for all three sync cues. Record a new multiview session with the current build."
        case .cameraSourceHashMismatch:
            "The iPhone movie no longer matches the hash sealed in the product manifest."
        case .externalSourceHashMismatch:
            "The Action 4 movie no longer matches the hash sealed at import."
        case .insufficientReferenceMotion:
            "MotionOS could not isolate all three iPhone sync gestures."
        case .insufficientExternalMotion:
            "The Action 4 video did not yield enough visible arm-motion evidence."
        case .noPlausibleProposal:
            "No three Action 4 motion peaks matched the START / MIDDLE / END timing pattern closely enough."
        }
    }
}

struct Action4SyncAnalysisArtifact:
    Codable,
    Equatable,
    Sendable {
    static let schemaVersion =
        "motionos.action4-sync-analysis.v1"

    let schemaVersion: String
    let runID: String
    let createdAtUTC: String
    let externalVideoSHA256: String
    let iPhoneVideoSHA256: String
    let iPhoneFirstFramePTSNS: UInt64
    let externalPoseSampleCount: Int
    let externalMotionSampleCount: Int
    let iPhoneMotionSampleCount: Int
    let referenceGestures: [SyncReferenceGesture]
    let proposal: ActionCameraSyncProposal
    let analysisParameters: [String: Double]
    let claimBoundary: String

    init(
        runID: String,
        externalVideoSHA256: String,
        iPhoneVideoSHA256: String,
        iPhoneFirstFramePTSNS: UInt64,
        externalPoseSampleCount: Int,
        externalMotionSampleCount: Int,
        iPhoneMotionSampleCount: Int,
        referenceGestures: [SyncReferenceGesture],
        proposal: ActionCameraSyncProposal,
        analysisParameters: [String: Double]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.runID = runID
        self.createdAtUTC =
            ISO8601DateFormatter().string(from: Date())
        self.externalVideoSHA256 = externalVideoSHA256
        self.iPhoneVideoSHA256 = iPhoneVideoSHA256
        self.iPhoneFirstFramePTSNS = iPhoneFirstFramePTSNS
        self.externalPoseSampleCount = externalPoseSampleCount
        self.externalMotionSampleCount = externalMotionSampleCount
        self.iPhoneMotionSampleCount = iPhoneMotionSampleCount
        self.referenceGestures = referenceGestures
        self.proposal = proposal
        self.analysisParameters = analysisParameters
        self.claimBoundary = (
            "This file proposes cross-view temporal correspondences from "
                + "visible arm motion. It does not become synchronization "
                + "authority until reviewed and sealed as a video-alignment "
                + "receipt. File creation times are not used as timing truth."
        )
    }
}

struct ArmPoseSample: Sendable {
    let timeNS: UInt64
    let joints: [String: BodyJoint2D]
}

enum ArmMotionTraceBuilder {
    static func samples(
        from poses: [ProductReplayPoseSample]
    ) -> [ArmPoseSample] {
        poses.map {
            ArmPoseSample(
                timeNS: $0.ptsNS,
                joints: $0.frame.imageJointMap
            )
        }
    }

    static func trace(
        from poses: [ArmPoseSample]
    ) -> [MotionEnergySample] {
        let ordered = poses
            .filter { !$0.joints.isEmpty }
            .sorted { $0.timeNS < $1.timeNS }
        guard ordered.count >= 2 else {
            return []
        }

        var result: [MotionEnergySample] = []
        result.reserveCapacity(ordered.count - 1)

        for (previous, current) in zip(
            ordered,
            ordered.dropFirst()
        ) {
            guard current.timeNS > previous.timeNS
            else {
                continue
            }

            let deltaSeconds = Double(
                current.timeNS - previous.timeNS
            ) / 1_000_000_000
            guard deltaSeconds >= 0.03,
                  deltaSeconds <= 0.80
            else {
                continue
            }

            var changes: [Double] = []
            var confidences: [Double] = []

            for side in ["left", "right"] {
                if let previousVector = armVector(
                    side: side,
                    joints: previous.joints
                ),
                let currentVector = armVector(
                    side: side,
                    joints: current.joints
                ) {
                    changes.append(
                        hypot(
                            currentVector.x - previousVector.x,
                            currentVector.y - previousVector.y
                        ) / deltaSeconds
                    )
                    confidences.append(
                        min(
                            previousVector.confidence,
                            currentVector.confidence
                        )
                    )
                }
            }

            guard !changes.isEmpty else {
                continue
            }

            let energy =
                changes.reduce(0, +)
                    / Double(changes.count)
            let confidence =
                confidences.reduce(0, +)
                    / Double(confidences.count)

            result.append(
                MotionEnergySample(
                    timeNS: current.timeNS,
                    energy: energy,
                    confidence: confidence
                )
            )
        }

        return result
    }

    private struct ArmVector {
        let x: Double
        let y: Double
        let confidence: Double
    }

    private static func armVector(
        side: String,
        joints: [String: BodyJoint2D]
    ) -> ArmVector? {
        guard let shoulder = joint(
            aliases: [
                "\(side)Shoulder",
                "\(side)_shoulder",
            ],
            joints: joints
        ) else {
            return nil
        }

        let distal = joint(
            aliases: [
                "\(side)Wrist",
                "\(side)_wrist",
                "\(side)Hand",
                "\(side)_hand",
            ],
            joints: joints
        ) ?? joint(
            aliases: [
                "\(side)Elbow",
                "\(side)_elbow",
            ],
            joints: joints
        )

        guard let distal else {
            return nil
        }

        return ArmVector(
            x: distal.x - shoulder.x,
            y: distal.y - shoulder.y,
            confidence: min(
                shoulder.confidence,
                distal.confidence
            )
        )
    }

    private static func joint(
        aliases: [String],
        joints: [String: BodyJoint2D]
    ) -> BodyJoint2D? {
        let targets = Set(aliases.map(normalize))
        return joints.values.first {
            targets.contains(normalize($0.id))
        }
    }

    private static func normalize(
        _ value: String
    ) -> String {
        value.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
    }
}

enum Action4VideoPoseExtractor {
    struct Result: Sendable {
        let poses: [ArmPoseSample]
        let motionTrace: [MotionEnergySample]
    }

    static let sampleIntervalSeconds = 0.20
    static let minimumJointConfidence: Float = 0.25

    static func extract(
        from videoURL: URL
    ) async throws -> Result {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(
            withMediaType: .video
        )
        guard let track = tracks.first else {
            throw Action4SyncAnalysisError
                .insufficientExternalMotion
        }

        let transform = try await track.load(
            .preferredTransform
        )
        let orientation = cgOrientation(
            for: transform
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Action4SyncAnalysisError
                .insufficientExternalMotion
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error
                ?? Action4SyncAnalysisError
                    .insufficientExternalMotion
        }

        let request = VNDetectHumanBodyPoseRequest()
        let intervalNS = UInt64(
            sampleIntervalSeconds * 1_000_000_000
        )
        var nextSampleNS: UInt64 = 0
        var poses: [ArmPoseSample] = []

        while let sampleBuffer =
                output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            let pts = CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )
            let ptsNS = presentationTimeNS(pts)
            guard ptsNS >= nextSampleNS else {
                continue
            }
            nextSampleNS = ptsNS.addingReportingOverflow(
                intervalNS
            ).overflow
                ? UInt64.max
                : ptsNS + intervalNS

            guard let pixelBuffer =
                    CMSampleBufferGetImageBuffer(
                        sampleBuffer
                    )
            else {
                continue
            }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation
            )
            try handler.perform([request])

            guard let observation =
                    request.results?.first
            else {
                continue
            }
            let points = try observation.recognizedPoints(
                .all
            )
            let joints = Dictionary(
                uniqueKeysWithValues:
                    points.compactMap {
                        name,
                        point
                        -> (String, BodyJoint2D)? in
                        guard point.confidence
                                >= minimumJointConfidence
                        else {
                            return nil
                        }
                        return (
                            name.rawValue.rawValue,
                            BodyJoint2D(
                                id: name.rawValue.rawValue,
                                x: Double(
                                    point.location.x
                                ),
                                y: Double(
                                    point.location.y
                                ),
                                confidence: Double(
                                    point.confidence
                                )
                            )
                        )
                    }
            )
            guard !joints.isEmpty else {
                continue
            }

            poses.append(
                ArmPoseSample(
                    timeNS: ptsNS,
                    joints: joints
                )
            )
        }

        guard reader.status == .completed
                || reader.status == .reading
        else {
            throw reader.error
                ?? Action4SyncAnalysisError
                    .insufficientExternalMotion
        }

        let trace = ArmMotionTraceBuilder.trace(
            from: poses
        )
        guard trace.count >= 20 else {
            throw Action4SyncAnalysisError
                .insufficientExternalMotion
        }

        return Result(
            poses: poses,
            motionTrace: trace
        )
    }

    private static func presentationTimeNS(
        _ time: CMTime
    ) -> UInt64 {
        let converted = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .roundHalfAwayFromZero
        )
        return UInt64(max(0, converted.value))
    }

    private static func cgOrientation(
        for transform: CGAffineTransform
    ) -> CGImagePropertyOrientation {
        let epsilon = 0.01
        let a = transform.a
        let b = transform.b
        let c = transform.c
        let d = transform.d

        if abs(a) < epsilon,
           abs(b - 1) < epsilon,
           abs(c + 1) < epsilon,
           abs(d) < epsilon {
            return .right
        }
        if abs(a) < epsilon,
           abs(b + 1) < epsilon,
           abs(c - 1) < epsilon,
           abs(d) < epsilon {
            return .left
        }
        if abs(a + 1) < epsilon,
           abs(d + 1) < epsilon {
            return .down
        }
        return .up
    }
}

enum Action4SyncAnalyzer {
    static let artifactFilename =
        "action4-sync-proposal.json"

    static func existingArtifactURL(
        for run: ProductRunRecord
    ) -> URL? {
        let url = artifactURL(for: run)
        return FileManager.default.fileExists(
            atPath: url.path
        )
            ? url
            : nil
    }

    static func loadArtifact(
        for run: ProductRunRecord
    ) throws -> Action4SyncAnalysisArtifact? {
        guard let url = existingArtifactURL(
            for: run
        ) else {
            return nil
        }
        let value = try JSONDecoder().decode(
            Action4SyncAnalysisArtifact.self,
            from: Data(contentsOf: url)
        )
        guard value.schemaVersion
                == Action4SyncAnalysisArtifact
                    .schemaVersion,
              value.runID == run.runID
        else {
            return nil
        }
        return value
    }

    static func analyze(
        run: ProductRunRecord
    ) async throws -> Action4SyncAnalysisArtifact {
        guard let externalVideoURL =
                run.externalVideoURL
        else {
            throw Action4SyncAnalysisError
                .missingExternalVideo
        }
        guard let cameraVideoURL =
                run.cameraVideoURL,
              let cameraJournalURL =
                run.cameraJournalURL
        else {
            throw Action4SyncAnalysisError
                .missingIPhoneEvidence
        }
        guard let manifest = run.productManifest
        else {
            throw Action4SyncAnalysisError
                .missingProductManifest
        }

        let requiredLabels = [
            "start",
            "middle",
            "end",
        ]
        let receipts = Dictionary(
            uniqueKeysWithValues:
                manifest.syncReceipts.map {
                    ($0.label.lowercased(), $0)
                }
        )
        guard requiredLabels.allSatisfy({
            receipts[$0]?.iPhoneCameraPTSNS != nil
        }) else {
            throw Action4SyncAnalysisError
                .missingCameraCueAnchors
        }

        async let cameraDigestTask =
            Task.detached(priority: .utility) {
                try FileEvidence.digest(
                    cameraVideoURL
                )
            }.value
        async let externalDigestTask =
            Task.detached(priority: .utility) {
                try FileEvidence.digest(
                    externalVideoURL
                )
            }.value
        async let timelineTask =
            Task.detached(priority: .utility) {
                try ProductReplayEvidenceLoader
                    .loadCameraTimeline(
                        cameraJournalURL
                    )
            }.value
        async let externalTask =
            Action4VideoPoseExtractor.extract(
                from: externalVideoURL
            )

        let (
            cameraDigest,
            externalDigest,
            timeline,
            externalResult
        ) = try await (
            cameraDigestTask,
            externalDigestTask,
            timelineTask,
            externalTask
        )

        if let expected =
                manifest.cameraVideoSHA256,
           expected != cameraDigest.sha256 {
            throw Action4SyncAnalysisError
                .cameraSourceHashMismatch
        }
        if let expected =
                manifest.externalCameraSHA256,
           expected != externalDigest.sha256 {
            throw Action4SyncAnalysisError
                .externalSourceHashMismatch
        }

        let iPhonePoseSamples =
            ArmMotionTraceBuilder.samples(
                from: timeline.poseSamples
            )
        let iPhoneTrace =
            ArmMotionTraceBuilder.trace(
                from: iPhonePoseSamples
            )
        guard iPhoneTrace.count >= 20 else {
            throw Action4SyncAnalysisError
                .insufficientReferenceMotion
        }

        var referenceGestures:
            [SyncReferenceGesture] = []
        for label in requiredLabels {
            guard let receipt = receipts[label],
                  let cuePTS =
                    receipt.iPhoneCameraPTSNS,
                  let peak =
                    ActionCameraSyncMatcher
                        .strongestGesture(
                            in: iPhoneTrace,
                            around: cuePTS
                        ),
                  peak.timeNS
                    >= timeline.firstFramePTSNS
            else {
                throw Action4SyncAnalysisError
                    .insufficientReferenceMotion
            }

            referenceGestures.append(
                SyncReferenceGesture(
                    label: label,
                    referenceTimeNS:
                        peak.timeNS
                            - timeline.firstFramePTSNS,
                    cueTimeNS:
                        cuePTS
                            >= timeline.firstFramePTSNS
                            ? cuePTS
                                - timeline
                                    .firstFramePTSNS
                            : nil,
                    energy: peak.energy,
                    confidence: peak.confidence
                )
            )
        }

        guard let proposal =
                ActionCameraSyncMatcher.propose(
                    referenceGestures:
                        referenceGestures,
                    externalTrace:
                        externalResult.motionTrace
                )
        else {
            throw Action4SyncAnalysisError
                .noPlausibleProposal
        }

        let artifact = Action4SyncAnalysisArtifact(
            runID: run.runID,
            externalVideoSHA256:
                externalDigest.sha256,
            iPhoneVideoSHA256:
                cameraDigest.sha256,
            iPhoneFirstFramePTSNS:
                timeline.firstFramePTSNS,
            externalPoseSampleCount:
                externalResult.poses.count,
            externalMotionSampleCount:
                externalResult.motionTrace.count,
            iPhoneMotionSampleCount:
                iPhoneTrace.count,
            referenceGestures:
                referenceGestures,
            proposal: proposal,
            analysisParameters: [
                "external_pose_sample_interval_s":
                    Action4VideoPoseExtractor
                        .sampleIntervalSeconds,
                "reference_gesture_search_behind_s":
                    0.35,
                "reference_gesture_search_ahead_s":
                    2.0,
                "maximum_clock_scale_deviation":
                    0.015,
            ]
        )

        let output = artifactURL(for: run)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        try encoder.encode(artifact).write(
            to: output,
            options: .atomic
        )

        return artifact
    }

    private static func artifactURL(
        for run: ProductRunRecord
    ) -> URL {
        run.directoryURL
            .appendingPathComponent(
                "external",
                isDirectory: true
            )
            .appendingPathComponent(
                "action4",
                isDirectory: true
            )
            .appendingPathComponent(
                artifactFilename
            )
    }
}

@MainActor
final class Action4SyncAnalysisController:
    ObservableObject {
    enum Phase: String {
        case idle
        case analyzing
        case ready
        case failed
    }

    @Published private(set) var phase: Phase =
        .idle
    @Published private(set) var artifact:
        Action4SyncAnalysisArtifact?
    @Published private(set) var errorMessage:
        String?

    func loadExisting(
        run: ProductRunRecord
    ) {
        do {
            artifact = try Action4SyncAnalyzer
                .loadArtifact(for: run)
            phase = artifact == nil
                ? .idle
                : .ready
            errorMessage = nil
        } catch {
            artifact = nil
            phase = .failed
            errorMessage =
                "Saved Action 4 sync proposal could not be read: "
                    + error.localizedDescription
        }
    }

    func analyze(
        run: ProductRunRecord
    ) async {
        guard phase != .analyzing else {
            return
        }
        phase = .analyzing
        errorMessage = nil

        do {
            artifact = try await Action4SyncAnalyzer
                .analyze(run: run)
            phase = .ready
        } catch {
            artifact = nil
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }
}
