import json

from motionos.indo_board_acquisition import (
    ACQUISITION_PROFILE_ID,
    ACTION4_CONFIRMATION_CAPABILITY,
    evaluate_indo_board_acquisition,
    require_indo_board_acquisition,
)


def _fixture(tmp_path):
    vision = tmp_path / "vision.json"
    iphone = tmp_path / "iphone-metadata.json"
    action4 = tmp_path / "action4-metadata.json"

    vision.write_text(
        json.dumps(
            {
                "schema_version": "motionos.vision-session.v1",
                "session_id": "vision-s1",
                "sport": "indo_board",
                "capture_mode": "multiview_calibration",
                "created_at_utc": "2026-10-01T12:00:00Z",
                "camera_sources": [
                    {
                        "source_id": "iphone-camera-id",
                        "display_name": "iPhone rear camera",
                        "kind": "built_in",
                        "clock_domain": "avcapture-pts",
                        "timestamp_basis":
                            "avcapture_presentation_timestamp",
                        "supports_live_frames": True,
                        "supports_remote_control": True,
                        "capabilities": [
                            "live_preview",
                            "vision_pose",
                            "camera_intrinsics",
                        ],
                    },
                    {
                        "source_id": "dji-action4",
                        "display_name": "DJI Osmo Action 4",
                        "kind": "external_recorded",
                        "clock_domain": "action4-video-pts",
                        "timestamp_basis": "container_video_pts",
                        "supports_live_frames": False,
                        "supports_remote_control": False,
                        "capabilities": [
                            "4k",
                            "manual_import",
                            "offline_vision_pose2d",
                            ACTION4_CONFIRMATION_CAPABILITY,
                        ],
                    },
                ],
                "sync_landmarks": [],
                "media_artifacts": [],
                "derived_artifacts": [],
                "coaching_condition": "feedback_disabled",
                "claim_boundary": "",
            }
        ),
        encoding="utf-8",
    )

    iphone.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera.v1",
                "session_id": "vision-s1",
                "camera": {
                    "unique_id": "iphone-camera-id",
                    "format_width": 1920,
                    "format_height": 1080,
                    "requested_frame_rate": 30.0,
                    "configured_frame_rate": 30.0,
                    "frame_rate_locked": True,
                    "video_stabilization_supported": True,
                    "preferred_video_stabilization_mode": "off",
                    "stabilization_locked_off": True,
                },
                "pose": {
                    "stride_delivered_frames": 3,
                },
            }
        ),
        encoding="utf-8",
    )

    action4.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.external-video-pose2d.v1",
                "session_id": "vision-s1",
                "source_id": "dji-action4",
                "image_width_px": 3840,
                "image_height_px": 2160,
                "pose_stride_frames": 1,
                "effective_frame_rate_fps": 59.94,
            }
        ),
        encoding="utf-8",
    )
    return vision, iphone, action4


def test_acquisition_profile_passes_fixed_two_camera_contract(tmp_path):
    vision, iphone, action4 = _fixture(tmp_path)
    output = tmp_path / "receipt.json"

    receipt = evaluate_indo_board_acquisition(
        vision,
        iphone,
        action4,
        output_path=output,
    )

    assert receipt["profile_id"] == ACQUISITION_PROFILE_ID
    assert receipt["passed"] is True
    assert receipt["failed_check_ids"] == []
    assert output.is_file()
    assert all(check["passed"] for check in receipt["checks"])


def test_action4_operator_profile_confirmation_is_required(tmp_path):
    vision, iphone, action4 = _fixture(tmp_path)
    raw = json.loads(vision.read_text(encoding="utf-8"))
    raw["camera_sources"][1]["capabilities"] = [
        "4k",
        "manual_import",
    ]
    vision.write_text(json.dumps(raw), encoding="utf-8")

    receipt = evaluate_indo_board_acquisition(
        vision,
        iphone,
        action4,
    )

    assert receipt["passed"] is False
    assert "action4_profile_operator_confirmed" in (
        receipt["failed_check_ids"]
    )


def test_action4_wrong_frame_rate_fails_machine_check(tmp_path):
    vision, iphone, action4 = _fixture(tmp_path)
    raw = json.loads(action4.read_text(encoding="utf-8"))
    raw["effective_frame_rate_fps"] = 30.0
    action4.write_text(json.dumps(raw), encoding="utf-8")

    receipt = evaluate_indo_board_acquisition(
        vision,
        iphone,
        action4,
    )

    assert receipt["passed"] is False
    assert "action4_effective_frame_rate" in (
        receipt["failed_check_ids"]
    )


def test_iphone_stabilization_must_be_off(tmp_path):
    vision, iphone, action4 = _fixture(tmp_path)
    raw = json.loads(iphone.read_text(encoding="utf-8"))
    raw["camera"]["stabilization_locked_off"] = False
    raw["camera"]["preferred_video_stabilization_mode"] = "auto"
    iphone.write_text(json.dumps(raw), encoding="utf-8")

    receipt = evaluate_indo_board_acquisition(
        vision,
        iphone,
        action4,
    )

    assert receipt["passed"] is False
    assert "iphone_stabilization_off" in receipt["failed_check_ids"]


def test_require_acquisition_raises_with_failed_check_ids(tmp_path):
    vision, iphone, action4 = _fixture(tmp_path)
    raw = json.loads(action4.read_text(encoding="utf-8"))
    raw["pose_stride_frames"] = 3
    action4.write_text(json.dumps(raw), encoding="utf-8")

    try:
        require_indo_board_acquisition(vision, iphone, action4)
    except ValueError as exc:
        assert "action4_pose_stride" in str(exc)
    else:
        raise AssertionError("expected acquisition validation failure")
