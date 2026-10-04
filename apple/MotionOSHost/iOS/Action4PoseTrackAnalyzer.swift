import Combine
import Foundation
import MotionOSAppleCapture

enum Action4PoseTrackError: LocalizedError {
    case missingExternalVideo
    case missingAlignment
    case sourceHashMismatch
    case insufficientPoseEvidence
    case stalePoseTrack

    var errorDescription: String? {
        switch self {
        case .missingExternalVideo:
            "Import the Action 4 original before building its pose track."
        case .missingAlignment:
            "Review and seal Action 4 temporal alignment before building synchronized pose evidence."
        case .sourceHashMismatch:
            "The Action 4 movie no longer matches the source bound to the sealed alignment."
        case .insufficientPoseEvidence:
            "MotionOS could not recover enough Action 4 body-pose frames for a useful track."
        case .stalePoseTrack:
            "The saved Action 4 pose track no longer matches this run or source movie."
        }
    }
}

enum Action4PoseTrackAnalyzer {
    static let artifactFilename =
        "action4-pose-track.json"
    static let sampleIntervalSeconds = 0.10
    static let minimumUsefulFrameCount = 10

    static func artifactURL(
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

    static func loadTrack(
        for run: ProductRunRecord
    ) throws -> ExternalVideoPoseTrack? {
        let url = artifactURL(for: run)
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return nil
        }

        let track = try JSONDecoder().decode(
            ExternalVideoPoseTrack.self,
            from: Data(contentsOf: url)
        )
        guard track.schemaVersion
                == ExternalVideoPoseTrack
                    .schemaVersion,
              track.runID == run.runID,
              track.sourceID == "action4"
        else {
            throw Action4PoseTrackError
                .stalePoseTrack
        }

        if let expected =
                run.productManifest?
                    .externalCameraSHA256,
           track.sourceVideoSHA256
                != expected {
            throw Action4PoseTrackError
                .stalePoseTrack
        }

        if let alignment =
                try Action4AlignmentSealer
                    .loadReceipt(for: run),
           track.sourceVideoSHA256
                != alignment.sourceVideo.sha256 {
            throw Action4PoseTrackError
                .stalePoseTrack
        }

        return track
    }

    static func analyze(
        run: ProductRunRecord,
        progress:
            (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExternalVideoPoseTrack {
        guard let externalURL =
                run.externalVideoURL
        else {
            throw Action4PoseTrackError
                .missingExternalVideo
        }
        guard let alignment =
                try Action4AlignmentSealer
                    .loadReceipt(for: run)
        else {
            throw Action4PoseTrackError
                .missingAlignment
        }

        progress?(0.02)

        let digest =
            try await Task.detached(
                priority: .utility
            ) {
                try FileEvidence.digest(
                    externalURL
                )
            }
            .value

        guard digest.sha256
                == alignment.sourceVideo.sha256,
              digest.byteCount
                == alignment.sourceVideo.byteCount
        else {
            throw Action4PoseTrackError
                .sourceHashMismatch
        }
        if let expected =
                run.productManifest?
                    .externalCameraSHA256,
           digest.sha256 != expected {
            throw Action4PoseTrackError
                .sourceHashMismatch
        }

        try Task.checkCancellation()
        progress?(0.08)

        let result =
            try await Action4VideoPoseExtractor
                .extract(
                    from: externalURL,
                    sampleIntervalSeconds:
                        sampleIntervalSeconds
                ) { value in
                    progress?(
                        0.08
                            + 0.86
                                * min(
                                    1,
                                    max(0, value)
                                )
                    )
                }

        guard result.poses.count
                >= minimumUsefulFrameCount
        else {
            throw Action4PoseTrackError
                .insufficientPoseEvidence
        }

        let frames = result.poses.map {
            sample in
            ExternalVideoPoseFrame(
                sourcePTSNS: sample.timeNS,
                joints:
                    sample.joints.values
                        .sorted {
                            $0.id < $1.id
                        },
                indoBoardEquipment:
                    sample.indoBoardEquipment,
                visibleFiducials:
                    sample.visibleFiducials
            )
        }

        let track = ExternalVideoPoseTrack(
            runID: run.runID,
            sourceID: "action4",
            sourceVideoSHA256:
                digest.sha256,
            sourceVideoByteCount:
                digest.byteCount,
            sourceDurationNS:
                alignment.sourceVideo.durationNS,
            analyzerID:
                "apple.vision.VNDetectHumanBodyPoseRequest",
            analyzerVersion:
                "motionos-action4-pose-v1",
            sampleIntervalSeconds:
                sampleIntervalSeconds,
            coordinateFrame:
                "source_image_normalized_origin_lower_left_after_orientation",
            frames: frames,
            createdAtUTC:
                ISO8601DateFormatter()
                    .string(from: Date())
        )

        try Task.checkCancellation()
        let output = artifactURL(for: run)
        try FileManager.default.createDirectory(
            at:
                output
                    .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        try encoder.encode(track).write(
            to: output,
            options: .atomic
        )

        progress?(1)
        return track
    }
}

@MainActor
final class Action4PoseTrackController:
    ObservableObject {
    enum Phase: String {
        case idle
        case analyzing
        case ready
        case failed
    }

    @Published private(set) var phase:
        Phase = .idle
    @Published private(set) var progress:
        Double = 0
    @Published private(set) var track:
        ExternalVideoPoseTrack?
    @Published private(set) var errorMessage:
        String?

    private var analysisTask:
        Task<Void, Never>?

    func loadExisting(
        run: ProductRunRecord
    ) {
        guard phase != .analyzing else {
            return
        }

        do {
            track =
                try Action4PoseTrackAnalyzer
                    .loadTrack(for: run)
            phase =
                track == nil
                    ? .idle
                    : .ready
            progress =
                track == nil
                    ? 0
                    : 1
            errorMessage = nil
        } catch {
            track = nil
            phase = .failed
            progress = 0
            errorMessage =
                error.localizedDescription
        }
    }

    func startAnalysis(
        run: ProductRunRecord
    ) {
        guard phase != .analyzing else {
            return
        }

        analysisTask?.cancel()
        phase = .analyzing
        progress = 0
        errorMessage = nil

        analysisTask = Task {
            [weak self] in
            do {
                let value =
                    try await Action4PoseTrackAnalyzer
                        .analyze(
                            run: run
                        ) { value in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.phase
                                        == .analyzing
                                else {
                                    return
                                }
                                self.progress =
                                    min(
                                        1,
                                        max(
                                            self.progress,
                                            value
                                        )
                                    )
                            }
                        }

                guard !Task.isCancelled,
                      let self
                else {
                    return
                }
                self.track = value
                self.progress = 1
                self.phase = .ready
                self.analysisTask = nil
            } catch is CancellationError {
                guard let self else {
                    return
                }
                self.phase =
                    self.track == nil
                        ? .idle
                        : .ready
                self.progress =
                    self.track == nil
                        ? 0
                        : 1
                self.analysisTask = nil
            } catch {
                guard let self else {
                    return
                }
                self.track = nil
                self.progress = 0
                self.phase = .failed
                self.errorMessage =
                    error.localizedDescription
                self.analysisTask = nil
            }
        }
    }

    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        if phase == .analyzing {
            phase =
                track == nil
                    ? .idle
                    : .ready
            progress =
                track == nil
                    ? 0
                    : 1
        }
    }
}
