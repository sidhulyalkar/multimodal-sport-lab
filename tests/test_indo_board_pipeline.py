import json

import pytest

from motionos.indo_board_pipeline import (
    process_indo_board_pipeline,
    validate_indo_board_pipeline_spec,
)
from motionos.schema import SensorEvent


def _write_pose_journal(path, *, source_id):
    event = SensorEvent(
        session_id="vision-s1",
        device_id=source_id,
        stream="/camera/pose2d",
        sequence=0,
        device_time_ns=1_000,
        payload={},
    )
    path.write_text(event.to_json() + "\n", encoding="utf-8")


def _fixture(tmp_path):
    vision = tmp_path / "vision.json"
    watch = tmp_path / "watch.jsonl"
    rig = tmp_path / "rig.json"
    layout = tmp_path / "layout.json"
    iphone_video = tmp_path / "iphone.mov"
    iphone_journal = tmp_path / "iphone.jsonl"
    action_video = tmp_path / "action.mov"
    action_journal = tmp_path / "action.jsonl"
    profile = tmp_path / "profile.json"
    spec = tmp_path / "pipeline.json"

    landmarks = [
        {
            "landmark_id": f"sync-{index}",
            "session_id": "vision-s1",
            "kind": "whole_body_impulse",
            "host_monotonic_time_ns":
                1_000_000_000 + index * 2_000_000_000,
            "created_at_unix_ms": 1_000 + index,
            "note": None,
        }
        for index in range(3)
    ]
    vision.write_text(
        json.dumps(
            {
                "schema_version": "motionos.vision-session.v1",
                "session_id": "vision-s1",
                "sport": "indo_board",
                "capture_mode": "multiview_calibration",
                "created_at_utc": "2026-09-30T23:00:00Z",
                "camera_sources": [],
                "sync_landmarks": landmarks,
                "media_artifacts": [],
                "derived_artifacts": [],
                "coaching_condition": "feedback_disabled",
                "claim_boundary": "",
            }
        ),
        encoding="utf-8",
    )
    watch.write_text("{}\n", encoding="utf-8")
    rig.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-rig-receipt.v1",
                "rig_id": "indo-board-two-camera-v1",
                "passed": True,
                "cameras": [
                    {"camera_id": "iphone-camera-id"},
                    {"camera_id": "dji-action4"},
                ],
            }
        ),
        encoding="utf-8",
    )
    layout.write_text("{}\n", encoding="utf-8")
    iphone_video.write_bytes(b"iphone-video")
    action_video.write_bytes(b"action-video")
    _write_pose_journal(
        iphone_journal,
        source_id="iphone-camera-id",
    )
    _write_pose_journal(
        action_journal,
        source_id="dji-action4",
    )

    document = {
        "schema_version": "motionos.indo-board-pipeline-spec.v1",
        "vision_session": vision.name,
        "watch_journal": watch.name,
        "rig_receipt": rig.name,
        "board_marker_layout": layout.name,
        "longitudinal_profile": profile.name,
        "iphone": {
            "video": iphone_video.name,
            "journal": iphone_journal.name,
        },
        "action4": {
            "video": action_video.name,
            "journal": action_journal.name,
        },
        "thresholds": {
            "maximum_pose_pair_ms": 10,
            "maximum_marker_pair_ms": 10,
            "minimum_joint_confidence": 0.6,
            "marker_frame_stride": 1,
            "maximum_board_scale_error_fraction": 0.03,
            "maximum_skeleton_board_pair_ms": 20,
            "minimum_modeled_mass_coverage": 0.75,
            "maximum_board_fit_residual_m": 0.03,
            "minimum_pose_confidence": 0.6,
            "maximum_timing_uncertainty_ms": 20,
            "maximum_reprojection_rms_px": 3,
            "minimum_longitudinal_confidence": 0.6,
        },
        "wrist_fusion": {
            "watch_acceleration_std_m_s2": 0.2,
            "vision_acceleration_std_m_s2": 0.4,
            "maximum_acceleration_rate_m_s3": 25.0,
            "maximum_time_delta_ms": 20,
        },
    }
    spec.write_text(
        json.dumps(document, indent=2),
        encoding="utf-8",
    )
    return spec, document, rig


def test_pipeline_preflight_accepts_matching_camera_contract(tmp_path):
    spec, document, _rig = _fixture(tmp_path)

    validated = validate_indo_board_pipeline_spec(spec)

    assert validated == document


def test_pipeline_preflight_rejects_camera_id_not_in_rig(tmp_path):
    spec, _document, rig = _fixture(tmp_path)
    raw_rig = json.loads(rig.read_text(encoding="utf-8"))
    raw_rig["cameras"][0]["camera_id"] = "different-iphone"
    rig.write_text(json.dumps(raw_rig), encoding="utf-8")

    with pytest.raises(
        ValueError,
        match="does not contain journal camera IDs",
    ):
        validate_indo_board_pipeline_spec(spec)


@pytest.mark.parametrize(
    ("section", "key", "value", "message"),
    [
        (
            "thresholds",
            "minimum_joint_confidence",
            1.2,
            "between 0 and 1",
        ),
        (
            "thresholds",
            "marker_frame_stride",
            1.5,
            "positive integer",
        ),
        (
            "wrist_fusion",
            "watch_acceleration_std_m_s2",
            "REPLACE_ME",
            "must be numeric",
        ),
        (
            "wrist_fusion",
            "maximum_acceleration_rate_m_s3",
            0,
            "must be positive",
        ),
    ],
)
def test_pipeline_preflight_rejects_invalid_numeric_contract(
    tmp_path,
    section,
    key,
    value,
    message,
):
    spec, document, _rig = _fixture(tmp_path)
    document[section][key] = value
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        validate_indo_board_pipeline_spec(spec)


def test_pipeline_preflight_requires_three_sync_landmarks(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    vision = tmp_path / document["vision_session"]
    raw = json.loads(vision.read_text(encoding="utf-8"))
    raw["sync_landmarks"] = raw["sync_landmarks"][:2]
    vision.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="at least three"):
        validate_indo_board_pipeline_spec(spec)


def test_failed_preflight_creates_no_output_directory(tmp_path):
    spec, document, _rig = _fixture(tmp_path)
    missing = tmp_path / document["iphone"]["video"]
    missing.unlink()
    output = tmp_path / "derived"

    with pytest.raises(FileNotFoundError, match="iphone.video"):
        process_indo_board_pipeline(spec, output)

    assert not output.exists()



@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf")])
def test_pipeline_preflight_rejects_non_finite_threshold(tmp_path, value):
    spec, document, _rig = _fixture(tmp_path)
    document["thresholds"]["maximum_pose_pair_ms"] = value
    spec.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ValueError, match="must be finite"):
        validate_indo_board_pipeline_spec(spec)
