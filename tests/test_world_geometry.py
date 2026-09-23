from __future__ import annotations

import json
import math
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.provenance import session_evidence_sha256, sha256_file
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter
from motionos.world_geometry import (
    _project_world_point,
    build_camera_rig_receipt,
    load_camera_calibration,
    triangulate_multiview,
    write_camera_calibration_receipt,
)


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    stream: str,
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
                streams=(stream,),
            ),
        ),
        metadata={},
    )
    with SessionWriter(root, manifest) as writer:
        writer.append(
            SensorEvent(
                session_id=session_id,
                device_id=device_id,
                stream=stream,
                sequence=0,
                device_time_ns=1_000_000_000,
                payload={"fixture": True},
            )
        )
    return root / session_id


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


def _rotation_y(degrees: float) -> list[list[float]]:
    angle = math.radians(degrees)
    cosine = math.cos(angle)
    sine = math.sin(angle)
    return [
        [cosine, 0.0, sine],
        [0.0, 1.0, 0.0],
        [-sine, 0.0, cosine],
    ]


def _world_from_camera(
    center: tuple[float, float, float],
    yaw_deg: float,
) -> list[list[float]]:
    rotation = _rotation_y(yaw_deg)
    return [
        [*rotation[0], center[0]],
        [*rotation[1], center[1]],
        [*rotation[2], center[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


def _clock(
    path: Path,
    *,
    reference: Path,
    target: Path,
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
                    "bundle_sha256": session_evidence_sha256(
                        target_reader
                    ),
                },
                "weighted_affine": {
                    "slope": 1.0,
                    "intercept_ns": 0.0,
                    "origin_device_time_ns": 1_000_000_000.0,
                    "origin_session_time_ns": 1_000_000_000.0,
                    "residual_rms_ns": 1_000_000.0,
                    "reduced_chi_square": 1.0,
                    "variance_scale": 1.0,
                    "covariance_at_origin": {
                        "origin_variance_ns2": 1_000_000.0**2,
                        "origin_slope_covariance_ns": 0.0,
                        "slope_variance": 1e-10,
                    },
                    "observations_used": 5,
                    "support_start_ns": 0,
                    "support_end_ns": 2_000_000_000,
                },
            }
        ),
        encoding="utf-8",
    )


def _calibration(
    path: Path,
    *,
    camera_id: str,
    center: tuple[float, float, float],
    yaw_deg: float,
    board: Path,
    world: Path,
    source: Path,
) -> None:
    path.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-calibration.v1",
                "calibration_id": f"{camera_id}-cal-v1",
                "camera_id": camera_id,
                "camera_frame_convention": "+X right,+Y down,+Z forward",
                "image_size_px": [1920, 1080],
                "intrinsics": [
                    [1000.0, 0.0, 960.0],
                    [0.0, 1000.0, 540.0],
                    [0.0, 0.0, 1.0],
                ],
                "distortion": {
                    "model": "none",
                    "coefficients": [],
                },
                "world_from_camera": _world_from_camera(
                    center,
                    yaw_deg,
                ),
                "world_frame": _artifact_ref(world, path.parent),
                "calibration_board": _artifact_ref(board, path.parent),
                "reprojection": {
                    "rms_px": 0.25,
                    "max_px": 0.75,
                    "observation_count": 48,
                },
                "source_evidence": [
                    {
                        "role": "calibration_capture",
                        **_artifact_ref(source, path.parent),
                    }
                ],
                "source_timestamp_basis":
                    "avcapture_presentation_timestamp",
                "camera_identity": {
                    "device_model": "iPhone fixture",
                    "camera_unique_id": camera_id,
                    "device_type": "builtInWideAngleCamera",
                    "position": "back",
                    "format_width": 1920,
                    "format_height": 1080,
                    "pixel_format": "32BGRA",
                },
                "acceptance": {
                    "max_reprojection_rms_px": 1.0,
                    "max_reprojection_max_px": 2.0,
                    "thresholds_frozen_before_review": True,
                },
                "software": {
                    "name": "fixture-calibrator",
                    "version": "1.0",
                },
                "frozen_before_rig_capture": True,
            }
        ),
        encoding="utf-8",
    )


