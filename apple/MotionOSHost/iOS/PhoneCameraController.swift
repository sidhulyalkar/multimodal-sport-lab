import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MotionOSAppleCapture
import UIKit

final class PhoneCameraController: NSObject, ObservableObject, @unchecked Sendable {
    enum State: String {
        case idle
        case authorizing
        case configuring
        case previewing
        case starting
        case recording
        case stopping
        case ended
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var frameCount: UInt64 = 0
    @Published private(set) var poseCount: UInt64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestVideoURL: URL?
    @Published private(set) var latestJournalURL: URL?
    @Published private(set) var latestMetadataURL: URL?

    private let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.sidhulyalkar.motionos.camera.session"
    )
    private let sampleQueue = DispatchQueue(
        label: "com.sidhulyalkar.motionos.camera.samples"
    )
    private let journalQueue = DispatchQueue(
        label: "com.sidhulyalkar.motionos.camera.journal"
    )
    private let stateLock = NSLock()
    private let inFlightSamples = DispatchGroup()

    private var configured = false
    private var cameraDevice: AVCaptureDevice?
    private var activeSessionID: String?
    private var activeVideoURL: URL?
    private var activeJournalURL: URL?
    private var activeMetadataURL: URL?
    private var metadata: [String: Any] = [:]
    private var journalHandle: FileHandle?
    private var frameSequence: UInt64 = 0
    private var poseSequence: UInt64 = 0
    private var lastPoseAttemptPTSNS: UInt64?
    private var recordedFrameCount: UInt64 = 0
    private var recordedPoseCount: UInt64 = 0

    var previewSession: AVCaptureSession { captureSession }

    private let requestedFPS = 30.0
    private let requestedPoseHz = 10.0
    private let deviceID = "iphone-camera"

    override init() {
        super.init()
        cameraAuthorized = AVCaptureDevice.authorizationStatus(
            for: .video
        ) == .authorized
    }

