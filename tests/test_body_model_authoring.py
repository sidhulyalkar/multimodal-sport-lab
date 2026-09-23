from __future__ import annotations

import json
import math
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.body_model_authoring import (
    build_body_model_profile,
    evaluate_body_registration,
)
from motionos.provenance import sha256_file
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionWriter


def _authoring_spec(
    tmp_path: Path,
    *,
    zero_left_femur: bool = False,
    omit_left_knee: bool = False,
) -> tuple[Path, Path]:
    scan = tmp_path / "body-scan.glb"
    scan.write_bytes(b"immutable-scan-fixture")

    left_knee = [-0.16, -0.40, 0.01]
    if zero_left_femur:
        left_knee = [-0.15, 0.00, 0.00]

    landmarks = {
        "root": [0.0, 0.0, 0.0],
        "leftHip": [-0.15, 0.00, 0.00],
        "rightHip": [0.16, 0.00, 0.00],
        "leftShoulder": [-0.20, 0.50, 0.00],
        "rightShoulder": [0.22, 0.51, 0.01],
        "leftKnee": left_knee,
        "rightKnee": [0.17, -0.43, 0.02],
    }
    if omit_left_knee:
        del landmarks["leftKnee"]

    spec = tmp_path / "body-authoring.json"
    spec.write_text(
        json.dumps(
            {
                "model_id": "fixture-body",
                "height_m": 1.58,
                "frame_convention": "+X right,+Y up,+Z forward",
                "source_artifact": scan.name,
                "source_type": "3d_body_scan",
                "landmarks_m": landmarks,
                "registration_landmarks": [
                    "root",
                    "leftHip",
                    "rightHip",
                    "leftShoulder",
                    "rightShoulder",
                ],
                "segment_pairs": {
                    "left_femur": ["leftHip", "leftKnee"],
                    "right_femur": ["rightHip", "rightKnee"],
                },
                "segments_m": {
                    "torso": 0.52,
                },
                "joint_limits_deg": {},
                "metadata": {
                    "fixture": True,
                },
            }
        ),
        encoding="utf-8",
    )
    return spec, scan


def test_authoring_hashes_scan_and_computes_asymmetric_segments(tmp_path):
    spec, scan = _authoring_spec(tmp_path)
    output = tmp_path / "body-model.json"

    profile = build_body_model_profile(spec, output)

    assert profile.source.artifact_sha256 == sha256_file(scan)
    assert profile.profile_sha256 == sha256_file(output)
    assert profile.segments_m["left_femur"] == pytest.approx(
        math.dist(
            profile.landmarks_m["leftHip"],
            profile.landmarks_m["leftKnee"],
        )
    )
    assert profile.segments_m["right_femur"] == pytest.approx(
        math.dist(
            profile.landmarks_m["rightHip"],
            profile.landmarks_m["rightKnee"],
        )
    )
    assert (
        profile.segments_m["left_femur"]
        != profile.segments_m["right_femur"]
    )
    assert profile.segments_m["torso"] == pytest.approx(0.52)


def test_authoring_rejects_missing_segment_landmark(tmp_path):
    spec, _ = _authoring_spec(tmp_path, omit_left_knee=True)

    with pytest.raises(ValueError, match="missing landmarks: leftKnee"):
        build_body_model_profile(
            spec,
            tmp_path / "body-model.json",
        )


def test_authoring_rejects_zero_length_segment(tmp_path):
    spec, _ = _authoring_spec(tmp_path, zero_left_femur=True)

    with pytest.raises(ValueError, match="zero-length geometry"):
        build_body_model_profile(
            spec,
            tmp_path / "body-model.json",
        )


def _transform_point(
    point: tuple[float, float, float],
    *,
    scale: float,
    tx: float,
) -> list[float]:
    x, y, z = point
    return [
        scale * (-y) + tx,
        scale * x - 0.2,
        scale * z + 1.0,
    ]


