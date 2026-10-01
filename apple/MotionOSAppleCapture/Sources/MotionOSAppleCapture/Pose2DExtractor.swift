#if os(iOS) && canImport(Vision) && canImport(CoreVideo)
import CoreVideo
import Foundation
import ImageIO
import Vision

public enum Pose2DExtractor {
    public static func extract(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [String: JSONValue]? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation
        )
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }

        var joints: [String: JSONValue] = [:]
        for name in observation.availableJointNames {
            let point = try observation.recognizedPoint(name)
            joints[name.rawValue.rawValue] = .object([
                "x": .number(Double(point.location.x)),
                "y": .number(Double(point.location.y)),
                "confidence": .number(Double(point.confidence)),
            ])
        }

        return [
            "joints_normalized": .object(joints),
            "joint_count": .number(Double(joints.count)),
            "joint_coordinate_frame": .string(
                "vision_normalized_lower_left"
            ),
            "vision_request": .string(
                "VNDetectHumanBodyPoseRequest"
            ),
        ]
    }
}
#endif
