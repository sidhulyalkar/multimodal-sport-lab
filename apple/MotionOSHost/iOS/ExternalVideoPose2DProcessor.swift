import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MotionOSAppleCapture

actor ExternalVideoPose2DProcessor {
    struct Result: Sendable {
        let journalURL: URL
        let metadataURL: URL
        let frameCount: UInt64
        let poseCount: UInt64
        let poseErrorCount: UInt64
        let imageWidthPixels: Int
        let imageHeightPixels: Int
        let visionOrientation: String
    }

    enum ProcessingError: LocalizedError {
        case noVideoTrack
        case cannotAddReaderOutput
        case readerDidNotStart
        case readerFailed(String)
        case invalidPresentationTime
        case noImageBuffer

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "The imported Action 4 file has no video track."
            case .cannotAddReaderOutput:
                "MotionOS could not attach a decoded video output."
            case .readerDidNotStart:
                "MotionOS could not start reading the imported video."
            case .readerFailed(let message):
                "Imported video processing failed: \(message)"
            case .invalidPresentationTime:
                "The imported video contains an invalid frame timestamp."
            case .noImageBuffer:
                "A decoded video frame did not contain an image buffer."
            }
        }
    }

    func process(
        videoURL: URL,
        sessionID: String,
        outputDirectory: URL,
        sourceID: String = "dji-action4",
        poseStride: UInt64 = 1
    ) async throws -> Result {
        precondition(poseStride > 0)

        let manager = FileManager.default
        try manager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = outputDirectory.appendingPathComponent(
            "action4-frames.jsonl"
        )
        let metadataURL = outputDirectory.appendingPathComponent(
            "action4-derived-metadata.json"
        )
        for url in [journalURL, metadataURL] where
            manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ProcessingError.noVideoTrack
        }

        let preferredTransform = try await track.load(.preferredTransform)
        let visionOrientation = Self.orientation(
            for: preferredTransform
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
            throw ProcessingError.cannotAddReaderOutput
        }
        reader.add(output)

        _ = manager.createFile(atPath: journalURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: journalURL)
        defer {
            try? handle.close()
        }

        guard reader.startReading() else {
            throw ProcessingError.readerDidNotStart
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var frameSequence: UInt64 = 0
        var poseSequence: UInt64 = 0
        var poseErrorCount: UInt64 = 0
        var displayWidth = 0
        var displayHeight = 0
        var firstPTSNS: UInt64?
        var lastPTSNS: UInt64?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsNS = try Self.presentationTimeNS(pts)
            firstPTSNS = firstPTSNS ?? ptsNS
            lastPTSNS = ptsNS

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else {
                throw ProcessingError.noImageBuffer
            }

            let encodedWidth = CVPixelBufferGetWidth(pixelBuffer)
            let encodedHeight = CVPixelBufferGetHeight(pixelBuffer)
            let dimensions = Self.displayDimensions(
                encodedWidth: encodedWidth,
                encodedHeight: encodedHeight,
                orientation: visionOrientation
            )
            displayWidth = dimensions.width
            displayHeight = dimensions.height

            var poseStatus = "not_scheduled"
            var posePayload: [String: JSONValue]?
            if frameSequence % poseStride == 0 {
                do {
                    posePayload = try Pose2DExtractor.extract(
                        from: pixelBuffer,
                        orientation: visionOrientation
                    )
                    poseStatus = posePayload == nil
                        ? "no_pose"
                        : "detected"
                } catch {
                    poseStatus = "vision_error"
                    poseErrorCount += 1
                }
            }

            try Self.append(
                SensorEnvelope(
                    sessionID: sessionID,
                    deviceID: sourceID,
                    stream: "/camera/frame",
                    sequence: frameSequence,
                    deviceTimeNS: ptsNS,
                    payload: [
                        "frame_index": .number(Double(frameSequence)),
                        "pts_seconds": .number(CMTimeGetSeconds(pts)),
                        "timestamp_basis": .string(
                            "container_video_pts"
                        ),
                        "source": .string(
                            "avassetreader_imported_video"
                        ),
                        "pose_status": .string(poseStatus),
                        "pose_stride": .number(Double(poseStride)),
                        "vision_orientation": .string(
                            Self.orientationName(visionOrientation)
                        ),
                        "width_px": .number(Double(displayWidth)),
                        "height_px": .number(Double(displayHeight)),
                        "encoded_width_px": .number(
                            Double(encodedWidth)
                        ),
                        "encoded_height_px": .number(
                            Double(encodedHeight)
                        ),
                    ]
                ),
                to: handle,
                encoder: encoder
            )

            if let posePayload {
                var payload = posePayload
                payload["source_frame_sequence"] =
                    .number(Double(frameSequence))
                payload["source_frame_pts_ns"] =
                    .number(Double(ptsNS))
                payload["timestamp_basis"] = .string(
                    "container_video_pts"
                )
                payload["source"] = .string(
                    "vision_2d_pose_from_imported_video"
                )
                payload["image_width_px"] =
                    .number(Double(displayWidth))
                payload["image_height_px"] =
                    .number(Double(displayHeight))
                payload["vision_orientation"] = .string(
                    Self.orientationName(visionOrientation)
                )

                try Self.append(
                    SensorEnvelope(
                        sessionID: sessionID,
                        deviceID: sourceID,
                        stream: "/camera/pose2d",
                        sequence: poseSequence,
                        deviceTimeNS: ptsNS,
                        payload: payload
                    ),
                    to: handle,
                    encoder: encoder
                )
                poseSequence += 1
            }

            frameSequence += 1
        }

        try handle.synchronize()

        guard reader.status == .completed else {
            throw ProcessingError.readerFailed(
                reader.error?.localizedDescription
                    ?? String(describing: reader.status)
            )
        }

        let sourceDigest = try FileEvidence.digest(videoURL)
        let effectiveFrameRate: Double? = {
            guard frameSequence >= 2,
                  let firstPTSNS,
                  let lastPTSNS,
                  lastPTSNS > firstPTSNS
            else {
                return nil
            }
            let durationSeconds =
                Double(lastPTSNS - firstPTSNS) / 1_000_000_000.0
            return Double(frameSequence - 1) / durationSeconds
        }()
        let metadata: [String: Any] = [
            "schema_version": "motionos.external-video-pose2d.v1",
            "session_id": sessionID,
            "source_id": sourceID,
            "generated_at_utc":
                ISO8601DateFormatter().string(from: Date()),
            "source_video": [
                "filename": videoURL.lastPathComponent,
                "sha256": sourceDigest.sha256,
                "byte_count": sourceDigest.byteCount,
            ],
            "timestamp_basis": "container_video_pts",
            "vision_request": "VNDetectHumanBodyPoseRequest",
            "vision_orientation":
                Self.orientationName(visionOrientation),
            "coordinate_frame": "vision_normalized_lower_left",
            "image_width_px": displayWidth,
            "image_height_px": displayHeight,
            "pose_stride_frames": poseStride,
            "effective_frame_rate_fps": effectiveFrameRate as Any,
            "counts": [
                "frames": frameSequence,
                "poses": poseSequence,
                "pose_errors": poseErrorCount,
            ],
            "pts_ns": [
                "first": firstPTSNS as Any,
                "last": lastPTSNS as Any,
            ],
            "preferred_transform": [
                preferredTransform.a,
                preferredTransform.b,
                preferredTransform.c,
                preferredTransform.d,
                preferredTransform.tx,
                preferredTransform.ty,
            ],
            "claim_boundary": (
                "2D joints are Vision observations on decoded source frames; "
                    + "they are not metric 3D coordinates until calibrated "
                    + "multi-view reconstruction succeeds."
            ),
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(to: metadataURL, options: .atomic)

        return Result(
            journalURL: journalURL,
            metadataURL: metadataURL,
            frameCount: frameSequence,
            poseCount: poseSequence,
            poseErrorCount: poseErrorCount,
            imageWidthPixels: displayWidth,
            imageHeightPixels: displayHeight,
            visionOrientation: Self.orientationName(visionOrientation)
        )
    }

    private static func append(
        _ event: SensorEnvelope,
        to handle: FileHandle,
        encoder: JSONEncoder
    ) throws {
        var data = try encoder.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func presentationTimeNS(
        _ time: CMTime
    ) throws -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else {
            throw ProcessingError.invalidPresentationTime
        }
        let scaled = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .roundHalfAwayFromZero
        )
        guard scaled.value >= 0 else {
            throw ProcessingError.invalidPresentationTime
        }
        return UInt64(scaled.value)
    }

    private static func orientation(
        for transform: CGAffineTransform
    ) -> CGImagePropertyOrientation {
        let tolerance = 0.01
        func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        if close(transform.a, 0),
           close(transform.b, 1),
           close(transform.c, -1),
           close(transform.d, 0) {
            return .right
        }
        if close(transform.a, 0),
           close(transform.b, -1),
           close(transform.c, 1),
           close(transform.d, 0) {
            return .left
        }
        if close(transform.a, -1),
           close(transform.b, 0),
           close(transform.c, 0),
           close(transform.d, -1) {
            return .down
        }
        return .up
    }

    private static func displayDimensions(
        encodedWidth: Int,
        encodedHeight: Int,
        orientation: CGImagePropertyOrientation
    ) -> (width: Int, height: Int) {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return (encodedHeight, encodedWidth)
        default:
            return (encodedWidth, encodedHeight)
        }
    }

    private static func orientationName(
        _ orientation: CGImagePropertyOrientation
    ) -> String {
        switch orientation {
        case .up: "up"
        case .upMirrored: "up_mirrored"
        case .down: "down"
        case .downMirrored: "down_mirrored"
        case .left: "left"
        case .leftMirrored: "left_mirrored"
        case .right: "right"
        case .rightMirrored: "right_mirrored"
        @unknown default: "unknown"
        }
    }
}