def _camera_session(
    tmp_path: Path,
    *,
    scales: tuple[float, ...],
    corrupt_index: int | None = None,
) -> Path:
    profile_landmarks = {
        "root": (0.0, 0.0, 0.0),
        "leftHip": (-0.15, 0.0, 0.0),
        "rightHip": (0.16, 0.0, 0.0),
        "leftShoulder": (-0.20, 0.50, 0.0),
        "rightShoulder": (0.22, 0.51, 0.01),
    }

    manifest = SessionManifest(
        session_id="camera-repeatability",
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="longboard",
        mode="calibration",
        athlete_id="fixture",
        devices=(
            DeviceDescriptor(
                device_id="camera",
                kind="iphone_camera",
                placement="external",
                streams=("/camera/pose3d",),
            ),
        ),
        metadata={
            "source_evidence_sha256": {
                "camera_mov": "fixture-camera-source",
            }
        },
    )

    with SessionWriter(tmp_path / "sessions", manifest) as writer:
        for sequence, scale in enumerate(scales):
            # Invert the known body<-Vision transform so registration must
            # recover the requested scale independently for every frame.
            raw = {
                name: [
                    (point[1] + 0.2) / scale,
                    -(point[0] - 0.4) / scale,
                    (point[2] - 1.0) / scale,
                ]
                for name, point in profile_landmarks.items()
            }
            if corrupt_index == sequence:
                del raw["rightShoulder"]

            writer.append(
                SensorEvent(
                    session_id=manifest.session_id,
                    device_id="camera",
                    stream="/camera/pose3d",
                    sequence=sequence,
                    device_time_ns=sequence * 1_000_000_000,
                    payload={
                        "joints_root_relative_m": raw,
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
            )
        writer.write_metadata("fixture", {"camera": "repeatability"})

    return tmp_path / "sessions" / manifest.session_id


def _repeatability_profile(tmp_path: Path) -> Path:
    profile = tmp_path / "body-profile.json"
    profile.write_text(
        json.dumps(
            {
                "schema_version": "motionos.body-model.v2",
                "model_id": "repeatability-body",
                "height_m": 1.58,
                "frame_convention": "+X right,+Y up,+Z forward",
                "landmarks_m": {
                    "root": [0.0, 0.0, 0.0],
                    "leftHip": [-0.15, 0.0, 0.0],
                    "rightHip": [0.16, 0.0, 0.0],
                    "leftShoulder": [-0.20, 0.50, 0.0],
                    "rightShoulder": [0.22, 0.51, 0.01],
                },
                "segments_m": {},
                "joint_limits_deg": {},
                "registration_landmarks": [
                    "root",
                    "leftHip",
                    "rightHip",
                    "leftShoulder",
                    "rightShoulder",
                ],
                "source": {
                    "type": "fixture",
                    "artifact_sha256": None,
                },
                "metadata": {},
            }
        ),
        encoding="utf-8",
    )
    return profile


def test_repeatability_reports_stable_pose_series_and_provenance(tmp_path):
    profile = _repeatability_profile(tmp_path)
    camera = _camera_session(
        tmp_path,
        scales=(1.20, 1.20, 1.20, 1.20),
    )

    report = evaluate_body_registration(profile, camera)

    assert report.total_pose_frames == 4
    assert report.successful_registrations == 4
    assert report.failed_registrations == 0
    assert report.successful_span_s == pytest.approx(3.0)
    assert report.residual_rms_max is not None
    assert report.residual_rms_max < 1e-8
    assert report.scale_median == pytest.approx(1.20, abs=1e-8)
    assert report.scale_range == pytest.approx(0.0, abs=1e-8)
    assert report.scale_coefficient_of_variation == pytest.approx(
        0.0,
        abs=1e-8,
    )
    assert len(report.camera_bundle_sha256) == 64
    assert report.camera_source_evidence_sha256 == {
        "camera_mov": "fixture-camera-source"
    }


def test_repeatability_counts_corrupted_pose_without_crashing(tmp_path):
    profile = _repeatability_profile(tmp_path)
    camera = _camera_session(
        tmp_path,
        scales=(1.20, 1.20, 1.20),
        corrupt_index=1,
    )

    report = evaluate_body_registration(profile, camera)

    assert report.total_pose_frames == 3
    assert report.successful_registrations == 2
    assert report.failed_registrations == 1
    assert report.failures[0].sequence == 1
    assert "missing registration landmarks" in report.failures[0].reason


def test_repeatability_surfaces_scale_drift(tmp_path):
    profile = _repeatability_profile(tmp_path)
    camera = _camera_session(
        tmp_path,
        scales=(1.00, 1.10, 1.20, 1.30),
    )

    report = evaluate_body_registration(profile, camera)

    assert report.failed_registrations == 0
    assert report.scale_min == pytest.approx(1.00, abs=1e-8)
    assert report.scale_max == pytest.approx(1.30, abs=1e-8)
    assert report.scale_range == pytest.approx(0.30, abs=1e-8)
    assert report.scale_coefficient_of_variation is not None
    assert report.scale_coefficient_of_variation > 0.09
