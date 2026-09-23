from __future__ import annotations

import json
import math

import pytest

from motionos.body_model import (
    BODY_MODEL_SCHEMA_VERSION,
    BodyModelProfile,
    fit_similarity_transform,
    load_body_model_profile,
    register_vision_pose,
    verify_body_model_source_artifact,
)
from motionos.provenance import sha256_file
from motionos.schema import SensorEvent


def _apply_known(
    point: tuple[float, float, float],
) -> tuple[float, float, float]:
    # 90-degree rotation about +Z, then scale 1.25 and translate.
    x, y, z = point
    rotated = (-y, x, z)
    return (
        1.25 * rotated[0] + 0.4,
        1.25 * rotated[1] - 0.2,
        1.25 * rotated[2] + 1.1,
    )


def _source_points() -> dict[str, tuple[float, float, float]]:
    return {
        "root": (0.0, 0.0, 0.0),
        "leftShoulder": (-0.25, 0.55, 0.02),
        "rightShoulder": (0.28, 0.56, -0.01),
        "leftHip": (-0.18, -0.05, 0.03),
        "rightHip": (0.21, -0.04, -0.02),
    }


def _profile_dict(source_hash: str | None = None) -> dict[str, object]:
    source = _source_points()
    return {
        "schema_version": BODY_MODEL_SCHEMA_VERSION,
        "model_id": "fixture-body-v2",
        "height_m": 1.58,
        "frame_convention": "+X right,+Y up,+Z forward",
        "landmarks_m": {
            name: list(_apply_known(point))
            for name, point in source.items()
        },
        "segments_m": {
            "left_femur": 0.402,
            "right_femur": 0.417,
            "left_tibia": 0.381,
            "right_tibia": 0.394,
            "left_upper_arm": 0.274,
            "right_upper_arm": 0.287,
        },
        "joint_limits_deg": {
            "left_knee": [0.0, 145.0],
            "right_knee": [0.0, 142.0],
        },
        "registration_landmarks": [
            "root",
            "leftShoulder",
            "rightShoulder",
            "leftHip",
            "rightHip",
        ],
        "source": {
            "type": "3d_body_scan",
            "artifact_sha256": source_hash,
            "notes": "synthetic fixture",
        },
        "metadata": {
            "asymmetry_preserved": True,
        },
    }


