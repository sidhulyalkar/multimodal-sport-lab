#if os(iOS) && canImport(Vision) && canImport(CoreVideo)
import CoreVideo
import Foundation
import ImageIO
import Vision
import simd

public enum Pose3DExtractor {
    public static func extract(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        equipmentDetectors:
            [any IndoBoardEquipmentFrameDetector] = [],
        qualificationRegistry:
            IndoBoardEquipmentModelQualificationRegistry? = nil
    ) throws -> [String: JSONValue]? {
        let request3D = VNDetectHumanBodyPose3DRequest()
        let request2D = VNDetectHumanBodyPoseRequest()
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr]
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation
        )
        try handler.perform([
            request3D,
            request2D,
            barcodeRequest,
        ])
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

        let fiducials = (barcodeRequest.results ?? [])
            .compactMap { observation
                -> IndoBoardFiducialDetection? in
                guard let raw =
                        observation.payloadStringValue,
                      let marker =
                        IndoBoardFiducialMarkerID(
                            rawValue: raw
                        )
                else {
                    return nil
                }

                let box = observation.boundingBox
                return IndoBoardFiducialDetection(
                    marker: marker,
                    center: NormalizedImagePoint2D(
                        x: Double(box.midX),
                        y: Double(box.midY)
                    ),
                    confidence:
                        Double(observation.confidence)
                )
            }

        let visibleFiducials = Array(
            Set(
                fiducials.map {
                    $0.marker.rawValue
                }
            )
        )
        .sorted()

        if !visibleFiducials.isEmpty {
            payload[
                "indo_board_fiducials_visible"
            ] = .array(
                visibleFiducials.map {
                    .string($0)
                }
            )
        }

        var equipmentCandidates:
            [IndoBoardEquipmentDetectionCandidate] = []

        if let equipment =
                IndoBoardFiducialEquipmentBuilder
                    .makeObservation(
                        detections: fiducials
                    ) {
            equipmentCandidates.append(
                IndoBoardEquipmentDetectionCandidate(
                    observation: equipment,
                    detectorID: "vision_qr"
                )
            )
        }

        var detectorFailures:
            [IndoBoardEquipmentDetectorFailure] = []
        var detectorExecutions:
            [IndoBoardEquipmentDetectorExecutionAudit] = []

        for detector in equipmentDetectors {
            let started =
                ProcessInfo.processInfo.systemUptime

            do {
                let observation = try detector.detect(
                    in: pixelBuffer,
                    orientation: orientation
                )
                let durationMS =
                    (
                        ProcessInfo.processInfo.systemUptime
                            - started
                    ) * 1_000

                if let observation {
                    equipmentCandidates.append(
                        IndoBoardEquipmentDetectionCandidate(
                            observation: observation,
                            detectorID:
                                detector.detectorID
                        )
                    )
                    detectorExecutions.append(
                        IndoBoardEquipmentDetectorExecutionAudit(
                            detectorID:
                                detector.detectorID,
                            status: .observation,
                            durationMS: durationMS
                        )
                    )
                } else {
                    detectorExecutions.append(
                        IndoBoardEquipmentDetectorExecutionAudit(
                            detectorID:
                                detector.detectorID,
                            status: .noObservation,
                            durationMS: durationMS
                        )
                    )
                }
            } catch {
                let durationMS =
                    (
                        ProcessInfo.processInfo.systemUptime
                            - started
                    ) * 1_000
                detectorFailures.append(
                    IndoBoardEquipmentDetectorFailure(
                        detectorID:
                            detector.detectorID,
                        message:
                            error.localizedDescription
                    )
                )
                detectorExecutions.append(
                    IndoBoardEquipmentDetectorExecutionAudit(
                        detectorID:
                            detector.detectorID,
                        status: .error,
                        durationMS: durationMS,
                        message:
                            error.localizedDescription
                    )
                )
            }
        }

        if !equipmentCandidates.isEmpty
            || !equipmentDetectors.isEmpty {
            let routing =
                IndoBoardEquipmentEvidenceRouter(
                    registry:
                        qualificationRegistry
                )
                .route(equipmentCandidates)

            payload["indo_board_equipment_routing"] =
                routing.audit.cameraPayload

            if let selected =
                    routing.tracking.selected {
                payload[
                    "indo_board_tracking_equipment"
                ] = selected.observation.cameraPayload
                payload[
                    "indo_board_tracking_detector_id"
                ] = .string(selected.detectorID)

                if let modelID =
                        selected.observation.modelID {
                    payload[
                        "indo_board_tracking_equipment_source"
                    ] = .string(modelID)
                }
            }

            if let selected =
                    routing.coaching.selected {
                payload["indo_board_equipment"] =
                    selected.observation.cameraPayload
                payload[
                    "indo_board_equipment_detector_id"
                ] = .string(selected.detectorID)

                if let modelID =
                        selected.observation.modelID {
                    payload[
                        "indo_board_equipment_source"
                    ] = .string(modelID)
                }
            }
        }

        if !detectorExecutions.isEmpty {
            payload[
                "indo_board_equipment_detector_executions"
            ] = .array(
                detectorExecutions.map {
                    $0.cameraPayload
                }
            )
        }

        if !detectorFailures.isEmpty {
            payload[
                "indo_board_equipment_detector_failures"
            ] = .array(
                detectorFailures.map {
                    $0.cameraPayload
                }
            )
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
