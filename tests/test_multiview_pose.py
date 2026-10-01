import pytest

from motionos.multiview_pose import (
    build_skeleton_correspondences,
    build_skeleton_sequence_correspondences,
)
from motionos.vision_contract import (
    VisionJointObservation,
    VisionObservation,
)


def _frame(source_id, session_time_ns, wrist_x, confidence=0.95):
    return VisionObservation(
        source_id=source_id,
        frame_sequence=7,
        frame_source_time_ns=session_time_ns - 1_000_000,
        mapped_session_time_ns=session_time_ns,
        timing_uncertainty_ns=2_000_000,
        coordinate_frame="image_pixels",
        model_identifier="fixture-pose",
        joints={
            "left_wrist": VisionJointObservation(
                x=wrist_x,
                y=400.0,
                confidence=confidence,
            ),
            "nose": VisionJointObservation(
                x=960.0,
                y=250.0,
                confidence=0.98,
            ),
        },
    )


def test_build_skeleton_correspondences_matches_world_geometry_contract():
    result = build_skeleton_correspondences(
        [
            _frame("iphone-rear", 1_000_000_000, 850.0),
            _frame("dji-action4", 1_006_000_000, 1010.0),
        ]
    )

    assert result.accepted_joint_count == 2
    document = result.to_correspondence_document(
        rig_id="indo-two-camera-v1",
        rig_receipt_sha256="a" * 64,
    )
    assert document["schema_version"] == (
        "motionos.multiview-correspondences.v1"
    )
    point = document["points"][0]
    assert set(point["observations"]) == {"iphone-rear", "dji-action4"}
    assert "source_frame_pts_ns" in point["observations"]["iphone-rear"]


def test_low_confidence_joint_is_rejected_without_poisoning_other_joints():
    result = build_skeleton_correspondences(
        [
            _frame("iphone-rear", 1_000_000_000, 850.0, confidence=0.1),
            _frame("dji-action4", 1_001_000_000, 1010.0),
        ]
    )

    assert result.accepted_joint_count == 1
    assert result.rejected_joint_count == 1


def test_frame_timing_gate_fails_closed():
    with pytest.raises(ValueError, match="timing span"):
        build_skeleton_correspondences(
            [
                _frame("iphone-rear", 1_000_000_000, 850.0),
                _frame("dji-action4", 1_050_000_000, 1010.0),
            ]
        )


def test_sequence_correspondences_accumulate_synchronized_pairs():
    first_pair = (
        _frame("iphone-rear", 1_000_000_000, 850.0),
        _frame("dji-action4", 1_006_000_000, 1010.0),
    )
    second_pair = (
        _frame("iphone-rear", 2_000_000_000, 860.0),
        _frame("dji-action4", 2_004_000_000, 1000.0),
    )

    document = build_skeleton_sequence_correspondences(
        [first_pair, second_pair],
        rig_id="indo-two-camera-v1",
        rig_receipt_sha256="b" * 64,
    )

    assert document["pair_count"] == 2
    assert document["accepted_joint_count"] == 4
    assert len(document["points"]) == 4
    assert len({
        point["point_id"]
        for point in document["points"]
    }) == 4
