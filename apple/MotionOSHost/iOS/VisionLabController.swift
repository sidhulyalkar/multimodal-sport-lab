import AVFoundation
import Combine
import Foundation
import MotionOSAppleCapture

@MainActor
final class VisionLabController: ObservableObject {
    enum Phase: String {
        case idle
        case armed
        case capturing
        case sealed
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionID: String?
    @Published var action4RecordingConfirmed = false
    @Published var coachingCondition: CoachingCondition = .feedbackDisabled
    @Published private(set) var syncLandmarks: [SyncLandmark] = []
    @Published private(set) var mediaArtifacts: [CapturedMediaArtifact] = []
    @Published private(set) var manifestURL: URL?
    @Published private(set) var flashGeneration: UInt64 = 0
    @Published private(set) var errorMessage: String?

    private let syncCueEmitter = SyncCueEmitter()

    let cameraSources = [
        CameraSource(
            sourceID: "iphone-rear",
            displayName: "iPhone rear camera",
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
            ]
        ),
    ]

    @discardableResult
    func armSession() -> String {
        let id = Self.makeSessionID()
        sessionID = id
        phase = .armed
        action4RecordingConfirmed = false
        syncLandmarks = []
        mediaArtifacts = []
        manifestURL = nil
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
        flashGeneration &+= 1

        do {
            try syncCueEmitter.emitChirp()
        } catch {
            errorMessage = (
                "Sync landmark recorded, but audio chirp failed: "
                    + error.localizedDescription
            )
        }
        return landmark
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

    @discardableResult
    func sealSession() throws -> URL {
        guard let sessionID else {
            throw VisionLabError.sessionNotArmed
        }

        let manifest = VisionSessionManifest(
            sessionID: sessionID,
            sport: "indo_board",
            captureMode: "multiview_calibration",
            createdAtUTC: Self.createdAtUTC(from: sessionID),
            cameraSources: cameraSources,
            syncLandmarks: syncLandmarks,
            mediaArtifacts: mediaArtifacts,
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

    private static func makeSessionID() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "indo-board-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func createdAtUTC(from sessionID: String) -> String {
        // The identifier keeps human-readable capture provenance, while this
        // field remains a standards-compliant timestamp.
        ISO8601DateFormatter().string(from: Date())
    }

    private static func nowUnixMS() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000.0))
    }

    enum VisionLabError: LocalizedError {
        case sessionNotArmed
        case action4NotConfirmed

        var errorDescription: String? {
            switch self {
            case .sessionNotArmed:
                "Arm an Indo Board vision session first."
            case .action4NotConfirmed:
                "Confirm the Action 4 is recording before coordinated capture."
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
