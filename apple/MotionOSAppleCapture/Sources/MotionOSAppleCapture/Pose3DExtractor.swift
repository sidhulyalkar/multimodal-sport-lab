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
        let request3D = VNDetectHumanBodyPose3DRequest()
        let request2D = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation
        )
        try handler.perform([request3D, request2D])
        guard let observation = request3D.results?.first else { return nil }

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

        var payload: [String: JSONValue] = [
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

        if let imageObservation = request2D.results?.first {
            let imagePoints = try imageObservation.recognizedPoints(.all)
            let visible = imagePoints.filter { _, point in
                point.confidence >= 0.25
            }

            if !visible.isEmpty {
                let xs = visible.values.map { Double($0.location.x) }
                let ys = visible.values.map { Double($0.location.y) }
                let confidence = visible.values.reduce(0.0) {
                    $0 + Double($1.confidence)
                } / Double(visible.count)

                var imageJoints: [String: JSONValue] = [:]
                for (name, point) in visible {
                    imageJoints[name.rawValue.rawValue] = .array([
                        .number(Double(point.location.x)),
                        .number(Double(point.location.y)),
                        .number(Double(point.confidence)),
                    ])
                }

                payload["body_pose_2d_joints"] = .object(imageJoints)
                payload["body_bbox_image_normalized"] = .array([
                    .number(xs.min() ?? 0),
                    .number(ys.min() ?? 0),
                    .number(xs.max() ?? 1),
                    .number(ys.max() ?? 1),
                ])
                payload["body_pose_2d_joint_count"] =
                    .number(Double(visible.count))
                payload["body_pose_2d_mean_confidence"] =
                    .number(confidence)
                payload["body_pose_2d_coordinate_frame"] =
                    .string("vision_normalized_image_bottom_left_origin")
            }
        }

        return payload
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
