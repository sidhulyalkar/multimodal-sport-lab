import AVFoundation
import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class VisionLabController: ObservableObject {
    static let minimumSyncLandmarkCount = 3
    enum Phase: String {
        case idle
        case armed
        case capturing
        case sealed
        case failed
    }

    enum ExternalPosePhase: String {
        case idle
        case processing
        case ready
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionID: String?
    @Published private(set) var createdAtUTC: String?
    @Published var action4RecordingConfirmed = false
    @Published var coachingCondition: CoachingCondition = .feedbackDisabled
    @Published private(set) var syncLandmarks: [SyncLandmark] = []
    @Published private(set) var acknowledgedSyncLandmarkIDs: Set<String> = []
    @Published private(set) var mediaArtifacts: [CapturedMediaArtifact] = []
    @Published private(set) var derivedArtifacts: [DerivedEvidenceArtifact] = []
    @Published private(set) var action4PosePhase: ExternalPosePhase = .idle
    @Published private(set) var action4PoseFrameCount: UInt64 = 0
    @Published private(set) var action4PoseCount: UInt64 = 0
    @Published private(set) var manifestURL: URL?
    @Published private(set) var flashGeneration: UInt64 = 0
    @Published private(set) var errorMessage: String?

    private let syncCueEmitter = SyncCueEmitter()
    private let externalPoseProcessor = ExternalVideoPose2DProcessor()
    private var iPhoneCameraSourceID = "iphone-rear"
    private var iPhoneCameraDisplayName = "iPhone rear camera"

    var cameraSources: [CameraSource] {
        [
        CameraSource(
            sourceID: iPhoneCameraSourceID,
            displayName: iPhoneCameraDisplayName,
            kind: .builtIn,
            clockDomain: "avcapture-pts",
            timestampBasis: "avcapture_presentation_timestamp",
            supportsLiveFrames: true,
            supportsRemoteControl: true,
            capabilities: [
                "live_preview",
                "vision_pose",
                "camera_intrinsics",
            ]
        ),
        CameraSource(
            sourceID: "dji-action4",
            displayName: "DJI Osmo Action 4",
            kind: .externalRecorded,
            clockDomain: "action4-video-pts",
            timestampBasis: "container_video_pts",
            supportsLiveFrames: false,
            supportsRemoteControl: false,
            capabilities: [
                "4k",
                "timecode",
                "wide_fov",
                "manual_import",
                "offline_vision_pose2d",
            ]
        ),
        ]
    }

    func bindIPhoneCamera(
        _ configuration: CameraCaptureConfiguration
    ) {
        iPhoneCameraSourceID = configuration.uniqueID
        iPhoneCameraDisplayName = configuration.localizedName
    }

    @discardableResult
    func armSession() -> String {
        let id = Self.makeSessionID()
        sessionID = id
        createdAtUTC = ISO8601DateFormatter().string(from: Date())
        phase = .armed
        action4RecordingConfirmed = false
        syncLandmarks = []
        acknowledgedSyncLandmarkIDs = []
        mediaArtifacts = []
        derivedArtifacts = []
        action4PosePhase = .idle
        action4PoseFrameCount = 0
        action4PoseCount = 0
        manifestURL = nil
        iPhoneCameraSourceID = "iphone-rear"
        iPhoneCameraDisplayName = "iPhone rear camera"
        errorMessage = nil
        return id
    }

    func markCapturing() {
        guard sessionID != nil else {
            fail(VisionLabError.sessionNotArmed)
            return
        }
        phase = .capturing
    }

    @discardableResult
    func emitSyncLandmark() -> SyncLandmark? {
        guard let sessionID,
              phase == .capturing || phase == .armed
        else {
            fail(VisionLabError.sessionNotArmed)
            return nil
        }

        let landmark = SyncLandmark(
            landmarkID: "sync-\(syncLandmarks.count + 1)-\(UUID().uuidString.prefix(6).lowercased())",
            sessionID: sessionID,
            kind: .wholeBodyImpulse,
            hostMonotonicTimeNS: MonotonicClock.nowNS(),
            createdAtUnixMS: Self.nowUnixMS(),
            note: (
                "Audio chirp + iPhone flash + Watch haptic; perform one "
                    + "sharp whole-body/board impulse immediately."
            )
        )
        syncLandmarks.append(landmark)
        return landmark
    }

    func emitLocalSyncSignals() {
        flashGeneration &+= 1
        do {
            try syncCueEmitter.emitChirp()
        } catch {
            errorMessage = (
                "SYNC was sent to Watch, but the iPhone chirp failed: "
                    + error.localizedDescription
            )
        }
    }

    func acknowledgeSyncLandmark(
        landmarkID: String,
        visionSessionID: String
    ) {
        guard visionSessionID == sessionID,
              syncLandmarks.contains(
                where: { $0.landmarkID == landmarkID }
              )
        else {
            return
        }
        acknowledgedSyncLandmarkIDs.insert(landmarkID)
        errorMessage = nil

        if phase == .sealed {
            do {
                _ = try sealSession()
            } catch {
                errorMessage = (
                    "Watch SYNC was acknowledged, but MotionOS could not "
                        + "refresh the sealed vision sidecar: "
                        + error.localizedDescription
                )
            }
        }
    }

    func discardUnacknowledgedSyncLandmark(
        landmarkID: String,
        message: String
    ) {
        guard !acknowledgedSyncLandmarkIDs.contains(landmarkID) else {
            return
        }
        syncLandmarks.removeAll {
            $0.landmarkID == landmarkID
        }
        errorMessage = message
    }

    func importAction4Video(_ sourceURL: URL) throws {
        guard let sessionID else {
            throw VisionLabError.sessionNotArmed
        }

        let gainedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if gainedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sessionDirectory = try makeSessionDirectory(sessionID: sessionID)
        let externalDirectory = sessionDirectory
            .appendingPathComponent("external", isDirectory: true)
            .appendingPathComponent("dji-action4", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )

        if let previous = mediaArtifacts.first(
            where: { $0.sourceID == "dji-action4" }
        ) {
            let previousURL = sessionDirectory.appendingPathComponent(
                previous.relativePath
            )
            try? FileManager.default.removeItem(at: previousURL)
        }

        let originalName = sourceURL.lastPathComponent
        let destination = externalDirectory.appendingPathComponent(
            "\(UUID().uuidString.prefix(8).lowercased())-\(originalName)"
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let evidence = try FileEvidence.digest(destination)
        let relativePath = destination.path.replacingOccurrences(
            of: sessionDirectory.path + "/",
            with: ""
        )

        let derivedDirectory = sessionDirectory
            .appendingPathComponent("derived", isDirectory: true)
            .appendingPathComponent("dji-action4", isDirectory: true)
        try? FileManager.default.removeItem(at: derivedDirectory)
        derivedArtifacts.removeAll { $0.sourceID == "dji-action4" }
        action4PosePhase = .idle
        action4PoseFrameCount = 0
        action4PoseCount = 0

        mediaArtifacts.removeAll { $0.sourceID == "dji-action4" }
        mediaArtifacts.append(
            CapturedMediaArtifact(
                sourceID: "dji-action4",
                relativePath: relativePath,
                originalFilename: originalName,
                sha256: evidence.sha256,
                byteCount: evidence.byteCount,
                importedAtUTC: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    func processAction4Pose2D() async {
        guard let sessionID,
              let source = mediaArtifacts.first(
                where: { $0.sourceID == "dji-action4" }
              )
        else {
            fail(VisionLabError.action4MediaMissing)
            return
        }

        action4PosePhase = .processing
        errorMessage = nil

        do {
            let sessionDirectory = try makeSessionDirectory(
                sessionID: sessionID
            )
            let sourceURL = sessionDirectory.appendingPathComponent(
                source.relativePath
            )
            let outputDirectory = sessionDirectory
                .appendingPathComponent("derived", isDirectory: true)
                .appendingPathComponent("dji-action4", isDirectory: true)

            let result = try await externalPoseProcessor.process(
                videoURL: sourceURL,
                sessionID: sessionID,
                outputDirectory: outputDirectory
            )

            let journalEvidence = try FileEvidence.digest(
                result.journalURL
            )
            let metadataEvidence = try FileEvidence.digest(
                result.metadataURL
            )
            let generatedAt = ISO8601DateFormatter().string(
                from: Date()
            )

            derivedArtifacts.removeAll {
                $0.sourceID == "dji-action4"
                    && (
                        $0.kind == "pose2d_journal"
                            || $0.kind == "pose2d_metadata"
                    )
            }
            derivedArtifacts.append(
                DerivedEvidenceArtifact(
                    artifactID: "action4-pose2d-journal",
                    sourceID: "dji-action4",
                    kind: "pose2d_journal",
                    relativePath: Self.relativePath(
                        result.journalURL,
                        under: sessionDirectory
                    ),
                    sha256: journalEvidence.sha256,
                    byteCount: journalEvidence.byteCount,
                    generatedAtUTC: generatedAt,
                    sourceMediaSHA256: source.sha256
                )
            )
            derivedArtifacts.append(
                DerivedEvidenceArtifact(
                    artifactID: "action4-pose2d-metadata",
                    sourceID: "dji-action4",
                    kind: "pose2d_metadata",
                    relativePath: Self.relativePath(
                        result.metadataURL,
                        under: sessionDirectory
                    ),
                    sha256: metadataEvidence.sha256,
                    byteCount: metadataEvidence.byteCount,
                    generatedAtUTC: generatedAt,
                    sourceMediaSHA256: source.sha256
                )
            )

            action4PoseFrameCount = result.frameCount
            action4PoseCount = result.poseCount
            action4PosePhase = .ready
            _ = try sealSession()
        } catch {
            action4PosePhase = .failed
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func sealSession() throws -> URL {
        guard let sessionID else {
            throw VisionLabError.sessionNotArmed
        }

        guard let createdAtUTC else {
            throw VisionLabError.sessionNotArmed
        }

        let manifest = VisionSessionManifest(
            sessionID: sessionID,
            sport: "indo_board",
            captureMode: "multiview_calibration",
            createdAtUTC: createdAtUTC,
            cameraSources: cameraSources,
            syncLandmarks: acknowledgedSyncLandmarks,
            mediaArtifacts: mediaArtifacts,
            derivedArtifacts: derivedArtifacts,
            coachingCondition: coachingCondition
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        let directory = try makeSessionDirectory(sessionID: sessionID)
        let url = directory.appendingPathComponent("vision_session.json")
        try data.write(to: url, options: .atomic)

        manifestURL = url
        phase = .sealed
        errorMessage = nil
        return url
    }

    var acknowledgedSyncLandmarks: [SyncLandmark] {
        syncLandmarks.filter {
            acknowledgedSyncLandmarkIDs.contains($0.landmarkID)
        }
    }

    var acknowledgedSyncLandmarkCount: Int {
        acknowledgedSyncLandmarks.count
    }

    var pendingSyncLandmarkCount: Int {
        syncLandmarks.count - acknowledgedSyncLandmarkCount
    }

    var hasMinimumSyncLandmarks: Bool {
        acknowledgedSyncLandmarkCount >= Self.minimumSyncLandmarkCount
    }

    func mediaArtifactURL(
        sourceID: String
    ) -> URL? {
        guard let manifestURL,
              let artifact = mediaArtifacts.first(
                where: { $0.sourceID == sourceID }
              )
        else {
            return nil
        }
        return manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(artifact.relativePath)
    }

    func derivedArtifactURL(
        sourceID: String,
        kind: String
    ) -> URL? {
        guard let manifestURL,
              let artifact = derivedArtifacts.first(
                where: {
                    $0.sourceID == sourceID
                        && $0.kind == kind
                }
              )
        else {
            return nil
        }
        return manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(artifact.relativePath)
    }

    func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = .failed
    }

    private func makeSessionDirectory(sessionID: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("MotionOS", isDirectory: true)
            .appendingPathComponent("Vision", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func relativePath(
        _ url: URL,
        under root: URL
    ) -> String {
        url.path.replacingOccurrences(
            of: root.path + "/",
            with: ""
        )
    }

    private static func makeSessionID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "indo-board-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func nowUnixMS() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000.0))
    }

    enum VisionLabError: LocalizedError {
        case sessionNotArmed
        case action4NotConfirmed
        case action4MediaMissing

        var errorDescription: String? {
            switch self {
            case .sessionNotArmed:
                "Arm an Indo Board vision session first."
            case .action4NotConfirmed:
                "Confirm the Action 4 is recording before coordinated capture."
            case .action4MediaMissing:
                "Import the original Action 4 movie before extracting 2D pose."
            }
        }
    }
}

@MainActor
private final class SyncCueEmitter {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func emitChirp() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, options: [.mixWithOthers])
        try session.setActive(true)

        if !engine.isRunning {
            try engine.start()
        }

        let durationSeconds = 0.12
        let frequencyHz = 1_200.0
        let frameCount = AVAudioFrameCount(
            format.sampleRate * durationSeconds
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw VisionCueError.cannotAllocateAudioBuffer
        }
        buffer.frameLength = frameCount

        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / format.sampleRate
                let envelope = sin(.pi * min(1, t / 0.01))
                    * sin(.pi * min(1, (durationSeconds - t) / 0.01))
                channel[frame] = Float(
                    0.35 * envelope * sin(2 * .pi * frequencyHz * t)
                )
            }
        }

        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    private enum VisionCueError: LocalizedError {
        case cannotAllocateAudioBuffer

        var errorDescription: String? {
            "MotionOS could not allocate the synchronization chirp buffer."
        }
    }
}
