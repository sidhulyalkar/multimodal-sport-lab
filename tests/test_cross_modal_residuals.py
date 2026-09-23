from __future__ import annotations

import hashlib
import json
import math
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.camera import CAMERA_POSE_STREAM
from motionos.cross_modal_residuals import build_cross_modal_residual_report
from motionos.provenance import session_evidence_sha256, sha256_file
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    streams: dict[str, list[tuple[int, dict[str, object]]]],
) -> Path:
    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="longboard",
        mode="calibration",
        athlete_id="fixture",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="fixture",
                placement="fixture",
                streams=tuple(streams),
            ),
        ),
        metadata={},
    )
    with SessionWriter(root, manifest) as writer:
        for stream, samples in streams.items():
            for sequence, (time_ns, payload) in enumerate(samples):
                writer.append(
                    SensorEvent(
                        session_id=session_id,
                        device_id=device_id,
                        stream=stream,
                        sequence=sequence,
                        device_time_ns=time_ns,
                        payload=payload,
                    )
                )
    return root / session_id


def _pose(vector):
    return {
        "joints_root_relative_m": {
            "leftElbow": [0.0, 0.0, 0.0],
            "leftWrist": list(vector),
        },
        "joint_coordinate_frame": "vision_root_joint_relative_meters",
    }


def _clock_analysis(
    path: Path,
    *,
    reference: Path,
    target: Path,
    residual_rms_ns: float = 2_000_000.0,
) -> None:
    reference_reader = SessionReader(reference)
    target_reader = SessionReader(target)
    path.write_text(
        json.dumps(
            {
                "schema_version": "motionos.clock-uncertainty.v1",
                "reference": {
                    "session_id": reference_reader.manifest.session_id,
                    "bundle_sha256": session_evidence_sha256(
                        reference_reader
                    ),
                },
                "target": {
                    "session_id": target_reader.manifest.session_id,
                    "bundle_sha256": session_evidence_sha256(target_reader),
                },
                "weighted_affine": {
                    "slope": 1.0,
                    "intercept_ns": 0.0,
                    "origin_device_time_ns": 1_000_000_000.0,
                    "origin_session_time_ns": 1_000_000_000.0,
                    "residual_rms_ns": residual_rms_ns,
                    "reduced_chi_square": 1.0,
                    "variance_scale": 1.0,
                    "covariance_at_origin": {
                        "origin_variance_ns2": 1_000_000.0**2,
                        "origin_slope_covariance_ns": 0.0,
                        "slope_variance": 1e-8,
                    },
                    "observations_used": 5,
                    "support_start_ns": 0,
                    "support_end_ns": 5_000_000_000,
                },
            }
        ),
        encoding="utf-8",
    )


def _artifact_ref(path: Path, base: Path) -> dict[str, str]:
    return {
        "path": str(path.relative_to(base)),
        "sha256": sha256_file(path),
    }


def _session_ref(path: Path, base: Path) -> dict[str, str]:
    return {
        "session": str(path.relative_to(base)),
        "bundle_sha256": session_evidence_sha256(SessionReader(path)),
    }


