from __future__ import annotations

import json
from pathlib import Path

import pytest

from motionos.personalized_kinematics import build_personalized_kinematics
from motionos.provenance import sha256_file


def _write(path: Path, object_: dict) -> Path:
    path.write_text(json.dumps(object_, indent=2) + "\n", encoding="utf-8")
    return path


def _fixture(tmp_path: Path) -> dict[str, Path]:
    world = _write(
        tmp_path / "world.json",
        {
            "schema_version": "motionos.world-frame.v1",
            "frame_id": "local-research",
            "units": "m",
            "axes": {"x": "rider right", "y": "up", "z": "forward"},
            "gravity_direction": [0, -1, 0],
        },
    )
    rig = _write(
        tmp_path / "rig.json",
        {
            "schema_version": "motionos.camera-rig-receipt.v1",
            "rig_id": "two-fixed-cameras",
            "passed": True,
            "world_frame_sha256": sha256_file(world),
        },
    )
    profile = _write(
        tmp_path / "body.json",
        {
            "schema_version": "motionos.body-model.v2",
            "model_id": "fixture-body",
            "height_m": 1.7,
            "frame_convention": "+X right,+Y up,+Z forward",
            "landmarks_m": {
                "root": [0, 1.0, 0],
                "leftHip": [-0.1, 1.1, 0],
                "rightHip": [0.1, 1.1, 0],
            },
            "segments_m": {
                "left_femur": 0.4,
                "right_femur": 0.4,
                "left_tibia": 0.4,
                "right_tibia": 0.4,
            },
            "joint_limits_deg": {},
            "registration_landmarks": ["root", "leftHip", "rightHip"],
            "source": {"type": "example_only", "artifact_sha256": None},
            "metadata": {},
        },
    )

    geometry_points: list[dict] = []
    frames: list[dict] = []
    points = {
        "leftHip": [-0.1, 1.1, 0],
        "leftKnee": [-0.1, 0.7, 0],
        "leftAnkle": [-0.1, 0.3, 0],
        "rightHip": [0.1, 1.1, 0],
        "rightKnee": [0.1, 0.7, 0],
        "rightAnkle": [0.1, 0.3, 0],
    }
    for index, time_ns in enumerate([1000000000, 1033333333, 1066666666]):
        frame_map: dict[str, str] = {}
        for joint, coordinate in points.items():
            pid = f"{index}:{joint}"
            geometry_points.append(
                {
                    "point_id": pid,
                    "reference_time_ns": time_ns,
                    "world_position_m": coordinate,
                    "mean_reprojection_residual_px": 0.5,
                    "ray_disagreement_rms_m": 0.002,
                }
            )
            frame_map[joint] = pid
        frames.append({"reference_time_ns": time_ns, "joints": frame_map})

    geometry = _write(
        tmp_path / "geometry.json",
        {
            "schema_version": "motionos.multiview-geometry-report.v1",
            "rig_id": "two-fixed-cameras",
            "rig_receipt_sha256": sha256_file(rig),
            "world_frame_sha256": sha256_file(world),
            "correspondences_sha256": "1" * 64,
            "points": geometry_points,
        },
    )
    mapping = _write(
        tmp_path / "map.json",
        {
            "schema_version": "motionos.kinematic-joint-map.v1",
            "subject_id": "participant-A",
            "geometry_report_sha256": sha256_file(geometry),
            "frames": frames,
        },
    )
    return {"geometry": geometry, "rig": rig, "world": world, "body": profile, "map": mapping}


def _run(paths: dict[str, Path], tmp_path: Path, **kwargs: object) -> dict:
    return build_personalized_kinematics(
        paths["geometry"],
        paths["rig"],
        paths["world"],
        paths["body"],
        paths["map"],
        tmp_path / "kinematics.json",
        **kwargs,
    )


