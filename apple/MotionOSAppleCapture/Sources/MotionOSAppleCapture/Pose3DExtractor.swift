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
            "joint_count": .number(Double(joints.count)),
            "body_height_m": .number(Double(observation.bodyHeight)),
            "height_estimation": .string(
                String(describing: observation.heightEstimation)
            ),
            "camera_origin_matrix": .array(
                flatten(observation.cameraOriginMatrix).map {
                    .number(Double($0))
                }
            ),
            "coordinate_basis": .string("vision_root_relative_meters")
        ]
    }

    private static func flatten(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x,
            matrix.columns.0.y,
            matrix.columns.0.z,
            matrix.columns.0.w,
            matrix.columns.1.x,
            matrix.columns.1.y,
            matrix.columns.1.z,
            matrix.columns.1.w,
            matrix.columns.2.x,
            matrix.columns.2.y,
            matrix.columns.2.z,
            matrix.columns.2.w,
            matrix.columns.3.x,
            matrix.columns.3.y,
            matrix.columns.3.z,
            matrix.columns.3.w
        ]
    }
}
#endif
