#if os(iOS) && canImport(Vision) && canImport(CoreVideo)
import CoreVideo
import Foundation
import ImageIO
import Vision
import simd

public enum Pose3DExtractor {
    public static func extract(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [String: JSONValue]? {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation
        )
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }

        var joints: [String: JSONValue] = [:]
        for name in observation.availableJointNames {
            let point = try observation.recognizedPoint(name)
            let translation = point.position.columns.3
            joints[name.rawValue.rawValue] = .array([
                .number(Double(translation.x)),
                .number(Double(translation.y)),
                .number(Double(translation.z))
            ])
        }
        return [
            "joints_m": .object(joints),
            "joint_count": .number(Double(joints.count))
        ]
    }
}
#endif
