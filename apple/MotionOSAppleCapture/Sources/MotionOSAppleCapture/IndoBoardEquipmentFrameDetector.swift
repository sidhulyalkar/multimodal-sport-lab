#if os(iOS) && canImport(CoreVideo) && canImport(ImageIO)
import CoreVideo
import Foundation
import ImageIO

/// Synchronous image-space equipment detector invoked on the camera analysis
/// queue. Implementations may wrap Core ML / Vision models, but must return
/// the shared MotionOS equipment contract rather than a model-specific tensor.
public protocol IndoBoardEquipmentFrameDetector {
    var detectorID: String { get }

    func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> IndoBoardEquipmentObservation?
}

public struct IndoBoardEquipmentDetectorExecutionAudit:
    Sendable,
    Equatable {
    public enum Status: String, Sendable, Equatable {
        case observation
        case noObservation = "no_observation"
        case error
    }

    public let detectorID: String
    public let status: Status
    public let durationMS: Double
    public let message: String?

    public init(
        detectorID: String,
        status: Status,
        durationMS: Double,
        message: String? = nil
    ) {
        self.detectorID = detectorID
        self.status = status
        self.durationMS = max(0, durationMS)
        self.message = message
    }

    public var cameraPayload: JSONValue {
        var object: [String: JSONValue] = [
            "detector_id": .string(detectorID),
            "status": .string(status.rawValue),
            "duration_ms": .number(durationMS),
        ]

        if let message, !message.isEmpty {
            object["message"] = .string(message)
        }

        return .object(object)
    }
}

public struct IndoBoardEquipmentDetectorFailure:
    Sendable,
    Equatable {
    public let detectorID: String
    public let message: String

    public init(
        detectorID: String,
        message: String
    ) {
        self.detectorID = detectorID
        self.message = message
    }

    public var cameraPayload: JSONValue {
        .object([
            "detector_id": .string(detectorID),
            "message": .string(message),
        ])
    }
}
#endif
