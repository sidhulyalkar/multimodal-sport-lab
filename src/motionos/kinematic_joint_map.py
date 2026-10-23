"""Build an auditable joint timeline from named multiview observations.

Never infer joint identity from point IDs or filenames. The original
correspondence file is hash-verified against the triangulation report;
an optional reviewed annotation file may confirm or supply joint names.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from typing import Any

from .personalized_kinematics import JOINT_MAP_SCHEMA
from .provenance import sha256_file
from .world_geometry import (
    MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION,
    MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION,
)

JOINT_ANNOTATIONS_SCHEMA = "motionos.kinematic-joint-annotations.v1"
ALLOWED_JOINTS = frozenset(
    {
        "root",
        "head",
        "neck",
        "leftShoulder",
        "rightShoulder",
        "leftElbow",
        "rightElbow",
        "leftWrist",
        "rightWrist",
        "leftHip",
        "rightHip",
        "leftKnee",
        "rightKnee",
        "leftAnkle",
        "rightAnkle",
        "leftHeel",
        "rightHeel",
        "leftFoot",
        "rightFoot",
        "leftToe",
        "rightToe",
    }
)


def _load(path: Path, *, label: str) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must be a JSON object")
    return raw


def _point_index(
    points: object,
    *,
    label: str,
) -> dict[str, dict[str, Any]]:
    if not isinstance(points, list) or not points:
        raise ValueError(f"{label}.points must be a nonempty list")
    index: dict[str, dict[str, Any]] = {}
    for item in points:
        if not isinstance(item, dict):
            raise TypeError(f"{label} point must be a JSON object")
        pid = item.get("point_id")
        time = item.get("reference_time_ns")
        if not isinstance(pid, str) or not pid:
            raise ValueError(f"{label} point ID must be nonempty")
        if isinstance(time, bool) or not isinstance(time, int) or time < 0:
            raise ValueError(f"{label} point {pid} needs a non-negative integer time")
        if pid in index:
            raise ValueError(f"{label} has duplicate point ID {pid}")
        index[pid] = item
    return index


def _joint(value: object, *, label: str) -> str:
    if not isinstance(value, str) or value not in ALLOWED_JOINTS:
        raise ValueError(
            f"{label} is not a supported anatomical joint: {value!r}"
        )
    return value


def build_kinematic_joint_map(
    geometry_report_path: str | Path,
    correspondences_path: str | Path,
    output_path: str | Path,
    *,
    subject_id: str,
    reviewed_annotations_path: str | Path | None = None,
) -> dict[str, Any]:
    """Create an exact-time joint index, preserving proposed versus reviewed status.

    A proposed label is usable for exploration but not proof of anatomical
    correspondence. Human review is recorded as a declared provenance status,
    not independently verified by this tool.
    """
    geo_path = Path(geometry_report_path).resolve()
    corr_path = Path(correspondences_path).resolve()
    dest = Path(output_path).resolve()
    annotation_path = (
        Path(reviewed_annotations_path).resolve()
        if reviewed_annotations_path is not None
        else None
    )
    inputs = {geo_path, corr_path}
    if annotation_path is not None:
        inputs.add(annotation_path)
    if dest in inputs:
        raise ValueError("joint map output must not overwrite source evidence")
    if not isinstance(subject_id, str) or not subject_id.strip():
        raise ValueError("subject_id must be a nonempty pseudonymous value")
    if len(subject_id) > 128:
        raise ValueError("subject_id is too long")

    geo = _load(geo_path, label="multiview geometry report")
    corr = _load(corr_path, label="multiview correspondences")
    if geo.get("schema_version") != MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION:
        raise ValueError("unsupported multiview geometry report schema")
    if corr.get("schema_version") != MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION:
        raise ValueError("unsupported multiview correspondences schema")
    corr_sha = sha256_file(corr_path)
    geo_sha = sha256_file(geo_path)
    if geo.get("correspondences_sha256") != corr_sha:
        raise ValueError("geometry report correspondences SHA-256 mismatch")
    if geo.get("rig_id") != corr.get("rig_id"):
        raise ValueError("correspondences rig_id mismatch")
    if geo.get("rig_receipt_sha256") != corr.get("rig_receipt_sha256"):
        raise ValueError("correspondences rig receipt hash mismatch")
    if corr.get("frozen_before_geometry_review") is not True:
        raise ValueError("correspondences must be frozen before geometry review")

    geometric = _point_index(geo.get("points"), label="geometry")
    source = _point_index(corr.get("points"), label="correspondences")
    if set(geometric) != set(source):
        raise ValueError("geometry and correspondences must contain identical point IDs")
    for pid, item in source.items():
        if item["reference_time_ns"] != geometric[pid]["reference_time_ns"]:
            raise ValueError(f"source and geometry timestamp disagree for point {pid}")

    joint_by_point: dict[str, str] = {}
    reviewed_by_point: set[str] = set()
    # Source-side detector labels remain merely proposed, even if they happen
    # to match the athlete's body model vocabulary.
    for pid, point in source.items():
        if "joint_name" in point:
            joint_by_point[pid] = _joint(
                point["joint_name"], label=f"correspondences {pid}.joint_name"
            )

    annotations_sha: str | None = None
    if annotation_path is not None:
        annotations = _load(annotation_path, label="reviewed joint annotations")
        if annotations.get("schema_version") != JOINT_ANNOTATIONS_SCHEMA:
            raise ValueError("unsupported joint annotations schema")
        if annotations.get("geometry_report_sha256") != geo_sha:
            raise ValueError("joint annotations geometry report hash mismatch")
        if annotations.get("correspondences_sha256") != corr_sha:
            raise ValueError("joint annotations correspondences hash mismatch")
        if annotations.get("review_status") != "human_reviewed":
            raise ValueError("joint annotations must explicitly declare human_reviewed")
        entries = annotations.get("labels")
        if not isinstance(entries, list) or not entries:
            raise ValueError("joint annotations must contain reviewed labels")
        for item in entries:
            if not isinstance(item, dict):
                raise TypeError("reviewed joint annotation entries must be objects")
            pid = item.get("point_id")
            if not isinstance(pid, str) or pid not in source:
                raise ValueError(f"reviewed label references an unknown point: {pid!r}")
            if pid in reviewed_by_point:
                raise ValueError(f"duplicate human review for point {pid}")
            value = _joint(item.get("joint_name"), label=f"reviewed point {pid}")
            if pid in joint_by_point and joint_by_point[pid] != value:
                raise ValueError(
                    f"human review conflicts with original joint label for {pid}; "
                    "revise upstream evidence instead of silently relabeling it"
                )
            joint_by_point[pid] = value
            reviewed_by_point.add(pid)
        annotations_sha = sha256_file(annotation_path)

    grouped: dict[int, dict[str, str]] = defaultdict(dict)
    review_by_frame: dict[int, dict[str, str]] = defaultdict(dict)
    for pid, joint in joint_by_point.items():
        time_ns = geometric[pid]["reference_time_ns"]
        if joint in grouped[time_ns]:
            raise ValueError(
                f"duplicate {joint} assignment at time {time_ns}; "
                "person association is ambiguous"
            )
        grouped[time_ns][joint] = pid
        review_by_frame[time_ns][joint] = (
            "human_reviewed" if pid in reviewed_by_point else "model_proposed"
        )
    if not grouped:
        raise ValueError(
            "no joint labels supplied: add joint_name to the frozen correspondences "
            "or provide a reviewed annotations file"
        )

    frames = [
        {
            "reference_time_ns": time_ns,
            "joints": dict(sorted(grouped[time_ns].items())),
            "joint_label_status": dict(sorted(review_by_frame[time_ns].items())),
        }
        for time_ns in sorted(grouped)
    ]
    output = {
        "schema_version": JOINT_MAP_SCHEMA,
        "subject_id": subject_id.strip(),
        "geometry_report_sha256": geo_sha,
        "source_correspondences_sha256": corr_sha,
        "reviewed_annotations_sha256": annotations_sha,
        "frame_count": len(frames),
        "labeled_point_count": len(joint_by_point),
        "unlabeled_point_count": len(source) - len(joint_by_point),
        "human_reviewed_point_count": len(reviewed_by_point),
        "joint_labels_fully_reviewed": len(reviewed_by_point) == len(joint_by_point),
        "frames": frames,
        "claim_boundary": (
            "Anatomical joint labels are inferred or user-reviewed associations, "
            "not anatomically validated joint centers. This manifest is "
            "hash-bound to exact source correspondences and triangulation output."
        ),
    }
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output
