from __future__ import annotations

import json
from pathlib import Path

import pytest

from motionos.kinematic_joint_map import build_kinematic_joint_map
from motionos.provenance import sha256_file


def _write(path: Path, value: dict) -> Path:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    return path


def _fixtures(tmp_path: Path) -> dict[str, Path]:
    correspondence = _write(
        tmp_path / "correspondences.json",
        {
            "schema_version": "motionos.multiview-correspondences.v1",
            "rig_id": "two-camera-rig",
            "rig_receipt_sha256": "e" * 64,
            "frozen_before_geometry_review": True,
            "points": [
                {
                    "point_id": "frame-1-leftHip",
                    "reference_time_ns": 1_000_000_000,
                    "joint_name": "leftHip",
                    "observations": {},
                },
                {
                    "point_id": "frame-1-leftKnee",
                    "reference_time_ns": 1_000_000_000,
                    "joint_name": "leftKnee",
                    "observations": {},
                },
                {
                    "point_id": "frame-2-leftHip",
                    "reference_time_ns": 1_033_333_333,
                    "joint_name": "leftHip",
                    "observations": {},
                },
                {
                    "point_id": "frame-2-unknown",
                    "reference_time_ns": 1_033_333_333,
                    "observations": {},
                },
            ],
        },
    )
    c = json.loads(correspondence.read_text())
    geometry = _write(
        tmp_path / "geometry.json",
        {
            "schema_version": "motionos.multiview-geometry-report.v1",
            "rig_id": c["rig_id"],
            "rig_receipt_sha256": c["rig_receipt_sha256"],
            "correspondences_sha256": sha256_file(correspondence),
            "points": [
                {
                    "point_id": item["point_id"],
                    "reference_time_ns": item["reference_time_ns"],
                    "world_position_m": [0.0, 1.0, 0.0],
                }
                for item in c["points"]
            ],
        },
    )
    return {"geometry": geometry, "correspondences": correspondence}


def _run(paths: dict[str, Path], tmp_path: Path, **kwargs: object) -> dict:
    return build_kinematic_joint_map(
        paths["geometry"],
        paths["correspondences"],
        tmp_path / "map.json",
        subject_id="participant-1",
        **kwargs,
    )


def test_auto_map_from_explicit_labeled_correspondences(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    report = _run(paths, tmp_path)
    assert report["schema_version"] == "motionos.kinematic-joint-map.v1"
    assert report["frame_count"] == 2
    assert report["unlabeled_point_count"] == 1
    assert report["labeled_point_count"] == 3
    assert report["human_reviewed_point_count"] == 0
    assert report["joint_labels_fully_reviewed"] is False
    assert report["frames"][0]["joints"]["leftKnee"] == "frame-1-leftKnee"
    assert report["frames"][0]["joint_label_status"]["leftHip"] == "model_proposed"
    assert report["geometry_report_sha256"] == sha256_file(paths["geometry"])


def test_annotation_review_preserves_proposed_labels(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    annotations = _write(
        tmp_path / "reviewed.json",
        {
            "schema_version": "motionos.kinematic-joint-annotations.v1",
            "geometry_report_sha256": sha256_file(paths["geometry"]),
            "correspondences_sha256": sha256_file(paths["correspondences"]),
            "review_status": "human_reviewed",
            "labels": [
                {"point_id": "frame-1-leftHip", "joint_name": "leftHip"},
                {"point_id": "frame-2-unknown", "joint_name": "leftAnkle"},
            ],
        },
    )
    report = _run(paths, tmp_path, reviewed_annotations_path=annotations)
    assert report["labeled_point_count"] == 4
    assert report["human_reviewed_point_count"] == 2
    assert report["unlabeled_point_count"] == 0
    assert report["joint_labels_fully_reviewed"] is False
    assert report["reviewed_annotations_sha256"] == sha256_file(annotations)
    assert report["frames"][1]["joints"]["leftAnkle"] == "frame-2-unknown"
    assert report["frames"][1]["joint_label_status"]["leftAnkle"] == "human_reviewed"


def test_rejects_stale_correspondence_digest(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    c = json.loads(paths["correspondences"].read_text())
    c["points"][0]["joint_name"] = "rightHip"
    _write(paths["correspondences"], c)
    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        _run(paths, tmp_path)


def test_rejects_duplicate_joint_at_same_time(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    c = json.loads(paths["correspondences"].read_text())
    c["points"][1]["joint_name"] = "leftHip"
    _write(paths["correspondences"], c)
    g = json.loads(paths["geometry"].read_text())
    g["correspondences_sha256"] = sha256_file(paths["correspondences"])
    _write(paths["geometry"], g)
    with pytest.raises(ValueError, match="duplicate leftHip"):
        _run(paths, tmp_path)


def test_rejects_review_conflicting_with_source(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    annotations = _write(
        tmp_path / "reviewed.json",
        {
            "schema_version": "motionos.kinematic-joint-annotations.v1",
            "geometry_report_sha256": sha256_file(paths["geometry"]),
            "correspondences_sha256": sha256_file(paths["correspondences"]),
            "review_status": "human_reviewed",
            "labels": [{"point_id": "frame-1-leftHip", "joint_name": "rightHip"}],
        },
    )
    with pytest.raises(ValueError, match="conflicts with original"):
        _run(paths, tmp_path, reviewed_annotations_path=annotations)


def test_rejects_unfrozen_correspondences(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    c = json.loads(paths["correspondences"].read_text())
    c["frozen_before_geometry_review"] = False
    _write(paths["correspondences"], c)
    g = json.loads(paths["geometry"].read_text())
    g["correspondences_sha256"] = sha256_file(paths["correspondences"])
    _write(paths["geometry"], g)
    with pytest.raises(ValueError, match="frozen"):
        _run(paths, tmp_path)


def test_rejects_same_destination_as_source(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    with pytest.raises(ValueError, match="must not overwrite"):
        build_kinematic_joint_map(
            paths["geometry"],
            paths["correspondences"],
            paths["geometry"],
            subject_id="participant-1",
        )


def test_rejects_uncurated_joint_name(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    c = json.loads(paths["correspondences"].read_text())
    c["points"][0]["joint_name"] = "fabricatedMuscleActivation"
    _write(paths["correspondences"], c)
    g = json.loads(paths["geometry"].read_text())
    g["correspondences_sha256"] = sha256_file(paths["correspondences"])
    _write(paths["geometry"], g)
    with pytest.raises(ValueError, match="supported anatomical joint"):
        _run(paths, tmp_path)


def test_no_label_raises_without_writing(tmp_path: Path) -> None:
    paths = _fixtures(tmp_path)
    c = json.loads(paths["correspondences"].read_text())
    for entry in c["points"]:
        entry.pop("joint_name", None)
    _write(paths["correspondences"], c)
    g = json.loads(paths["geometry"].read_text())
    g["correspondences_sha256"] = sha256_file(paths["correspondences"])
    _write(paths["geometry"], g)
    with pytest.raises(ValueError, match="no joint labels"):
        _run(paths, tmp_path)
    assert not (tmp_path / "map.json").exists()
