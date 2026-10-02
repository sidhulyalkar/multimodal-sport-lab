from motionos.indo_pose_metrics import analyze_indo_pose_payloads


def _payload(*, knee_offset: float, shoulder_offset: float = 0.0):
    return {
        "body_pose_2d_joints": {
            "leftHip": [0.44, 0.62, 0.95],
            "rightHip": [0.56, 0.62, 0.95],
            "leftKnee": [0.44 + knee_offset, 0.44, 0.95],
            "rightKnee": [0.56 - knee_offset, 0.44, 0.95],
            "leftAnkle": [0.40, 0.18, 0.95],
            "rightAnkle": [0.60, 0.18, 0.95],
            "leftShoulder": [
                0.43 + shoulder_offset,
                0.82,
                0.95,
            ],
            "rightShoulder": [
                0.57 + shoulder_offset,
                0.82,
                0.95,
            ],
            "leftWrist": [0.30, 0.60, 0.9],
            "rightWrist": [0.70, 0.60, 0.9],
        },
        "body_bbox_image_normalized": [0.25, 0.10, 0.75, 0.92],
        "body_pose_2d_mean_confidence": 0.93,
    }


def test_pose_metrics_extract_body_only_signals():
    result = analyze_indo_pose_payloads(
        [
            _payload(knee_offset=0.00, shoulder_offset=0.00),
            _payload(knee_offset=0.04, shoulder_offset=0.03),
            _payload(knee_offset=0.05, shoulder_offset=0.04),
        ]
    )

    metrics = result["metrics"]
    assert result["frame_accounting"]["frames_with_2d_pose"] == 3
    assert result["frame_accounting"]["complete_frames"] == 3
    assert metrics["median_knee_flexion_deg"] > 0
    assert metrics["trunk_excursion"] > 0
    assert metrics["median_stance_width_bbox_ratio"] > 0
    assert metrics["median_arm_excursion_body_ratio"] > 0


def test_pose_metrics_fail_soft_when_2d_pose_is_missing():
    result = analyze_indo_pose_payloads(
        [
            {"joints_root_relative_m": {}},
            {},
        ]
    )

    assert result["frame_accounting"]["total_pose_frames"] == 2
    assert result["frame_accounting"]["frames_with_2d_pose"] == 0
    assert result["metrics"] == {}
    assert result["confidence"] == {}
