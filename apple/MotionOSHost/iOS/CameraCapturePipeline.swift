import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import MotionOSAppleCapture
import simd

struct CameraCaptureConfiguration: Sendable {
    let uniqueID: String
    let localizedName: String
    let deviceType: String
    let position: String
    let formatWidth: Int32
    let formatHeight: Int32
    let minFrameRate: Double
    let maxFrameRate: Double
    let intrinsicDeliveryEnabled: Bool

    func metadataObject() -> [String: Any] {
        [
            "unique_id": uniqueID,
            "localized_name": localizedName,
            "device_type": deviceType,
            "position": position,
            "format_width": Int(formatWidth),
            "format_height": Int(formatHeight),
            "min_supported_frame_rate": minFrameRate,
            "max_supported_frame_rate": maxFrameRate,
            "intrinsic_matrix_delivery_enabled": intrinsicDeliveryEnabled,
        ]
    }
}

struct CameraLiveCaptureStats: Equatable, Sendable {
    let deliveredFrames: UInt64
    let writtenFrames: UInt64
    let writerBackpressureFrames: UInt64
    let droppedFrames: UInt64
    let poseScheduledFrames: UInt64
    let poseDetectedFrames: UInt64
    let poseNoResultFrames: UInt64
    let poseErrorFrames: UInt64
    let firstPTSNS: UInt64?
    let lastPTSNS: UInt64?

    var durationSeconds: Double {
        guard let firstPTSNS,
              let lastPTSNS,
              lastPTSNS > firstPTSNS
        else {
            return 0
        }
        return Double(lastPTSNS - firstPTSNS) / 1_000_000_000.0
    }

    var effectiveDeliveredFPS: Double? {
        guard deliveredFrames >= 2,
              durationSeconds > 0
        else {
            return nil
        }
        return Double(deliveredFrames - 1) / durationSeconds
    }

    var writtenFraction: Double? {
        guard deliveredFrames > 0 else { return nil }
        return Double(writtenFrames) / Double(deliveredFrames)
    }

    var poseSuccessFraction: Double? {
        guard poseScheduledFrames > 0 else { return nil }
        return Double(poseDetectedFrames) / Double(poseScheduledFrames)
    }
}

struct CameraEvidenceBundle: Sendable {
    let directory: URL
    let videoURL: URL
    let journalURL: URL
    let metadataURL: URL
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case videoConnectionUnavailable
    case writerSettingsUnavailable
    case recordingAlreadyActive
    case recordingNotActive
    case invalidPresentationTime
    case writerFailed(String)
    case journalClosed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "No rear wide-angle camera is available."
        case .cannotAddInput:
            "The rear camera input could not be added to the capture session."
        case .cannotAddOutput:
            "The video-data output could not be added to the capture session."
        case .videoConnectionUnavailable:
            "The capture session has no video connection."
        case .writerSettingsUnavailable:
            "AVFoundation did not provide compatible movie-writer settings."
        case .recordingAlreadyActive:
            "A camera evidence recording is already active."
        case .recordingNotActive:
            "No camera evidence recording is active."
        case .invalidPresentationTime:
            "A camera frame arrived without a usable presentation timestamp."
        case .writerFailed(let message):
            "The camera movie writer failed: \(message)"
        case .journalClosed:
            "The camera frame journal is closed."
        }
    }
}