def _fixture(tmp_path: Path) -> tuple[Path, dict[str, Path]]:
    sessions = tmp_path / "sessions"
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()

    camera = _write_session(
        sessions,
        session_id="camera",
        device_id="camera",
        streams={
            CAMERA_POSE_STREAM: [
                (0, _pose((1.0, 0.0, 0.0))),
                (1_000_000_000, _pose((0.0, 1.0, 0.0))),
                (2_000_000_000, _pose((-1.0, 0.0, 0.0))),
                # Deliberate dropout/gap. The benchmark must not
                # differentiate across this interval.
                (5_000_000_000, _pose((0.0, -1.0, 0.0))),
            ]
        },
    )

    rate = math.pi / 2.0
    imu = _write_session(
        sessions,
        session_id="watch",
        device_id="watch",
        streams={
            "/body/watch/imu": [
                (
                    1_000_000_000,
                    {
                        "gx": 0.0,
                        "gy": 0.0,
                        "gz": rate,
                    },
                ),
                (
                    2_000_000_000,
                    {
                        "gx": 0.0,
                        "gy": 0.0,
                        "gz": rate,
                    },
                ),
            ]
        },
    )

    pressure = _write_session(
        sessions,
        session_id="insoles",
        device_id="left-insole",
        streams={
            "/body/left_foot/pressure": [
                (0, {"normal_force_n": 0.0}),
                (1_040_000_000, {"normal_force_n": 120.0}),
                (2_040_000_000, {"normal_force_n": 0.0}),
            ]
        },
    )

    imu_clock = artifacts / "imu-clock.json"
    pressure_clock = artifacts / "pressure-clock.json"
    _clock_analysis(imu_clock, reference=camera, target=imu)
    _clock_analysis(pressure_clock, reference=camera, target=pressure)

    contacts = artifacts / "visual-contact.json"
    contacts.write_text(
        json.dumps(
            {
                "schema_version": "motionos.visual-contact-events.v1",
                "events": [
                    {
                        "time_ns": 1_000_000_000,
                        "side": "left",
                        "event": "contact_onset",
                        "uncertainty_ns": 3_000_000,
                    },
                    {
                        "time_ns": 2_000_000_000,
                        "side": "left",
                        "event": "contact_release",
                        "uncertainty_ns": 3_000_000,
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    strata = artifacts / "strata.json"
    strata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.robustness-strata.v1",
                "intervals": [
                    {
                        "start_ns": 0,
                        "end_ns": 1_500_000_000,
                        "labels": {
                            "motion_speed": "slow",
                            "occlusion": "clear",
                            "pose_confidence": "high",
                            "distance_framing": "near",
                            "sensor_gap": "none",
                            "day_id": "day-1",
                            "remount_id": "mount-1",
                            "camera_view": "side",
                        },
                    },
                    {
                        "start_ns": 1_500_000_001,
                        "end_ns": 5_000_000_000,
                        "labels": {
                            "motion_speed": "fast",
                            "occlusion": "partial",
                            "pose_confidence": "medium",
                            "distance_framing": "far",
                            "sensor_gap": "dropout",
                            "day_id": "day-1",
                            "remount_id": "mount-1",
                            "camera_view": "side",
                        },
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    registration = artifacts / "registration.json"
    registration.write_text(
        json.dumps(
            {
                "schema_version": "motionos.body-registration-report.v1",
                "frames": [
                    {
                        "device_time_ns": 1_000_000_000,
                        "success": True,
                        "residual_rms_m": 0.01,
                    },
                    {
                        "device_time_ns": 2_000_000_000,
                        "success": True,
                        "residual_rms_m": 0.02,
                    },
                    {
                        "device_time_ns": 3_000_000_000,
                        "success": False,
                        "residual_rms_m": None,
                    },
                ],
                "claim_boundary": "fixture repeatability only",
            }
        ),
        encoding="utf-8",
    )

    geometry = artifacts / "geometry.json"
    geometry.write_text(
        json.dumps(
            {
                "schema_version": "motionos.geometry-measurements.v1",
                "measurements": [
                    {
                        "time_ns": 1_000_000_000,
                        "metric": "camera_reprojection_residual_px",
                        "value": 2.0,
                        "unit": "px",
                    },
                    {
                        "time_ns": 2_000_000_000,
                        "metric": "camera_reprojection_residual_px",
                        "value": 4.0,
                        "unit": "px",
                    },
                    {
                        "time_ns": 2_000_000_000,
                        "metric":
                            "cross_view_triangulation_disagreement_m",
                        "value": 0.015,
                        "unit": "m",
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    spec = tmp_path / "residual-spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.cross-modal-residual-spec.v1",
                "experiment_id": "fixture-residuals",
                "camera": _session_ref(camera, tmp_path),
                "strata": _artifact_ref(strata, tmp_path),
                "imu_video": [
                    {
                        "comparison_id": "left-forearm",
                        "imu": _session_ref(imu, tmp_path),
                        "clock_uncertainty": _artifact_ref(
                            imu_clock,
                            tmp_path,
                        ),
                        "stream": "/body/watch/imu",
                        "proximal_joint": "leftElbow",
                        "distal_joint": "leftWrist",
                        "imu_to_pose_rotation": [
                            [1.0, 0.0, 0.0],
                            [0.0, 1.0, 0.0],
                            [0.0, 0.0, 1.0],
                        ],
                        "max_pairing_delta_ms": 20.0,
                        "max_pose_interval_ms": 1500.0,
                    }
                ],
                "pressure_video": [
                    {
                        "comparison_id": "left-contact",
                        "side": "left",
                        "insole": _session_ref(pressure, tmp_path),
                        "clock_uncertainty": _artifact_ref(
                            pressure_clock,
                            tmp_path,
                        ),
                        "visual_events": _artifact_ref(
                            contacts,
                            tmp_path,
                        ),
                        "stream": "/body/left_foot/pressure",
                        "force_threshold_n": 50.0,
                        "max_match_delta_ms": 100.0,
                    }
                ],
                "body_registration_report": _artifact_ref(
                    registration,
                    tmp_path,
                ),
                "geometry_measurements": _artifact_ref(
                    geometry,
                    tmp_path,
                ),
            }
        ),
        encoding="utf-8",
    )
    return spec, {
        "camera": camera,
        "imu": imu,
        "pressure": pressure,
        "imu_clock": imu_clock,
        "pressure_clock": pressure_clock,
        "contacts": contacts,
        "strata": strata,
        "registration": registration,
        "geometry": geometry,
    }


def test_cross_modal_report_recovers_known_lag_and_zero_angular_residual(
    tmp_path,
):
    spec, _paths = _fixture(tmp_path)
    output = tmp_path / "report.json"

    report = build_cross_modal_residual_report(spec, output)

    assert report["schema_version"] == (
        "motionos.cross-modal-residual-report.v1"
    )
    imu = report["imu_video"][0]
    assert imu["pairing"]["matched_samples"] == 2
    assert imu["pairing"]["skipped_visual_intervals"][
        "pose_interval_too_large"
    ] == 1
    assert imu["residual_norm_rad_s"]["max_abs"] == pytest.approx(0.0)

    pressure = report["pressure_video"][0]
    assert pressure["matching"]["matched_events"] == 2
    assert pressure["residual_ms"]["mean"] == pytest.approx(40.0)
    assert pressure["samples"][0][
        "absolute_residual_over_combined_std"
    ] > 1.0

    geometry = report["geometry"]
    body = geometry["body_registration"]
    assert body["successful_frames"] == 2
    assert body["failed_frames"] == 1
    assert body["residual_rms_m"]["mean"] == pytest.approx(0.015)

    explicit = geometry["explicit_measurements"]["metrics"]
    assert explicit["camera_reprojection_residual_px"][
        "distribution"
    ]["mean"] == pytest.approx(3.0)
    assert explicit["cross_view_triangulation_disagreement_m"][
        "distribution"
    ]["mean"] == pytest.approx(0.015)


def test_report_stratifies_occlusion_speed_dropout_and_view(tmp_path):
    spec, _paths = _fixture(tmp_path)

    report = build_cross_modal_residual_report(
        spec,
        tmp_path / "report.json",
    )

    imu_strata = report["imu_video"][0][
        "stratified_residual_norm_rad_s"
    ]
    assert set(imu_strata["occlusion"]) == {"clear", "partial"}
    assert set(imu_strata["motion_speed"]) == {"fast", "slow"}
    assert set(imu_strata["sensor_gap"]) == {"dropout", "none"}
    assert set(imu_strata["camera_view"]) == {"side"}

    pressure_strata = report["pressure_video"][0][
        "stratified_residual_ms"
    ]
    assert set(pressure_strata["pose_confidence"]) == {
        "high",
        "medium",
    }


def test_report_has_no_scalar_aggregate_quality_score(tmp_path):
    spec, _paths = _fixture(tmp_path)

    report = build_cross_modal_residual_report(
        spec,
        tmp_path / "report.json",
    )

    assert report.get("aggregate_quality_score") is None
    assert "forbidden" in report["aggregate_quality_score_policy"]


def test_residual_spec_hash_binding_rejects_edited_clock(tmp_path):
    spec, paths = _fixture(tmp_path)
    original = json.loads(paths["imu_clock"].read_text(encoding="utf-8"))
    original["weighted_affine"]["intercept_ns"] = 123.0
    paths["imu_clock"].write_text(json.dumps(original), encoding="utf-8")

    with pytest.raises(ValueError, match="hash mismatch"):
        build_cross_modal_residual_report(
            spec,
            tmp_path / "report.json",
        )


def test_clock_analysis_must_bind_exact_target_session(tmp_path):
    spec, paths = _fixture(tmp_path)
    spec_raw = json.loads(spec.read_text(encoding="utf-8"))

    clock_raw = json.loads(
        paths["imu_clock"].read_text(encoding="utf-8")
    )
    clock_raw["target"]["session_id"] = "wrong-session"
    paths["imu_clock"].write_text(json.dumps(clock_raw), encoding="utf-8")
    spec_raw["imu_video"][0]["clock_uncertainty"]["sha256"] = sha256_file(
        paths["imu_clock"]
    )
    spec.write_text(json.dumps(spec_raw), encoding="utf-8")

    with pytest.raises(ValueError, match="target session ID mismatch"):
        build_cross_modal_residual_report(
            spec,
            tmp_path / "report.json",
        )


def test_rotation_matrix_must_be_proper(tmp_path):
    spec, _paths = _fixture(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["imu_video"][0]["imu_to_pose_rotation"] = [
        [1.0, 0.0, 0.0],
        [1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
    ]
    spec.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="not orthogonal"):
        build_cross_modal_residual_report(
            spec,
            tmp_path / "report.json",
        )
