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
        var parentJoints: [String: JSONValue] = [:]

        for name in observation.availableJointNames {
            let point = try observation.recognizedPoint(name)
            let translation = point.position.columns.3
            joints[name.rawValue.rawValue] = .array([
                .number(Double(translation.x)),
                .number(Double(translation.y)),
                .number(Double(translation.z)),
            ])

            if let parent = observation.parentJointName(name) {
                parentJoints[name.rawValue.rawValue] = .string(
                    parent.rawValue.rawValue
                )
            } else {
                parentJoints[name.rawValue.rawValue] = .null
            }
        }

        return [
            "joints_root_relative_m": .object(joints),
            "joint_parents": .object(parentJoints),
            "joint_count": .number(Double(joints.count)),
            "body_height_m": .number(Double(observation.bodyHeight)),
            "height_estimation": .string(
                String(describing: observation.heightEstimation)
            ),
            "camera_origin_matrix": matrixJSON(
                observation.cameraOriginMatrix
            ),
            "joint_coordinate_frame": .string(
                "vision_root_joint_relative_meters"
            ),
            "camera_origin_semantics": .string(
                "transform_from_skeleton_root_to_camera"
            ),
            "vision_request": .string(
                "VNDetectHumanBodyPose3DRequest"
            ),
        ]
    }

    private static func matrixJSON(
        _ matrix: simd_float4x4
    ) -> JSONValue {
        .array(
            (0..<4).map { row in
                .array(
                    (0..<4).map { column in
                        .number(
                            Double(matrix[column][row])
                        )
                    }
                )
            }
        )
    }
}
#endif
