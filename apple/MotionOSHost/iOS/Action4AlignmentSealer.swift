import AVFoundation
import CoreMedia
import Foundation
import MotionOSAppleCapture

enum Action4AlignmentSealError: LocalizedError {
    case missingExternalVideo
    case missingProposal
    case missingIPhoneTimeline
    case invalidVideoDuration
    case sourceHashMismatch
    case proposalHashMismatch
    case receiptRunMismatch
    case receiptSourceMismatch
    case receiptCoverageFailed

    var errorDescription: String? {
        switch self {
        case .missingExternalVideo:
            "The imported Action 4 original is unavailable."
        case .missingProposal:
            "Analyze and review the Action 4 sync proposal first."
        case .missingIPhoneTimeline:
            "The iPhone camera timeline is unavailable."
        case .invalidVideoDuration:
            "The Action 4 movie duration is invalid."
        case .sourceHashMismatch:
            "The Action 4 source no longer matches the sealed import hash."
        case .proposalHashMismatch:
            "The reviewed sync proposal changed before sealing."
        case .receiptRunMismatch:
            "The saved alignment belongs to a different MotionOS run."
        case .receiptSourceMismatch:
            "The saved alignment does not bind this Action 4 source."
        case .receiptCoverageFailed:
            "The saved alignment does not span early, middle, and late session time."
        }
    }
}

enum Action4AlignmentSealer {
    static let receiptFilename =
        "video-alignment.json"

    static func receiptURL(
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
                receiptFilename
            )
    }

    static func loadReceipt(
        for run: ProductRunRecord
    ) throws -> VideoAlignmentReceiptV1? {
        let url = receiptURL(for: run)
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return nil
        }

        let receipt = try JSONDecoder().decode(
            VideoAlignmentReceiptV1.self,
            from: Data(contentsOf: url)
        )
        guard receipt.schemaVersion
                == VideoAlignmentReceiptV1
                    .schemaVersion,
              receipt.runID == run.runID
        else {
            throw Action4AlignmentSealError
                .receiptRunMismatch
        }
        guard receipt.coverage.passed else {
            throw Action4AlignmentSealError
                .receiptCoverageFailed
        }
        if let expected =
                run.productManifest?
                    .externalCameraSHA256,
           receipt.sourceVideo.sha256 != expected {
            throw Action4AlignmentSealError
                .receiptSourceMismatch
        }
        return receipt
    }

    static func seal(
        run: ProductRunRecord,
        artifact: Action4SyncAnalysisArtifact
    ) async throws -> VideoAlignmentReceiptV1 {
        guard artifact.runID == run.runID else {
            throw Action4AlignmentSealError
                .receiptRunMismatch
        }
        guard let externalURL =
                run.externalVideoURL
        else {
            throw Action4AlignmentSealError
                .missingExternalVideo
        }
        guard let cameraJournalURL =
                run.cameraJournalURL
        else {
            throw Action4AlignmentSealError
                .missingIPhoneTimeline
        }
        guard let proposalURL =
                Action4SyncAnalyzer
                    .existingArtifactURL(for: run)
        else {
            throw Action4AlignmentSealError
                .missingProposal
        }

        async let evidenceTask =
            Task.detached(priority: .utility) {
                let source = try FileEvidence.digest(
                    externalURL
                )
                let proposal = try FileEvidence.digest(
                    proposalURL
                )
                return (source, proposal)
            }.value
        async let timelineTask =
            Task.detached(priority: .utility) {
                try ProductReplayEvidenceLoader
                    .loadCameraTimeline(
                        cameraJournalURL
                    )
            }.value
        async let durationTask =
            loadDurationNS(externalURL)

        let (
            evidence,
            timeline,
            durationNS
        ) = try await (
            evidenceTask,
            timelineTask,
            durationTask
        )
        let sourceDigest = evidence.0
        let proposalDigest = evidence.1

        guard sourceDigest.sha256
                == artifact.externalVideoSHA256
        else {
            throw Action4AlignmentSealError
                .sourceHashMismatch
        }
        if let expected =
                run.productManifest?
                    .externalCameraSHA256,
           expected != sourceDigest.sha256 {
            throw Action4AlignmentSealError
                .sourceHashMismatch
        }

        let currentArtifact = try JSONDecoder().decode(
            Action4SyncAnalysisArtifact.self,
            from: Data(contentsOf: proposalURL)
        )
        guard currentArtifact == artifact else {
            throw Action4AlignmentSealError
                .proposalHashMismatch
        }

        let anchors = artifact.proposal.anchors.map {
            VideoAlignmentAnchorV1(
                label: $0.label,
                videoPTSNS: $0.externalPTSNS,
                referenceTimeNS:
                    $0.referenceTimeNS,
                // Action 4 pose is sampled at 5 Hz and the reference pose
                // stream is roughly 10 Hz. 150 ms is a conservative
                // discretization envelope for the reviewed visual landmark.
                uncertaintyNS: 150_000_000,
                source:
                    "operator_reviewed_cross_view_arm_motion_peak_v1"
            )
        }

        let receipt =
            try VideoAlignmentReceiptBuilderV1.build(
                runID: run.runID,
                sourceFilename:
                    externalURL.lastPathComponent,
                sourceSHA256:
                    sourceDigest.sha256,
                sourceByteCount:
                    sourceDigest.byteCount,
                videoDurationNS: durationNS,
                referenceStartNS: 0,
                referenceEndNS:
                    UInt64(
                        max(
                            1,
                            (
                                timeline.durationSeconds
                                    * 1_000_000_000
                            )
                            .rounded(
                                .toNearestOrEven
                            )
                        )
                    ),
                anchors: anchors,
                sourceMetadata: [
                    "camera": "DJI Osmo Action 4",
                    "review_state":
                        "operator_accepted",
                    "proposal_schema":
                        artifact.proposal.schemaVersion,
                    "proposal_sha256":
                        proposalDigest.sha256,
                    "proposal_confidence":
                        String(
                            format:
                                "%.6f",
                            artifact.proposal.confidence
                        ),
                    "reference":
                        "iphone_camera_elapsed_pts",
                    "protocol_version":
                        run.protocolVersion,
                ]
            )

        try VideoAlignmentReceiptBuilderV1
            .validate(
                receipt,
                sourceDigest: sourceDigest
            )

        let output = receiptURL(for: run)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        try encoder.encode(receipt).write(
            to: output,
            options: .atomic
        )
        return receipt
    }

    private static func loadDurationNS(
        _ url: URL
    ) async throws -> UInt64 {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(
            .duration
        )
        let scaled = CMTimeConvertScale(
            duration,
            timescale: 1_000_000_000,
            method: .roundHalfAwayFromZero
        )
        guard scaled.isNumeric,
              scaled.value > 0
        else {
            throw Action4AlignmentSealError
                .invalidVideoDuration
        }
        return UInt64(scaled.value)
    }
}