    @MainActor
    func requestAuthorization() async {
        state = .authorizing
        errorMessage = nil

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
            state = .idle
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAuthorized = granted
            state = granted ? .idle : .failed
            if !granted {
                errorMessage = "Camera access was not granted."
            }
        default:
            cameraAuthorized = false
            state = .failed
            errorMessage = "Camera access is unavailable in Settings."
        }
    }

    @MainActor
    func preparePreview() {
        errorMessage = nil
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        else {
            state = .failed
            errorMessage = "Authorize camera access before preview."
            return
        }

        do {
            if !configured {
                state = .configuring
                try configureSession()
            }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                DispatchQueue.main.async {
                    if self.state != .recording && self.state != .starting {
                        self.state = .previewing
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    @MainActor
    func stopPreview() {
        guard state == .previewing else { return }
        state = .stopping
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                if self.state == .stopping {
                    self.state = .idle
                }
            }
        }
    }

    @MainActor
    func startEvidenceCapture() {
        errorMessage = nil
        latestVideoURL = nil
        latestJournalURL = nil
        latestMetadataURL = nil

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        else {
            state = .failed
            errorMessage = "Authorize camera access before recording."
            return
        }

        do {
            if !configured {
                state = .configuring
                try configureSession()
            }
            let evidence = try prepareEvidenceFiles()
            state = .starting

            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                self.movieOutput.startRecording(
                    to: evidence.videoURL,
                    recordingDelegate: self
                )
            }
        } catch {
            fail(error)
        }
    }

    @MainActor
    func stopEvidenceCapture() {
        guard state == .recording || state == .starting else { return }
        state = .stopping
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                self.finishCapture(error: nil)
            }
        }
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.noBackCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddCameraInput
        }
        captureSession.addInput(input)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoDataOutput.setSampleBufferDelegate(
            self,
            queue: sampleQueue
        )
        guard captureSession.canAddOutput(videoDataOutput) else {
            throw CameraError.cannotAddVideoDataOutput
        }
        captureSession.addOutput(videoDataOutput)

        guard captureSession.canAddOutput(movieOutput) else {
            throw CameraError.cannotAddMovieOutput
        }
        captureSession.addOutput(movieOutput)

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if let range = camera.activeFormat.videoSupportedFrameRateRanges.first,
           range.minFrameRate <= requestedFPS,
           requestedFPS <= range.maxFrameRate {
            let duration = CMTime(
                value: 1,
                timescale: CMTimeScale(requestedFPS)
            )
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        }

        cameraDevice = camera
        configured = true
    }

    private struct EvidenceFiles: Sendable {
        let sessionID: String
        let root: URL
        let videoURL: URL
        let journalURL: URL
        let metadataURL: URL
    }

    private func prepareEvidenceFiles() throws -> EvidenceFiles {
        let sessionID = "camera-" + UUID().uuidString.lowercased()
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents
            .appendingPathComponent("CameraEvidence", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let videoURL = root.appendingPathComponent("camera.mov")
        let journalURL = root.appendingPathComponent("camera.jsonl")
        let metadataURL = root.appendingPathComponent("camera-metadata.json")

        _ = manager.createFile(atPath: journalURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()

        let dimensions = cameraDevice.map {
            CMVideoFormatDescriptionGetDimensions(
                $0.activeFormat.formatDescription
            )
        }

        let started = ISO8601DateFormatter().string(from: Date())
        let camera = cameraDevice
        let sidecar: [String: Any] = [
            "schema_version": "motionos.camera.v1",
            "session_id": sessionID,
            "started_at_utc": started,
            "created_at_utc": started,
            "athlete_id": "local-athlete",
            "placement": "tripod_side_view",
            "orientation": "landscape_right_sensor_native",
            "video_filename": videoURL.lastPathComponent,
            "timestamp_authority": "cmsamplebuffer_presentation_time",
            "host_callback_timestamp_authority": "diagnostic_arrival_only",
            "device": [
                "model": UIDevice.current.model,
                "localized_model": UIDevice.current.localizedModel,
                "system_name": UIDevice.current.systemName,
                "system_version": UIDevice.current.systemVersion
            ],
            "camera": [
                "localized_name": camera?.localizedName ?? "unknown",
                "unique_id": camera?.uniqueID ?? "unknown",
                "position": "back",
                "width_px": Int(dimensions?.width ?? 0),
                "height_px": Int(dimensions?.height ?? 0),
                "requested_fps": requestedFPS
            ],
            "pose": [
                "requested_hz": requestedPoseHz,
                "framework": "Vision",
                "request": "VNDetectHumanBodyPose3DRequest",
                "coordinate_basis": "vision_root_relative_meters"
            ]
        ]

        try writeMetadata(sidecar, to: metadataURL)

        stateLock.lock()
        activeSessionID = sessionID
        activeVideoURL = videoURL
        activeJournalURL = journalURL
        activeMetadataURL = metadataURL
        metadata = sidecar
        journalHandle = handle
        frameSequence = 0
        poseSequence = 0
        lastPoseAttemptPTSNS = nil
        recordedFrameCount = 0
        recordedPoseCount = 0
        stateLock.unlock()

        return EvidenceFiles(
            sessionID: sessionID,
            root: root,
            videoURL: videoURL,
            journalURL: journalURL,
            metadataURL: metadataURL
        )
    }

    private func writeMetadata(
        _ metadata: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func presentationTimeNS(
        _ sampleBuffer: CMSampleBuffer
    ) -> UInt64? {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.timescale != 0 else { return nil }
        let scaled = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .default
        )
        guard scaled.value >= 0 else { return nil }
        return UInt64(scaled.value)
    }

    private struct FrameReservation {
        let sessionID: String
        let frameSequence: UInt64
        let poseAttempted: Bool
    }

    private func reserveFrame(
        ptsNS: UInt64
    ) -> FrameReservation? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID = activeSessionID else { return nil }

        let poseIntervalNS = UInt64(
            (1_000_000_000.0 / requestedPoseHz).rounded()
        )
        let attemptPose: Bool
        if let lastPoseAttemptPTSNS {
            attemptPose = ptsNS >= lastPoseAttemptPTSNS + poseIntervalNS
        } else {
            attemptPose = true
        }
        if attemptPose {
            lastPoseAttemptPTSNS = ptsNS
        }

        let reservation = FrameReservation(
            sessionID: sessionID,
            frameSequence: frameSequence,
            poseAttempted: attemptPose
        )
        frameSequence += 1
        recordedFrameCount += 1
        inFlightSamples.enter()
        return reservation
    }

    private func reservePoseSequence() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let value = poseSequence
        poseSequence += 1
        recordedPoseCount += 1
        return value
    }

    private func appendJournalEvents(
        _ events: [SensorEnvelope]
    ) {
        guard !events.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let lines = try events.map { event -> Data in
                var data = try encoder.encode(event)
                data.append(0x0A)
                return data
            }
            journalQueue.async { [weak self] in
                guard let self else { return }
                do {
                    for data in lines {
                        try self.journalHandle?.write(contentsOf: data)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.fail(error)
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.fail(error)
            }
        }
    }

    private func finishCapture(error: Error?) {
        stateLock.lock()
        activeSessionID = nil
        let videoURL = activeVideoURL
        let journalURL = activeJournalURL
        let metadataURL = activeMetadataURL
        let frames = recordedFrameCount
        let poses = recordedPoseCount
        var finalMetadata = metadata
        stateLock.unlock()

        if captureSession.isRunning {
            captureSession.stopRunning()
        }

        // reserveFrame() enters this group while holding stateLock. Because
        // activeSessionID is cleared above under the same lock, no new sample
        // can enter after this point. Wait for Vision/encoding work that had
        // already reserved a frame before closing the journal.
        inFlightSamples.wait()

        journalQueue.sync {
            do {
                try journalHandle?.synchronize()
                try journalHandle?.close()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error)
                }
            }
            journalHandle = nil
        }

        finalMetadata["ended_at_utc"] = ISO8601DateFormatter().string(
            from: Date()
        )
        finalMetadata["frame_event_count"] = frames
        finalMetadata["pose_event_count"] = poses

        if let metadataURL {
            do {
                try writeMetadata(finalMetadata, to: metadataURL)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error)
                }
                return
            }
        }

        stateLock.lock()
        metadata = finalMetadata
        activeVideoURL = nil
        activeJournalURL = nil
        activeMetadataURL = nil
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameCount = frames
            self.poseCount = poses
            self.latestVideoURL = videoURL
            self.latestJournalURL = journalURL
            self.latestMetadataURL = metadataURL
            if let error {
                self.state = .failed
                self.errorMessage = error.localizedDescription
            } else {
                self.state = .ended
            }
        }
    }

    private func publishCounts() {
        stateLock.lock()
        let frames = recordedFrameCount
        let poses = recordedPoseCount
        stateLock.unlock()

        if frames % 15 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.frameCount = frames
                self?.poseCount = poses
            }
        }
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .failed
            self?.errorMessage = error.localizedDescription
        }
    }

    enum CameraError: LocalizedError {
        case noBackCamera
        case cannotAddCameraInput
        case cannotAddVideoDataOutput
        case cannotAddMovieOutput

        var errorDescription: String? {
            switch self {
            case .noBackCamera:
                "No back camera is available."
            case .cannotAddCameraInput:
                "MotionOS could not add the camera input."
            case .cannotAddVideoDataOutput:
                "MotionOS could not add frame analysis output."
            case .cannotAddMovieOutput:
                "MotionOS could not add video recording output."
            }
        }
    }
}