def _pose_event() -> SensorEvent:
    return SensorEvent(
        session_id="camera-session",
        device_id="camera",
        stream="/camera/pose3d",
        sequence=7,
        device_time_ns=123_000_000,
        payload={
            "joints_root_relative_m": {
                name: list(point)
                for name, point in _source_points().items()
            },
            "joint_coordinate_frame":
                "vision_root_joint_relative_meters",
            "camera_origin_matrix": [
                [1.0, 0.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
                [0.0, 0.0, 1.0, 2.0],
                [0.0, 0.0, 0.0, 1.0],
            ],
        },
    )


def test_similarity_fit_recovers_known_transform():
    source = _source_points()
    target = {
        name: _apply_known(point)
        for name, point in source.items()
    }

    transform, residuals = fit_similarity_transform(
        source,
        target,
        landmark_order=tuple(source),
    )

    assert transform.scale == pytest.approx(1.25, abs=1e-9)
    assert transform.translation_m == pytest.approx(
        (0.4, -0.2, 1.1),
        abs=1e-9,
    )
    assert transform.rotation[0] == pytest.approx(
        (0.0, -1.0, 0.0),
        abs=1e-9,
    )
    assert transform.rotation[1] == pytest.approx(
        (1.0, 0.0, 0.0),
        abs=1e-9,
    )
    assert transform.rotation[2] == pytest.approx(
        (0.0, 0.0, 1.0),
        abs=1e-9,
    )
    assert max(residuals.values()) < 1e-9


def test_profile_preserves_left_right_asymmetry_and_hash(tmp_path):
    scan = tmp_path / "scan.glb"
    scan.write_bytes(b"synthetic body scan bytes")
    profile_path = tmp_path / "body-model.json"
    profile_path.write_text(
        json.dumps(_profile_dict(sha256_file(scan))),
        encoding="utf-8",
    )

    profile = load_body_model_profile(profile_path)

    assert profile.profile_sha256 == sha256_file(profile_path)
    assert profile.segments_m["left_femur"] == pytest.approx(0.402)
    assert profile.segments_m["right_femur"] == pytest.approx(0.417)
    assert profile.segments_m["left_femur"] != profile.segments_m["right_femur"]
    assert verify_body_model_source_artifact(profile, scan) == sha256_file(scan)


def test_source_artifact_tampering_is_rejected(tmp_path):
    scan = tmp_path / "scan.glb"
    scan.write_bytes(b"original")
    profile_path = tmp_path / "body-model.json"
    profile_path.write_text(
        json.dumps(_profile_dict(sha256_file(scan))),
        encoding="utf-8",
    )
    profile = load_body_model_profile(profile_path)

    scan.write_bytes(b"tampered")

    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        verify_body_model_source_artifact(profile, scan)


def test_register_pose_retains_raw_event_and_emits_receipt(tmp_path):
    profile_path = tmp_path / "body-model.json"
    profile_path.write_text(
        json.dumps(_profile_dict()),
        encoding="utf-8",
    )
    profile = load_body_model_profile(profile_path)
    event = _pose_event()
    original_payload = json.loads(json.dumps(event.payload))

    registered = register_vision_pose(event, profile)

    assert event.payload == original_payload
    assert registered.receipt.profile_id == "fixture-body-v2"
    assert registered.receipt.profile_sha256 == sha256_file(profile_path)
    assert registered.receipt.source_pose_sequence == 7
    assert registered.receipt.source_pose_time_ns == 123_000_000
    assert registered.receipt.transform.scale == pytest.approx(1.25, abs=1e-9)
    assert registered.receipt.residual_rms_m < 1e-9
    assert registered.receipt.residual_max_m < 1e-9

    for name, point in _source_points().items():
        assert registered.joints_body_model_m[name] == pytest.approx(
            _apply_known(point),
            abs=1e-9,
        )


def test_missing_declared_registration_landmark_is_rejected(tmp_path):
    profile_path = tmp_path / "body-model.json"
    profile_path.write_text(
        json.dumps(_profile_dict()),
        encoding="utf-8",
    )
    profile = load_body_model_profile(profile_path)
    event = _pose_event()
    payload = dict(event.payload)
    joints = dict(payload["joints_root_relative_m"])
    del joints["rightHip"]
    payload["joints_root_relative_m"] = joints
    missing = SensorEvent(
        session_id=event.session_id,
        device_id=event.device_id,
        stream=event.stream,
        sequence=event.sequence,
        device_time_ns=event.device_time_ns,
        payload=payload,
    )

    with pytest.raises(
        ValueError,
        match="missing registration landmarks: rightHip",
    ):
        register_vision_pose(missing, profile)


def test_collinear_landmarks_are_rejected():
    source = {
        "a": (0.0, 0.0, 0.0),
        "b": (1.0, 0.0, 0.0),
        "c": (2.0, 0.0, 0.0),
    }
    target = {
        "a": (0.0, 0.0, 0.0),
        "b": (0.0, 1.0, 0.0),
        "c": (0.0, 2.0, 0.0),
    }

    with pytest.raises(ValueError, match="collinear or degenerate"):
        fit_similarity_transform(
            source,
            target,
            landmark_order=("a", "b", "c"),
        )


def test_profile_rejects_symmetric_assumption_by_not_imposing_one():
    profile = BodyModelProfile.from_dict(_profile_dict())

    assert not math.isclose(
        profile.segments_m["left_tibia"],
        profile.segments_m["right_tibia"],
    )
