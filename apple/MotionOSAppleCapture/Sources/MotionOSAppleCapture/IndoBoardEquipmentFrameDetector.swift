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