def test_exports_personal_trajectory_and_trc_without_force_claims(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    trc = tmp_path / "markers.trc"
    report = _run(paths, tmp_path, trc_path=trc)
    assert report["schema_version"] == "motionos.personalized-kinematics.v1"
    assert report["frame_count"] == 3
    assert report["source"]["geometry_report_sha256"] == sha256_file(paths["geometry"])
    assert report["body_model_personalized_source_verified"] is False
    assert len(report["discontinuities"]) == 0
    assert report["frames"][0]["joint_angles_deg"]["left_knee_flexion_deg"] == 0.0
    assert report["frames"][0]["joint_angles_deg"]["right_knee_flexion_deg"] == 0.0
    assert report["trc_sha256"] == sha256_file(trc)
    assert "NumMarkers" in trc.read_text()
    assert "muscle force" in report["claim_boundary"]


def test_fail_closed_on_mismatched_rig_hash(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    rig = json.loads(paths["rig"].read_text())
    rig["passed"] = False
    _write(paths["rig"], rig)
    with pytest.raises(ValueError, match="passing camera rig"):
        _run(paths, tmp_path)
    assert not (tmp_path / "kinematics.json").exists()


def test_no_unverified_scan_claim(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    profile = json.loads(paths["body"].read_text())
    profile["source"] = {"type": "3d_scan", "artifact_sha256": "a" * 64}
    _write(paths["body"], profile)
    with pytest.raises(ValueError, match="source must be supplied"):
        _run(paths, tmp_path)


def test_wrong_point_time_is_not_silently_aligned(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    geo = json.loads(paths["geometry"].read_text())
    geo["points"][0]["reference_time_ns"] += 1
    _write(paths["geometry"], geo)
    map_ = json.loads(paths["map"].read_text())
    map_["geometry_report_sha256"] = sha256_file(paths["geometry"])
    _write(paths["map"], map_)
    with pytest.raises(ValueError, match="source timestamp"):
        _run(paths, tmp_path)


def test_low_quality_marker_is_dropped_and_knee_angle_suppressed(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    geo = json.loads(paths["geometry"].read_text())
    geo["points"][1]["mean_reprojection_residual_px"] = 200.0
    _write(paths["geometry"], geo)
    map_ = json.loads(paths["map"].read_text())
    map_["geometry_report_sha256"] = sha256_file(paths["geometry"])
    _write(paths["map"], map_)
    report = _run(paths, tmp_path)
    assert report["rejected_joint_observations"] == 1
    frame = report["frames"][0]
    assert "leftKnee" not in frame["markers_world_m"]
    assert "left_knee_flexion_deg" not in frame["joint_angles_deg"]
    assert frame["skipped_joint_angles"]["left_knee_flexion_deg"] == (
        "joint_unobserved_or_rejected"
    )


def test_personal_segment_mismatch_suppresses_angle(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    body = json.loads(paths["body"].read_text())
    body["segments_m"]["left_femur"] = 0.2
    _write(paths["body"], body)
    report = _run(paths, tmp_path)
    assert "left_knee_flexion_deg" not in report["frames"][0]["joint_angles_deg"]
    assert report["frames"][0]["skipped_joint_angles"]["left_knee_flexion_deg"] == (
        "personal_segment_geometry_disagreement"
    )
    assert "right_knee_flexion_deg" in report["frames"][0]["joint_angles_deg"]


def test_rejects_nonuniform_grid_before_any_outputs(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    geo = json.loads(paths["geometry"].read_text())
    mapping = json.loads(paths["map"].read_text())
    for point in geo["points"][-6:]:
        point["reference_time_ns"] += 10000000
    mapping["frames"][-1]["reference_time_ns"] += 10000000
    _write(paths["geometry"], geo)
    mapping["geometry_report_sha256"] = sha256_file(paths["geometry"])
    _write(paths["map"], mapping)
    with pytest.raises(ValueError, match="near-uniform"):
        _run(paths, tmp_path, trc_path=tmp_path / "bad.trc")
    assert not (tmp_path / "bad.trc").exists()
    assert not (tmp_path / "kinematics.json").exists()
    # Explicit irregular timelines can still be preserved as JSON.
    report = _run(paths, tmp_path)
    assert report["frame_count"] == 3


def test_no_input_file_overwrite(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    with pytest.raises(ValueError, match="overwrite immutable"):
        build_personalized_kinematics(
            paths["geometry"],
            paths["rig"],
            paths["world"],
            paths["body"],
            paths["map"],
            paths["geometry"],
        )