def _mount_verification(
    path: Path,
    *,
    camera_id: str,
    session_id: str,
    calibration: Path,
    observed_world_from_camera: list[list[float]],
    source: Path,
) -> None:
    path.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.camera-mount-verification.v1",
                "camera_id": camera_id,
                "session_id": session_id,
                "calibration_sha256": sha256_file(calibration),
                "observed_world_from_camera":
                    observed_world_from_camera,
                "source_evidence": [
                    {
                        "role": "mount_check_image",
                        **_artifact_ref(source, path.parent),
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


def _fixture(tmp_path: Path) -> dict[str, Path]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()
    sessions = tmp_path / "sessions"

    board_source = artifacts / "charuco-board.pdf"
    board_source.write_bytes(b"fixture-charuco-board")
    board = artifacts / "board.json"
    board.write_text(
        json.dumps(
            {
                "schema_version": "motionos.calibration-board.v1",
                "board_id": "charuco-7x5-v1",
                "board_type": "charuco",
                "squares_x": 7,
                "squares_y": 5,
                "square_length_m": 0.04,
                "marker_length_m": 0.03,
                "dictionary": "DICT_5X5_1000",
                "printable_source_sha256": sha256_file(board_source),
            }
        ),
        encoding="utf-8",
    )

    world = artifacts / "world.json"
    world.write_text(
        json.dumps(
            {
                "schema_version": "motionos.world-frame.v1",
                "frame_id": "longboard-calibration-world-v1",
                "units": "m",
                "axes": {
                    "x": "rider right",
                    "y": "up",
                    "z": "forward along calibration lane",
                },
                "origin_description":
                    "center of ChArUco board bottom edge",
                "gravity_direction": [0.0, -1.0, 0.0],
                "calibration_board_sha256": sha256_file(board),
            }
        ),
        encoding="utf-8",
    )

    watch = _write_session(
        sessions,
        session_id="watch-reference",
        device_id="watch",
        stream="/body/watch/imu",
    )
    camera_a = _write_session(
        sessions,
        session_id="camera-a-session",
        device_id="cam-a",
        stream="/camera/frame",
    )
    camera_b = _write_session(
        sessions,
        session_id="camera-b-session",
        device_id="cam-b",
        stream="/camera/frame",
    )

    source_a = artifacts / "cam-a-calibration-source.bin"
    source_b = artifacts / "cam-b-calibration-source.bin"
    source_a.write_bytes(b"camera-a-calibration-source")
    source_b.write_bytes(b"camera-b-calibration-source")

    calibration_a = artifacts / "cam-a-calibration.json"
    calibration_b = artifacts / "cam-b-calibration.json"
    _calibration(
        calibration_a,
        camera_id="cam-a",
        center=(-0.5, 0.0, 0.0),
        yaw_deg=5.0,
        board=board,
        world=world,
        source=source_a,
    )
    _calibration(
        calibration_b,
        camera_id="cam-b",
        center=(0.5, 0.0, 0.0),
        yaw_deg=-5.0,
        board=board,
        world=world,
        source=source_b,
    )

    clock_a = artifacts / "cam-a-clock.json"
    clock_b = artifacts / "cam-b-clock.json"
    _clock(clock_a, reference=watch, target=camera_a)
    _clock(clock_b, reference=watch, target=camera_b)

    mount_source_a = artifacts / "cam-a-mount-check.jpg"
    mount_source_b = artifacts / "cam-b-mount-check.jpg"
    mount_source_a.write_bytes(b"camera-a-mount-check")
    mount_source_b.write_bytes(b"camera-b-mount-check")

    mount_a = artifacts / "cam-a-mount.json"
    mount_b = artifacts / "cam-b-mount.json"
    _mount_verification(
        mount_a,
        camera_id="cam-a",
        session_id="camera-a-session",
        calibration=calibration_a,
        observed_world_from_camera=_world_from_camera(
            (-0.5, 0.0, 0.0),
            5.0,
        ),
        source=mount_source_a,
    )
    _mount_verification(
        mount_b,
        camera_id="cam-b",
        session_id="camera-b-session",
        calibration=calibration_b,
        observed_world_from_camera=_world_from_camera(
            (0.5, 0.0, 0.0),
            -5.0,
        ),
        source=mount_source_b,
    )

    rig_spec = tmp_path / "rig-spec.json"
    rig_spec.write_text(
        json.dumps(
            {
                "schema_version": "motionos.camera-rig-spec.v1",
                "rig_id": "longboard-two-camera-v1",
                "thresholds_frozen_before_review": True,
                "min_pairwise_baseline_m": 0.75,
                "min_pairwise_view_angle_deg": 5.0,
                "max_mount_translation_drift_m": 0.01,
                "max_mount_rotation_drift_deg": 1.0,
                "max_correspondence_time_delta_ms": 10.0,
                "reference_session": _session_ref(watch, tmp_path),
                "cameras": [
                    {
                        "calibration": _artifact_ref(
                            calibration_a,
                            tmp_path,
                        ),
                        "camera_session": _session_ref(
                            camera_a,
                            tmp_path,
                        ),
                        "clock_uncertainty": _artifact_ref(
                            clock_a,
                            tmp_path,
                        ),
                        "mount_verification": _artifact_ref(
                            mount_a,
                            tmp_path,
                        ),
                    },
                    {
                        "calibration": _artifact_ref(
                            calibration_b,
                            tmp_path,
                        ),
                        "camera_session": _session_ref(
                            camera_b,
                            tmp_path,
                        ),
                        "clock_uncertainty": _artifact_ref(
                            clock_b,
                            tmp_path,
                        ),
                        "mount_verification": _artifact_ref(
                            mount_b,
                            tmp_path,
                        ),
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    return {
        "board": board,
        "world": world,
        "watch": watch,
        "camera_a": camera_a,
        "camera_b": camera_b,
        "calibration_a": calibration_a,
        "calibration_b": calibration_b,
        "clock_a": clock_a,
        "clock_b": clock_b,
        "mount_a": mount_a,
        "mount_b": mount_b,
        "mount_source_a": mount_source_a,
        "mount_source_b": mount_source_b,
        "rig_spec": rig_spec,
    }


def test_camera_calibration_receipt_preserves_metric_contract(tmp_path):
    paths = _fixture(tmp_path)
    output = tmp_path / "camera-calibration-receipt.json"

    receipt = write_camera_calibration_receipt(
        paths["calibration_a"],
        output,
    )

    assert receipt["passed"] is True
    calibration = receipt["calibration"]
    assert calibration["camera_id"] == "cam-a"
    assert calibration["distortion"]["model"] == "none"
    assert calibration["world_frame"]["units"] == "m"
    assert calibration["calibration_board"]["board_type"] == "charuco"
    assert calibration["frozen_before_rig_capture"] is True
    assert calibration["acceptance"]["passed"] is True
    assert calibration["camera_identity"]["camera_unique_id"] == "cam-a"
    assert calibration["source_timestamp_basis"] == (
        "avcapture_presentation_timestamp"
    )


def test_two_camera_rig_requires_shared_world_clock_and_stable_mounts(
    tmp_path,
):
    paths = _fixture(tmp_path)
    receipt = build_camera_rig_receipt(
        paths["rig_spec"],
        tmp_path / "rig.json",
    )

    assert receipt["passed"] is True
    assert receipt["gates"]["pairwise_geometry_passed"] is True
    assert receipt["gates"]["mount_stability_passed"] is True
    assert receipt["pairwise_geometry"][0]["baseline_m"] == pytest.approx(
        1.0
    )
    assert receipt["pairwise_geometry"][0][
        "view_axis_angle_deg"
    ] == pytest.approx(10.0, abs=1e-6)
    assert len(receipt["cameras"]) == 2


def test_moved_camera_fails_mount_stability_gate(tmp_path):
    paths = _fixture(tmp_path)
    _mount_verification(
        paths["mount_b"],
        camera_id="cam-b",
        session_id="camera-b-session",
        calibration=paths["calibration_b"],
        observed_world_from_camera=_world_from_camera(
            (0.55, 0.0, 0.0),
            -5.0,
        ),
        source=paths["mount_source_b"],
    )
    spec = json.loads(paths["rig_spec"].read_text(encoding="utf-8"))
    spec["cameras"][1]["mount_verification"]["sha256"] = sha256_file(
        paths["mount_b"]
    )
    paths["rig_spec"].write_text(json.dumps(spec), encoding="utf-8")

    receipt = build_camera_rig_receipt(
        paths["rig_spec"],
        tmp_path / "rig.json",
    )

    assert receipt["passed"] is False
    assert receipt["gates"]["mount_stability_passed"] is False
    assert receipt["cameras"][1]["mount_translation_drift_m"] > 0.04


def test_changed_calibration_bytes_fail_closed(tmp_path):
    paths = _fixture(tmp_path)
    raw = json.loads(
        paths["calibration_a"].read_text(encoding="utf-8")
    )
    raw["reprojection"]["rms_px"] = 99.0
    paths["calibration_a"].write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="calibration.*hash mismatch"):
        build_camera_rig_receipt(
            paths["rig_spec"],
            tmp_path / "rig.json",
        )


def test_clock_mapping_must_bind_exact_camera_session(tmp_path):
    paths = _fixture(tmp_path)
    clock = json.loads(paths["clock_a"].read_text(encoding="utf-8"))
    clock["target"]["session_id"] = "wrong-camera-session"
    paths["clock_a"].write_text(json.dumps(clock), encoding="utf-8")
    spec = json.loads(paths["rig_spec"].read_text(encoding="utf-8"))
    spec["cameras"][0]["clock_uncertainty"]["sha256"] = sha256_file(
        paths["clock_a"]
    )
    paths["rig_spec"].write_text(json.dumps(spec), encoding="utf-8")

    with pytest.raises(ValueError, match="clock target session mismatch"):
        build_camera_rig_receipt(
            paths["rig_spec"],
            tmp_path / "rig.json",
        )


def test_multiview_triangulation_recovers_known_world_point(tmp_path):
    paths = _fixture(tmp_path)
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)
    assert rig["passed"] is True

    point_world = (0.0, 0.1, 5.0)
    calibration_a = load_camera_calibration(paths["calibration_a"])
    calibration_b = load_camera_calibration(paths["calibration_b"])
    pixel_a = _project_world_point(calibration_a, point_world)
    pixel_b = _project_world_point(calibration_b, point_world)

    correspondences = tmp_path / "correspondences.json"
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "rig_id": rig["rig_id"],
                "rig_receipt_sha256": sha256_file(rig_path),
                "frozen_before_geometry_review": True,
                "points": [
                    {
                        "point_id": "known-point",
                        "reference_time_ns": 1_000_000_000,
                        "observations": {
                            "cam-a": {
                                "u_px": pixel_a[0],
                                "v_px": pixel_a[1],
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000,
                            },
                            "cam-b": {
                                "u_px": pixel_b[0],
                                "v_px": pixel_b[1],
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000,
                            },
                        },
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    measurements = tmp_path / "geometry-measurements.json"
    report = triangulate_multiview(
        rig_path,
        correspondences,
        tmp_path / "geometry-report.json",
        measurements_output_path=measurements,
    )

    recovered = report["points"][0]["world_position_m"]
    assert recovered == pytest.approx(point_world, abs=1e-7)
    assert report["reprojection_residual_px"]["max"] < 1e-6
    assert report["ray_disagreement_rms_m"]["max"] < 1e-7

    measurement_payload = json.loads(
        measurements.read_text(encoding="utf-8")
    )
    assert measurement_payload["schema_version"] == (
        "motionos.geometry-measurements.v1"
    )
    metrics = {
        item["metric"]
        for item in measurement_payload["measurements"]
    }
    assert metrics == {
        "camera_reprojection_residual_px",
        "cross_view_triangulation_disagreement_m",
    }


def test_nonpassing_rig_cannot_claim_world_triangulation(tmp_path):
    paths = _fixture(tmp_path)
    spec = json.loads(paths["rig_spec"].read_text(encoding="utf-8"))
    spec["min_pairwise_view_angle_deg"] = 30.0
    paths["rig_spec"].write_text(json.dumps(spec), encoding="utf-8")
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)
    assert rig["passed"] is False

    correspondences = tmp_path / "correspondences.json"
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "rig_id": rig["rig_id"],
                "rig_receipt_sha256": sha256_file(rig_path),
                "frozen_before_geometry_review": True,
                "points": [
                    {
                        "point_id": "unreachable",
                        "reference_time_ns": 1,
                        "observations": {
                            "cam-a": {
                                "u_px": 960.0,
                                "v_px": 540.0,
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000
                            },
                            "cam-b": {
                                "u_px": 960.0,
                                "v_px": 540.0,
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000
                            },
                        },
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="passing camera-rig receipt"):
        triangulate_multiview(
            rig_path,
            correspondences,
            tmp_path / "geometry-report.json",
        )


def test_correspondence_receipt_hash_is_immutable(tmp_path):
    paths = _fixture(tmp_path)
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)
    correspondences = tmp_path / "correspondences.json"
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "rig_id": rig["rig_id"],
                "rig_receipt_sha256": "0" * 64,
                "frozen_before_geometry_review": True,
                "points": [
                    {
                        "point_id": "p",
                        "reference_time_ns": 1,
                        "observations": {
                            "cam-a": {
                                "u_px": 960.0,
                                "v_px": 540.0,
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000
                            },
                            "cam-b": {
                                "u_px": 960.0,
                                "v_px": 540.0,
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000
                            },
                        },
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="rig receipt hash mismatch"):
        triangulate_multiview(
            rig_path,
            correspondences,
            tmp_path / "geometry-report.json",
        )


def test_bad_reprojection_quality_fails_calibration_and_rig_gate(tmp_path):
    paths = _fixture(tmp_path)
    raw = json.loads(
        paths["calibration_a"].read_text(encoding="utf-8")
    )
    raw["reprojection"]["rms_px"] = 1.5
    raw["reprojection"]["max_px"] = 2.5
    paths["calibration_a"].write_text(json.dumps(raw), encoding="utf-8")

    calibration_receipt = write_camera_calibration_receipt(
        paths["calibration_a"],
        tmp_path / "camera-receipt.json",
    )
    assert calibration_receipt["passed"] is False

    mount = json.loads(paths["mount_a"].read_text(encoding="utf-8"))
    mount["calibration_sha256"] = sha256_file(paths["calibration_a"])
    paths["mount_a"].write_text(json.dumps(mount), encoding="utf-8")

    spec = json.loads(paths["rig_spec"].read_text(encoding="utf-8"))
    spec["cameras"][0]["calibration"]["sha256"] = sha256_file(
        paths["calibration_a"]
    )
    spec["cameras"][0]["mount_verification"]["sha256"] = sha256_file(
        paths["mount_a"]
    )
    paths["rig_spec"].write_text(json.dumps(spec), encoding="utf-8")

    rig = build_camera_rig_receipt(
        paths["rig_spec"],
        tmp_path / "rig.json",
    )
    assert rig["passed"] is False
    assert rig["gates"]["camera_calibration_quality_passed"] is False


def test_multiview_correspondence_time_must_match_reference(tmp_path):
    paths = _fixture(tmp_path)
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)

    calibration_a = load_camera_calibration(paths["calibration_a"])
    calibration_b = load_camera_calibration(paths["calibration_b"])
    point_world = (0.0, 0.0, 5.0)
    pixel_a = _project_world_point(calibration_a, point_world)
    pixel_b = _project_world_point(calibration_b, point_world)

    correspondences = tmp_path / "bad-time.json"
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "rig_id": rig["rig_id"],
                "rig_receipt_sha256": sha256_file(rig_path),
                "frozen_before_geometry_review": True,
                "points": [
                    {
                        "point_id": "time-mismatch",
                        "reference_time_ns": 1_000_000_000,
                        "observations": {
                            "cam-a": {
                                "u_px": pixel_a[0],
                                "v_px": pixel_a[1],
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_000_000_000,
                            },
                            "cam-b": {
                                "u_px": pixel_b[0],
                                "v_px": pixel_b[1],
                                "source_frame_sequence": 0,
                                "source_frame_pts_ns": 1_100_000_000,
                            },
                        },
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="correspondence time tolerance"):
        triangulate_multiview(
            rig_path,
            correspondences,
            tmp_path / "geometry-report.json",
        )


def test_multiview_correspondence_cannot_extrapolate_clock(tmp_path):
    paths = _fixture(tmp_path)
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)
    calibration_a = load_camera_calibration(paths["calibration_a"])
    calibration_b = load_camera_calibration(paths["calibration_b"])
    point_world = (0.0, 0.0, 5.0)
    pixel_a = _project_world_point(calibration_a, point_world)
    pixel_b = _project_world_point(calibration_b, point_world)

    correspondences = tmp_path / "outside-support.json"
    correspondences.write_text(
        json.dumps(
            {
                "schema_version":
                    "motionos.multiview-correspondences.v1",
                "rig_id": rig["rig_id"],
                "rig_receipt_sha256": sha256_file(rig_path),
                "frozen_before_geometry_review": True,
                "points": [
                    {
                        "point_id": "outside-support",
                        "reference_time_ns": 3_000_000_000,
                        "observations": {
                            "cam-a": {
                                "u_px": pixel_a[0],
                                "v_px": pixel_a[1],
                                "source_frame_sequence": 1,
                                "source_frame_pts_ns": 3_000_000_000,
                            },
                            "cam-b": {
                                "u_px": pixel_b[0],
                                "v_px": pixel_b[1],
                                "source_frame_sequence": 1,
                                "source_frame_pts_ns": 3_000_000_000,
                            },
                        },
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="outside clock landmark support"):
        triangulate_multiview(
            rig_path,
            correspondences,
            tmp_path / "geometry-report.json",
        )
