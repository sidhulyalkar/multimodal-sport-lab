from __future__ import annotations

import json

import pytest

from motionos.body_authoring import (
    BODY_AUTHORING_SPEC_SCHEMA_VERSION,
    build_body_model_from_spec,
    build_body_registration_report,
)
from motionos.body_model import verify_body_model_source_artifact
from motionos.provenance import sha256_file
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionWriter


def _landmarks() -> dict[str, list[float]]:
    return {
        "root": [0.0, 0.0, 0.0],
        "leftHip": [-0.15, 0.0, 0.0],
        "rightHip": [0.17, 0.01, 0.0],
        "leftShoulder": [-0.20, 0.50, 0.01],
        "rightShoulder": [0.22, 0.52, -0.01],
        "leftKnee": [-0.14, -0.39, 0.02],
        "rightKnee": [0.16, -0.41, 0.01],
    }


def _write_spec(tmp_path):
    scan = tmp_path / "scan.glb"
    scan.write_bytes(b"immutable body scan fixture")
    spec = tmp_path / "body-authoring.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version": BODY_AUTHORING_SPEC_SCHEMA_VERSION,
                "model_id": "body-fixture",
                "height_m": 1.58,
                "frame_convention": "+X right,+Y up,+Z forward",
                "source": {
                    "type": "3d_body_scan",
                    "artifact": "scan.glb",
                    "notes": "fixture",
                },
                "landmarks_m": _landmarks(),
                "registration_landmarks": [
                    "root",
                    "leftHip",
                    "rightHip",
                    "leftShoulder",
                    "rightShoulder",
                ],
                "segment_definitions": {
                    "left_femur": ["leftHip", "leftKnee"],
                    "right_femur": ["rightHip", "rightKnee"],
                },
                "segments_m": {
                    "torso": 0.52,
                },
                "joint_limits_deg": {
                    "left_knee": [0, 145],
                    "right_knee": [0, 142],
                },
                "metadata": {
                    "landmarking_method": "manual_fixture",
                },
            }
        ),
        encoding="utf-8",
    )
    return spec, scan


def test_build_body_model_hashes_scan_and_preserves_asymmetry(tmp_path):
    spec, scan = _write_spec(tmp_path)
    output = tmp_path / "body-model.json"

    profile = build_body_model_from_spec(spec, output)

    assert output.is_file()
    assert profile.model_id == "body-fixture"
    assert profile.source.artifact_sha256 == sha256_file(scan)
    assert verify_body_model_source_artifact(profile, scan) == sha256_file(scan)
    assert profile.segments_m["left_femur"] != pytest.approx(
        profile.segments_m["right_femur"]
    )
    assert profile.segments_m["torso"] == pytest.approx(0.52)
    assert profile.metadata["authoring_spec_sha256"] == sha256_file(spec)
    assert profile.metadata["segment_definition_count"] == 2


def test_build_body_model_rejects_missing_segment_landmark(tmp_path):
    spec, _scan = _write_spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["segment_definitions"]["left_femur"] = ["leftHip", "missingKnee"]
    spec.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="missing landmark"):
        build_body_model_from_spec(spec, tmp_path / "body-model.json")


def test_build_body_model_rejects_zero_length_segment(tmp_path):
    spec, _scan = _write_spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["landmarks_m"]["leftKnee"] = raw["landmarks_m"]["leftHip"]
    spec.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="zero-length"):
        build_body_model_from_spec(spec, tmp_path / "body-model.json")


def _pose_payload(
    *,
    scale_divisor: float = 1.0,
    omit: str | None = None,
) -> dict[str, object]:
    joints = {}
    for name, point in _landmarks().items():
        if name == omit:
            continue
        joints[name] = [value / scale_divisor for value in point]
    return {
        "joints_root_relative_m": joints,
        "joint_coordinate_frame": "vision_root_joint_relative_meters",
        "joint_parents": {},
        "camera_origin_matrix": [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 2.0],
            [0.0, 0.0, 0.0, 1.0],
        ],
    }


def _write_camera_session(tmp_path):
    manifest = SessionManifest(
        session_id="camera-repeatability",
        created_at_utc="2026-09-23T00:00:00+00:00",
        sport="body-registration-fixture",
        mode="calibration",
        athlete_id="local-athlete",
        devices=(
            DeviceDescriptor(
                device_id="camera",
                kind="iphone_camera",
                placement="tripod",
                streams=("/camera/pose3d",),
            ),
        ),
        metadata={
            "source_evidence_sha256": {
                "camera_mov": "a" * 64,
                "camera_frames_jsonl": "b" * 64,
            }
        },
    )
    with SessionWriter(tmp_path / "sessions", manifest) as writer:
        writer.append(
            SensorEvent(
                session_id=manifest.session_id,
                device_id="camera",
                stream="/camera/pose3d",
                sequence=0,
                device_time_ns=100_000_000,
                payload=_pose_payload(),
            )
        )
        writer.append(
            SensorEvent(
                session_id=manifest.session_id,
                device_id="camera",
                stream="/camera/pose3d",
                sequence=1,
                device_time_ns=200_000_000,
                payload=_pose_payload(scale_divisor=1.1),
            )
        )
        writer.append(
            SensorEvent(
                session_id=manifest.session_id,
                device_id="camera",
                stream="/camera/pose3d",
                sequence=2,
                device_time_ns=300_000_000,
                payload=_pose_payload(omit="rightHip"),
            )
        )
    return tmp_path / "sessions" / manifest.session_id


def test_registration_report_counts_failures_and_scale_drift(tmp_path):
    spec, _scan = _write_spec(tmp_path)
    profile_path = tmp_path / "body-model.json"
    build_body_model_from_spec(spec, profile_path)
    camera_session = _write_camera_session(tmp_path)

    report = build_body_registration_report(profile_path, camera_session)

    accounting = report["frame_accounting"]
    assert accounting["total_pose_frames"] == 3
    assert accounting["successful_registrations"] == 2
    assert accounting["failed_registrations"] == 1
    assert any(
        "missing registration landmarks: rightHip" in reason
        for reason in accounting["failure_reasons"]
    )

    assert report["residual_rms_m"]["max"] < 1e-8
    assert report["scale"]["min"] == pytest.approx(1.0, abs=1e-8)
    assert report["scale"]["max"] == pytest.approx(1.1, abs=1e-8)
    assert report["scale"]["range"] == pytest.approx(0.1, abs=1e-8)
    assert report["scale"]["coefficient_of_variation"] > 0
    assert report["successful_time_span"]["span_s"] == pytest.approx(0.1)
    assert len(report["camera_session"]["bundle_sha256"]) == 64
    assert report["camera_session"]["source_evidence_sha256"]["camera_mov"] == (
        "a" * 64
    )
    assert [frame["success"] for frame in report["frames"]] == [
        True,
        True,
        False,
    ]