final class CameraCapturePipeline:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    static let schemaVersion = "motionos.camera.v1"
    static let poseStride: UInt64 = 3

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(
        label: "motionos.camera.session"
    )
    private let outputQueue = DispatchQueue(
        label: "motionos.camera.output"
    )

    private var configuration: CameraCaptureConfiguration?
    private var configured = false

    // outputQueue-confined recording state
    private var sessionID: String?
    private var hostModel = ""
    private var hostOSVersion = ""
    private var directoryURL: URL?
    private var videoURL: URL?
    private var journalURL: URL?
    private var metadataURL: URL?
    private var journalHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerStarted = false
    private var frameSequence: UInt64 = 0
    private var poseSequence: UInt64 = 0
    private var dropSequence: UInt64 = 0
    private var deliveredFrameCount: UInt64 = 0
    private var writtenFrameCount: UInt64 = 0
    private var writerBackpressureCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var poseScheduledCount: UInt64 = 0
    private var poseDetectedCount: UInt64 = 0
    private var poseNoResultCount: UInt64 = 0
    private var poseErrorCount: UInt64 = 0
    private var firstPTSNS: UInt64?
    private var lastPTSNS: UInt64?
    private var firstIntrinsicMatrix: [[Double]]?
    private var lastIntrinsicMatrix: [[Double]]?
    private var encoder = JSONEncoder()

    override init() {
        encoder.outputFormatting = [.sortedKeys]
        super.init()
    }

    var captureSessionForPreview: AVCaptureSession {
        captureSession
    }

    func startPreview() async throws -> CameraCaptureConfiguration {
        let configuration = try await configure()

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                continuation.resume()
            }
        }
        return configuration
    }

    func configure() async throws -> CameraCaptureConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let configuration = try self.configureOnSessionQueue()
                    continuation.resume(returning: configuration)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording(
        sessionID: String,
        hostModel: String,
        hostOSVersion: String
    ) async throws -> CameraCaptureConfiguration {
        let configuration = try await configure()

        try await withCheckedThrowingContinuation { continuation in
            outputQueue.async {
                do {
                    try self.prepareRecordingOnOutputQueue(
                        sessionID: sessionID,
                        hostModel: hostModel,
                        hostOSVersion: hostOSVersion
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                continuation.resume()
            }
        }

        return configuration
    }

    func liveStats() async -> CameraLiveCaptureStats {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                continuation.resume(returning: self.makeLiveStats())
            }
        }
    }

    func stopRecording() async throws -> CameraEvidenceBundle {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
                continuation.resume()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            outputQueue.async {
                self.finishRecordingOnOutputQueue { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func configureOnSessionQueue() throws -> CameraCaptureConfiguration {
        if let configuration, configured {
            return configuration
        }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraCaptureError.cameraUnavailable
        }

        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        captureSession.sessionPreset = .hd1920x1080

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        captureSession.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(
            self,
            queue: outputQueue
        )
        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraCaptureError.cannotAddOutput
        }
        captureSession.addOutput(videoOutput)

        guard let connection = videoOutput.connection(with: .video) else {
            throw CameraCaptureError.videoConnectionUnavailable
        }

        let intrinsicsEnabled: Bool
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            intrinsicsEnabled = true
        } else {
            intrinsicsEnabled = false
        }

        if connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let minRate = ranges.map(\.minFrameRate).min() ?? 0
        let maxRate = ranges.map(\.maxFrameRate).max() ?? 0

        let configuration = CameraCaptureConfiguration(
            uniqueID: device.uniqueID,
            localizedName: device.localizedName,
            deviceType: device.deviceType.rawValue,
            position: String(describing: device.position),
            formatWidth: dimensions.width,
            formatHeight: dimensions.height,
            minFrameRate: minRate,
            maxFrameRate: maxRate,
            intrinsicDeliveryEnabled: intrinsicsEnabled
        )
        self.configuration = configuration
        configured = true
        return configuration
    }

    private func prepareRecordingOnOutputQueue(
        sessionID: String,
        hostModel: String,
        hostOSVersion: String
    ) throws {
        guard self.sessionID == nil else {
            throw CameraCaptureError.recordingAlreadyActive
        }
        guard configured else {
            throw CameraCaptureError.cameraUnavailable
        }

        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents
            .appendingPathComponent("MotionOSCamera", isDirectory: true)
        let directory = root
            .appendingPathComponent(sessionID, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let videoURL = directory.appendingPathComponent("camera.mov")
        let journalURL = directory.appendingPathComponent(
            "camera-frames.jsonl"
        )
        let metadataURL = directory.appendingPathComponent(
            "camera-metadata.json"
        )
        for url in [videoURL, journalURL, metadataURL] {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        }

        guard let settings = videoOutput
            .recommendedVideoSettingsForAssetWriter(writingTo: .mov)
        else {
            throw CameraCaptureError.writerSettingsUnavailable
        }

        let writer = try AVAssetWriter(
            outputURL: videoURL,
            fileType: .mov
        )
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        writerInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(writerInput) else {
            throw CameraCaptureError.writerSettingsUnavailable
        }
        writer.add(writerInput)

        _ = manager.createFile(atPath: journalURL.path, contents: nil)
        let journalHandle = try FileHandle(forWritingTo: journalURL)

        self.sessionID = sessionID
        self.hostModel = hostModel
        self.hostOSVersion = hostOSVersion
        self.directoryURL = directory
        self.videoURL = videoURL
        self.journalURL = journalURL
        self.metadataURL = metadataURL
        self.journalHandle = journalHandle
        self.writer = writer
        self.writerInput = writerInput
        writerStarted = false
        frameSequence = 0
        poseSequence = 0
        dropSequence = 0
        deliveredFrameCount = 0
        writtenFrameCount = 0
        writerBackpressureCount = 0
        droppedFrameCount = 0
        poseScheduledCount = 0
        poseDetectedCount = 0
        poseNoResultCount = 0
        poseErrorCount = 0
        firstPTSNS = nil
        lastPTSNS = nil
        firstIntrinsicMatrix = nil
        lastIntrinsicMatrix = nil
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handleFrame(sampleBuffer)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handleDroppedFrame(sampleBuffer)
    }

    private func handleFrame(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let sessionID,
              let writer,
              let writerInput,
              journalHandle != nil
        else {
            return
        }

        do {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsNS = try presentationTimeNS(pts)

            if !writerStarted {
                guard writer.startWriting() else {
                    throw CameraCaptureError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "startWriting returned false"
                    )
                }
                writer.startSession(atSourceTime: pts)
                writerStarted = true
            }

            let written: Bool
            if writerInput.isReadyForMoreMediaData {
                written = writerInput.append(sampleBuffer)
                if written {
                    writtenFrameCount += 1
                } else {
                    throw CameraCaptureError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "append returned false"
                    )
                }
            } else {
                written = false
                writerBackpressureCount += 1
            }

            deliveredFrameCount += 1
            firstPTSNS = firstPTSNS ?? ptsNS
            lastPTSNS = ptsNS

            let dimensions = frameDimensions(sampleBuffer)
            let intrinsic = intrinsicMatrix(sampleBuffer)
            if let intrinsic {
                firstIntrinsicMatrix = firstIntrinsicMatrix ?? intrinsic
                lastIntrinsicMatrix = intrinsic
            }

            let shouldAnalyzePose =
                frameSequence % Self.poseStride == 0
            var poseStatus = "not_scheduled"
            var posePayload: [String: JSONValue]?

            if shouldAnalyzePose {
                poseScheduledCount += 1
                if let pixelBuffer = CMSampleBufferGetImageBuffer(
                    sampleBuffer
                ) {
                    do {
                        if let pose = try Pose3DExtractor.extract(
                            from: pixelBuffer,
                            orientation: .up
                        ) {
                            poseStatus = "detected"
                            poseDetectedCount += 1
                            posePayload = pose
                        } else {
                            poseStatus = "no_pose"
                            poseNoResultCount += 1
                        }
                    } catch {
                        poseStatus = "vision_error"
                        poseErrorCount += 1
                    }
                } else {
                    poseStatus = "vision_error"
                    poseErrorCount += 1
                }
            }

            var framePayload: [String: JSONValue] = [
                "frame_index": .number(Double(frameSequence)),
                "pts_seconds": .number(CMTimeGetSeconds(pts)),
                "timestamp_basis": .string(
                    "avcapture_presentation_timestamp"
                ),
                "source": .string(
                    "avcapture_video_data_output"
                ),
                "video_written": .bool(written),
                "pose_status": .string(poseStatus),
                "pose_stride": .number(Double(Self.poseStride)),
                "vision_orientation": .string("up"),
                "orientation_policy": .string(
                    "rear_camera_native_landscape"
                ),
                "width_px": .number(Double(dimensions.width)),
                "height_px": .number(Double(dimensions.height)),
            ]
            if let intrinsic {
                framePayload["camera_intrinsic_matrix"] =
                    jsonMatrix(intrinsic)
                framePayload["intrinsic_reference_width_px"] =
                    .number(Double(dimensions.width))
                framePayload["intrinsic_reference_height_px"] =
                    .number(Double(dimensions.height))
            }

            try appendEvent(
                SensorEnvelope(
                    sessionID: sessionID,
                    deviceID: configuration?.uniqueID ?? "iphone-camera",
                    stream: "/camera/frame",
                    sequence: frameSequence,
                    deviceTimeNS: ptsNS,
                    payload: framePayload
                )
            )

            if let posePayload {
                var payload = posePayload
                payload["source_frame_sequence"] =
                    .number(Double(frameSequence))
                payload["source_frame_pts_ns"] =
                    .number(Double(ptsNS))
                payload["timestamp_basis"] = .string(
                    "avcapture_presentation_timestamp"
                )
                payload["source"] = .string(
                    "vision_3d_pose_from_camera_frame"
                )

                try appendEvent(
                    SensorEnvelope(
                        sessionID: sessionID,
                        deviceID:
                            configuration?.uniqueID ?? "iphone-camera",
                        stream: "/camera/pose3d",
                        sequence: poseSequence,
                        deviceTimeNS: ptsNS,
                        payload: payload
                    )
                )
                poseSequence += 1
            }

            frameSequence += 1
        } catch {
            // The controller will detect an invalid final writer state.
            writer.cancelWriting()
        }
    }

    private func handleDroppedFrame(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let sessionID, journalHandle != nil else {
            return
        }

        do {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsNS = try presentationTimeNS(pts)
            droppedFrameCount += 1

            try appendEvent(
                SensorEnvelope(
                    sessionID: sessionID,
                    deviceID: configuration?.uniqueID ?? "iphone-camera",
                    stream: "/camera/drop",
                    sequence: dropSequence,
                    deviceTimeNS: ptsNS,
                    payload: [
                        "timestamp_basis": .string(
                            "avcapture_presentation_timestamp"
                        ),
                        "source": .string(
                            "AVCaptureVideoDataOutput.didDrop"
                        ),
                        "reason": .string(
                            "late_or_output_pipeline_drop"
                        ),
                    ]
                )
            )
            dropSequence += 1
        } catch {
            // A drop-journal failure will be reflected by final evidence
            // counts/hash validation rather than synthesized data.
        }
    }

    private func makeLiveStats() -> CameraLiveCaptureStats {
        CameraLiveCaptureStats(
            deliveredFrames: deliveredFrameCount,
            writtenFrames: writtenFrameCount,
            writerBackpressureFrames: writerBackpressureCount,
            droppedFrames: droppedFrameCount,
            poseScheduledFrames: poseScheduledCount,
            poseDetectedFrames: poseDetectedCount,
            poseNoResultFrames: poseNoResultCount,
            poseErrorFrames: poseErrorCount,
            firstPTSNS: firstPTSNS,
            lastPTSNS: lastPTSNS
        )
    }

    private func finishRecordingOnOutputQueue(
        completion: @escaping (
            Result<CameraEvidenceBundle, Error>
        ) -> Void
    ) {
        guard let sessionID,
              let writer,
              let writerInput,
              let directoryURL,
              let videoURL,
              let journalURL,
              let metadataURL
        else {
            completion(.failure(CameraCaptureError.recordingNotActive))
            return
        }

        if writerStarted, writer.status == .writing {
            writerInput.markAsFinished()
            writer.finishWriting {
                self.outputQueue.async {
                    self.finalizeEvidence(
                        sessionID: sessionID,
                        writer: writer,
                        directoryURL: directoryURL,
                        videoURL: videoURL,
                        journalURL: journalURL,
                        metadataURL: metadataURL,
                        completion: completion
                    )
                }
            }
        } else {
            finalizeEvidence(
                sessionID: sessionID,
                writer: writer,
                directoryURL: directoryURL,
                videoURL: videoURL,
                journalURL: journalURL,
                metadataURL: metadataURL,
                completion: completion
            )
        }
    }

    private func finalizeEvidence(
        sessionID: String,
        writer: AVAssetWriter,
        directoryURL: URL,
        videoURL: URL,
        journalURL: URL,
        metadataURL: URL,
        completion: @escaping (
            Result<CameraEvidenceBundle, Error>
        ) -> Void
    ) {
        do {
            try journalHandle?.synchronize()
            try journalHandle?.close()
            journalHandle = nil

            guard writer.status == .completed else {
                throw CameraCaptureError.writerFailed(
                    writer.error?.localizedDescription
                        ?? "writer did not complete"
                )
            }

            let metadata: [String: Any] = [
                "schema_version": Self.schemaVersion,
                "session_id": sessionID,
                "closed_at_utc": ISO8601DateFormatter().string(
                    from: Date()
                ),
                "host": [
                    "model": hostModel,
                    "os_version": hostOSVersion,
                ],
                "camera": configuration?.metadataObject() ?? [:],
                "video": [
                    "filename": videoURL.lastPathComponent,
                    "container": "mov",
                    "codec_policy": "avfoundation_recommended",
                    "timestamp_basis":
                        "avcapture_presentation_timestamp",
                    "orientation_policy":
                        "rear_camera_native_landscape",
                ],
                "pose": [
                    "request": "VNDetectHumanBodyPose3DRequest",
                    "stride_delivered_frames": Int(Self.poseStride),
                    "vision_orientation": "up",
                    "joint_coordinate_frame":
                        "vision_root_joint_relative_meters",
                    "camera_geometry":
                        "cameraOriginMatrix preserved per pose",
                    "interpolation": "none",
                ],
                "counts": [
                    "delivered_frames": Int(deliveredFrameCount),
                    "written_frames": Int(writtenFrameCount),
                    "writer_backpressure_frames":
                        Int(writerBackpressureCount),
                    "avcapture_dropped_frames":
                        Int(droppedFrameCount),
                    "pose_scheduled_frames":
                        Int(poseScheduledCount),
                    "pose_detected_frames":
                        Int(poseDetectedCount),
                    "pose_no_result_frames":
                        Int(poseNoResultCount),
                    "pose_error_frames":
                        Int(poseErrorCount),
                ],
                "pts_ns": [
                    "first": firstPTSNS as Any,
                    "last": lastPTSNS as Any,
                ],
                "first_intrinsic_matrix":
                    firstIntrinsicMatrix as Any,
                "last_intrinsic_matrix":
                    lastIntrinsicMatrix as Any,
                "provenance": [
                    "camera_mov_sha256": try sha256(videoURL),
                    "camera_frames_jsonl_sha256":
                        try sha256(journalURL),
                ],
                "claim_boundary":
                    "Vision 3D pose is teacher/validation evidence; "
                    + "root-relative joints are not world/body coordinates.",
            ]

            let data = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: metadataURL, options: .atomic)

            let bundle = CameraEvidenceBundle(
                directory: directoryURL,
                videoURL: videoURL,
                journalURL: journalURL,
                metadataURL: metadataURL
            )
            resetRecordingState()
            completion(.success(bundle))
        } catch {
            resetRecordingState()
            completion(.failure(error))
        }
    }

    private func appendEvent(
        _ event: SensorEnvelope
    ) throws {
        guard let journalHandle else {
            throw CameraCaptureError.journalClosed
        }
        var data = try encoder.encode(event)
        data.append(0x0A)
        try journalHandle.write(contentsOf: data)
    }

    private func presentationTimeNS(
        _ time: CMTime
    ) throws -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else {
            throw CameraCaptureError.invalidPresentationTime
        }
        let scaled = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .roundHalfAwayFromZero
        )
        guard scaled.value >= 0 else {
            throw CameraCaptureError.invalidPresentationTime
        }
        return UInt64(scaled.value)
    }

    private func frameDimensions(
        _ sampleBuffer: CMSampleBuffer
    ) -> CMVideoDimensions {
        guard let description = CMSampleBufferGetFormatDescription(
            sampleBuffer
        ) else {
            return CMVideoDimensions(width: 0, height: 0)
        }
        return CMVideoFormatDescriptionGetDimensions(description)
    }

    private func intrinsicMatrix(
        _ sampleBuffer: CMSampleBuffer
    ) -> [[Double]]? {
        guard let data = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) as? Data,
            data.count >= MemoryLayout<matrix_float3x3>.size
        else {
            return nil
        }

        var matrix = matrix_float3x3()
        _ = withUnsafeMutableBytes(of: &matrix) { destination in
            data.copyBytes(
                to: destination,
                count: MemoryLayout<matrix_float3x3>.size
            )
        }

        return (0..<3).map { row in
            (0..<3).map { column in
                Double(matrix[column][row])
            }
        }
    }

    private func jsonMatrix(
        _ matrix: [[Double]]
    ) -> JSONValue {
        .array(
            matrix.map { row in
                .array(row.map(JSONValue.number))
            }
        )
    }

    private func sha256(
        _ url: URL
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while let data = try handle.read(
            upToCount: 1024 * 1024
        ), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func resetRecordingState() {
        self.sessionID = nil
        hostModel = ""
        hostOSVersion = ""
        directoryURL = nil
        videoURL = nil
        journalURL = nil
        metadataURL = nil
        journalHandle = nil
        writer = nil
        writerInput = nil
        writerStarted = false
    }
}