extension PhoneCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard
            let ptsNS = presentationTimeNS(sampleBuffer),
            let reservation = reserveFrame(ptsNS: ptsNS)
        else {
            return
        }
        defer { inFlightSamples.leave() }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        var posePayload: [String: JSONValue]?
        if reservation.poseAttempted {
            do {
                posePayload = try Pose3DExtractor.extract(
                    from: pixelBuffer,
                    orientation: .up
                )
            } catch {
                posePayload = nil
            }
        }

        let detected = posePayload != nil
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let frame = SensorEnvelope(
            sessionID: reservation.sessionID,
            deviceID: deviceID,
            stream: "/camera/frame",
            sequence: reservation.frameSequence,
            deviceTimeNS: ptsNS,
            payload: [
                "video_pts_ns": .number(Double(ptsNS)),
                "host_callback_monotonic_ns": .number(
                    Double(MonotonicClock.nowNS())
                ),
                "width_px": .number(Double(width)),
                "height_px": .number(Double(height)),
                "pixel_format": .string(
                    String(format: "0x%08X", pixelFormat)
                ),
                "pose_attempted": .bool(reservation.poseAttempted),
                "pose_detected": .bool(detected),
                "timestamp_basis": .string(
                    "cmsamplebuffer_presentation_time"
                ),
                "source": .string("iphone_avcapture_video_data")
            ]
        )

        var events = [frame]
        if var posePayload {
            let poseSequence = reservePoseSequence()
            posePayload["video_pts_ns"] = .number(Double(ptsNS))
            posePayload["timestamp_basis"] = .string(
                "cmsamplebuffer_presentation_time"
            )
            posePayload["source"] = .string(
                "apple_vision_3d_body_pose"
            )

            events.append(
                SensorEnvelope(
                    sessionID: reservation.sessionID,
                    deviceID: deviceID,
                    stream: "/camera/pose3d",
                    sequence: poseSequence,
                    deviceTimeNS: ptsNS,
                    payload: posePayload
                )
            )
        }

        appendJournalEvents(events)
        publishCounts()
    }
}

extension PhoneCameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .recording
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        finishCapture(error: error)
    }
}
