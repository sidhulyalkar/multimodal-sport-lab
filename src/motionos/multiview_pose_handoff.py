"""Deterministic, evidence-bound 2D pose to multiview correspondence adapter.

This stage associates already identified single-person, per-camera poses. It
does not recover missing source-frame numbers, perform person re-identification,
calibrate lenses, triangulate 3D points, or invent interpolated observations.
"""
from __future__ import annotations

import json
import math
from bisect import bisect_left
from collections import Counter
from pathlib import Path
from typing import Any

from .kinematic_joint_map import ALLOWED_JOINTS
from .provenance import sha256_file
from .world_geometry import (
    CAMERA_RIG_RECEIPT_SCHEMA_VERSION,
    MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION,
    _clock_model_from_dict,
)

SPEC_SCHEMA = "motionos.multiview-pose-handoff-spec.v1"
TRACK_SCHEMA = "motionos.camera-pose-observations.v1"
AUDIT_SCHEMA = "motionos.multiview-pose-handoff-audit.v1"
NORMALIZED_LOWER_LEFT = "source_image_normalized_origin_lower_left_after_orientation"
PIXEL_UPPER_LEFT = "source_image_pixels_origin_upper_left_after_orientation"


def _object(path: Path, label: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError(f"{label} must be a JSON object")
    return data


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a nonempty string")
    return value.strip()


def _number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{label} must be finite")
    return result


def _nonnegative_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a nonnegative integer")
    return value


def _read_bound(
    reference: object, *, base: Path, label: str,
) -> tuple[Path, str, dict[str, Any]]:
    if not isinstance(reference, dict):
        raise TypeError(f"{label} reference must be an object")
    requested = _text(reference.get("path"), f"{label}.path")
    path = (base / requested).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{label} is missing: {path}")
    expected = _text(reference.get("sha256"), f"{label}.sha256").lower()
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ValueError(f"{label} requires a valid SHA-256")
    actual = sha256_file(path)
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch")
    return path, actual, _object(path, label)


def _read_media(
    reference: object, *, base: Path, label: str,
) -> tuple[Path, str]:
    if not isinstance(reference, dict):
        raise TypeError(f"{label} must be an object")
    path = (base / _text(reference.get("path"), f"{label}.path")).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{label} is missing: {path}")
    digest = _text(reference.get("sha256"), f"{label}.sha256").lower()
    if sha256_file(path) != digest:
        raise ValueError(f"{label} SHA-256 mismatch")
    return path, digest


def _read_track(
    data: dict[str, Any], *, camera: dict[str, Any], subject_id: str,
    media_sha256: str, clock: Any, minimum_confidence: float,
) -> list[dict[str, Any]]:
    cid = _text(camera.get("camera_id"), "rig camera id")
    if data.get("schema_version") != TRACK_SCHEMA:
        raise ValueError(f"{cid} requires {TRACK_SCHEMA} input")
    if data.get("camera_id") != cid or data.get("session_id") != camera.get("session_id"):
        raise ValueError(f"{cid} camera/session mismatch")
    if data.get("session_bundle_sha256") != camera.get("session_bundle_sha256"):
        raise ValueError(f"{cid} session bundle hash mismatch")
    if data.get("source_video_sha256") != media_sha256:
        raise ValueError(f"{cid} source video hash mismatch")
    if data.get("subject_id") != subject_id:
        raise ValueError(f"{cid} participant identity mismatch")
    calibration = camera.get("calibration")
    if not isinstance(calibration, dict):
        raise TypeError(f"{cid} rig calibration is missing")
    dims = calibration.get("image_size_px")
    if (
        not isinstance(dims, list) or len(dims) != 2
        or any(isinstance(x, bool) or not isinstance(x, int) or x <= 1 for x in dims)
    ):
        raise ValueError(f"{cid} requires calibrated image dimensions")
    if data.get("image_size_px") != dims:
        raise ValueError(f"{cid} pose image dimensions differ from calibrated pixels")
    mode = data.get("coordinate_frame")
    if mode not in (NORMALIZED_LOWER_LEFT, PIXEL_UPPER_LEFT):
        raise ValueError(f"{cid} requires an explicit supported oriented image coordinate frame")
    raw_frames = data.get("frames")
    if not isinstance(raw_frames, list) or not raw_frames:
        raise ValueError(f"{cid} requires nonempty pose frames")

    parsed: list[dict[str, Any]] = []
    previous_pts = -1
    previous_sequence = -1
    for index, raw in enumerate(raw_frames):
        if not isinstance(raw, dict):
            raise TypeError(f"{cid} frame {index} must be an object")
        sequence = _nonnegative_int(raw.get("source_frame_sequence"), "source_frame_sequence")
        pts = _nonnegative_int(raw.get("source_frame_pts_ns"), "source_frame_pts_ns")
        if pts <= previous_pts or sequence <= previous_sequence:
            raise ValueError(f"{cid} duplicate or non-monotonic source frames")
        previous_pts = pts
        previous_sequence = sequence
        if raw.get("subject_id") != subject_id:
            raise ValueError(f"{cid} frame {index} contains an unverified or different person")
        joints = raw.get("joints")
        if not isinstance(joints, list):
            raise TypeError(f"{cid} frame {index} joints must be a list")
        points: dict[str, tuple[float, float, float]] = {}
        seen_joint_ids: set[str] = set()
        for entry in joints:
            if not isinstance(entry, dict):
                raise TypeError(f"{cid} joint must be an object")
            name = _text(entry.get("id"), "joint id")
            if name not in ALLOWED_JOINTS:
                raise ValueError(f"{cid} unsupported joint name {name}")
            if name in seen_joint_ids:
                raise ValueError(f"{cid} duplicate joint {name} in frame {index}")
            seen_joint_ids.add(name)
            confidence = _number(entry.get("confidence"), f"{cid}.{name}.confidence")
            if not 0 <= confidence <= 1:
                raise ValueError(f"{cid} joint confidence outside 0..1")
            x = _number(entry.get("x"), f"{cid}.{name}.x")
            y = _number(entry.get("y"), f"{cid}.{name}.y")
            if mode == NORMALIZED_LOWER_LEFT:
                if not (0 <= x <= 1 and 0 <= y <= 1):
                    raise ValueError(f"{cid} normalized joint is outside image")
                u, v = x * (dims[0] - 1), (1.0 - y) * (dims[1] - 1)
            else:
                if not (0 <= x < dims[0] and 0 <= y < dims[1]):
                    raise ValueError(f"{cid} pixel joint is outside calibrated image")
                u, v = x, y
            if confidence >= minimum_confidence:
                points[name] = (u, v, confidence)
        mapped_time = clock.map(pts) if clock.outside_support_ns(pts) == 0 else None
        uncertainty = (
            clock.predictive_std_ns(pts) if mapped_time is not None else None
        )
        parsed.append({
            "sequence": sequence,
            "pts": pts,
            "mapped_ns": mapped_time,
            "predictive_std_ns": uncertainty,
            "joints": points,
        })
    return parsed


def build_multiview_pose_correspondences(
    spec_path: str | Path,
    output_path: str | Path,
    *,
    audit_path: str | Path | None = None,
) -> dict[str, Any]:
    """Create frozen per-joint observations for MotionOS metric triangulation."""
    spec_file = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    audit = Path(audit_path).resolve() if audit_path is not None else None
    spec = _object(spec_file, "pose handoff spec")
    if spec.get("schema_version") != SPEC_SCHEMA:
        raise ValueError("unsupported multiview pose handoff spec")
    subject_id = _text(spec.get("subject_id"), "subject_id")
    anchor_id = _text(spec.get("anchor_camera_id"), "anchor_camera_id")
    if spec.get("operator_confirmed_single_person_identity") is not True:
        raise ValueError("cross-camera single-person identity requires operator confirmation")
    confidence = _number(spec.get("min_joint_confidence"), "min_joint_confidence")
    if not 0 < confidence <= 1:
        raise ValueError("min_joint_confidence must be within (0,1]")
    minimum_points = _nonnegative_int(spec.get("min_matched_points"), "min_matched_points")
    if minimum_points < 1:
        raise ValueError("min_matched_points must be at least one")
    minimum_fraction = _number(spec.get("min_matched_anchor_fraction"), "min_matched_anchor_fraction")
    if not 0 < minimum_fraction <= 1:
        raise ValueError("min_matched_anchor_fraction must be within (0,1]")
    base = spec_file.parent

    rig_path, rig_hash, rig = _read_bound(spec.get("rig_receipt"), base=base, label="rig")
    if rig.get("schema_version") != CAMERA_RIG_RECEIPT_SCHEMA_VERSION:
        raise ValueError("invalid camera rig receipt schema")
    if rig.get("passed") is not True:
        raise ValueError("a passing calibrated camera rig is required")
    thresholds = rig.get("thresholds")
    if not isinstance(thresholds, dict):
        raise TypeError("rig thresholds missing")
    max_time_delta_ns = _number(
        thresholds.get("max_correspondence_time_delta_ms"), "rig time tolerance"
    ) * 1e6
    if max_time_delta_ns <= 0:
        raise ValueError("rig time tolerance must be positive")
    cameras = rig.get("cameras")
    if not isinstance(cameras, list) or len(cameras) < 2:
        raise ValueError("rig requires two or more cameras")
    entries = spec.get("camera_tracks")
    if not isinstance(entries, list) or len(entries) != len(cameras):
        raise ValueError("exactly one track must be provided per rig camera")
    by_camera = {camera.get("camera_id"): camera for camera in cameras if isinstance(camera, dict)}
    if len(by_camera) != len(cameras) or anchor_id not in by_camera:
        raise ValueError("rig camera identifiers are ambiguous or anchor is missing")

    input_paths = {spec_file, rig_path}
    tracks: dict[str, list[dict[str, Any]]] = {}
    track_hashes: dict[str, str] = {}
    media_hashes: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise TypeError("camera track entries must be objects")
        cid = _text(entry.get("camera_id"), "camera_tracks.camera_id")
        if cid not in by_camera or cid in tracks:
            raise ValueError(f"unknown or repeated pose camera {cid}")
        track_path, track_hash, data = _read_bound(
            entry.get("track"), base=base, label=f"{cid}.track"
        )
        media_path, media_hash = _read_media(
            entry.get("original_video"), base=base, label=f"{cid}.original_video"
        )
        if track_path == media_path or track_path in input_paths or media_path in input_paths:
            raise ValueError("source artifacts may not alias each other")
        input_paths.update((track_path, media_path))
        rig_cam = by_camera[cid]
        clock_data = rig_cam.get("clock_uncertainty")
        if not isinstance(clock_data, dict):
            raise TypeError(f"{cid} missing calibrated clock model")
        clock = _clock_model_from_dict(
            clock_data.get("weighted_affine"), label=f"{cid}.weighted_affine"
        )
        tracks[cid] = _read_track(
            data, camera=rig_cam, subject_id=subject_id,
            media_sha256=media_hash, clock=clock, minimum_confidence=confidence,
        )
        track_hashes[cid] = track_hash
        media_hashes[cid] = media_hash
    if set(tracks) != set(by_camera):
        raise ValueError("tracks must exactly match rig cameras")
    if output in input_paths or audit in input_paths or (audit is not None and audit == output):
        raise ValueError("outputs must not overwrite immutable input sources")

    other_ids = sorted(cid for cid in tracks if cid != anchor_id)
    valid_other = {}
    for cid in other_ids:
        candidates = [
            f for f in tracks[cid]
            if f["mapped_ns"] is not None and 3 * f["predictive_std_ns"] <= max_time_delta_ns
        ]
        valid_other[cid] = sorted(candidates, key=lambda f: f["mapped_ns"])
    available_times = {
        cid: [f["mapped_ns"] for f in valid_other[cid]]
        for cid in other_ids
    }
    used_sequences: dict[str, set[int]] = {cid: set() for cid in other_ids}
    rejected: Counter[str] = Counter()
    points: list[dict[str, Any]] = []
    qualifying_anchor_frames = 0
    for anchor in tracks[anchor_id]:
        if anchor["mapped_ns"] is None:
            rejected["anchor_outside_clock_support"] += 1
            continue
        if 3 * anchor["predictive_std_ns"] > max_time_delta_ns:
            rejected["anchor_clock_uncertainty"] += 1
            continue
        qualifying_anchor_frames += 1
        # Match full frames, never interpolate a 2D joint across an occlusion.
        matched: dict[str, dict[str, Any]] = {anchor_id: anchor}
        for cid in other_ids:
            times = available_times[cid]
            pos = bisect_left(times, anchor["mapped_ns"])
            neighbours = [valid_other[cid][idx] for idx in (pos - 1, pos) if 0 <= idx < len(times)]
            neighbours = [
                frame for frame in neighbours
                if frame["sequence"] not in used_sequences[cid]
                and abs(frame["mapped_ns"] - anchor["mapped_ns"]) <= max_time_delta_ns
            ]
            if not neighbours:
                rejected["no_synchronized_frame"] += 1
                continue
            neighbours.sort(key=lambda f: (abs(f["mapped_ns"] - anchor["mapped_ns"]), f["pts"]))
            if (
                len(neighbours) > 1
                and abs(neighbours[0]["mapped_ns"] - anchor["mapped_ns"])
                == abs(neighbours[1]["mapped_ns"] - anchor["mapped_ns"])
            ):
                rejected["ambiguous_nearest_frame"] += 1
                continue
            selected = neighbours[0]
            used_sequences[cid].add(selected["sequence"])
            matched[cid] = selected

        for joint in sorted(anchor["joints"]):
            observations: dict[str, dict[str, int | float]] = {}
            for cid, frame in matched.items():
                if joint not in frame["joints"]:
                    continue
                u, v, _confidence = frame["joints"][joint]
                observations[cid] = {
                    "u_px": round(u, 6), "v_px": round(v, 6),
                    "source_frame_sequence": frame["sequence"],
                    "source_frame_pts_ns": frame["pts"],
                }
            if len(observations) < 2:
                rejected["joint_not_multiview_visible"] += 1
                continue
            time_ns = anchor["mapped_ns"]
            points.append({
                "point_id": f"{time_ns}:{joint}",
                "joint_name": joint,
                "reference_time_ns": time_ns,
                "observations": dict(sorted(observations.items())),
            })
    # A missing/unsupported anchor frame is missing coverage, not a reason to
    # shrink the denominator and make a weak study appear complete.
    denominator = len(tracks[anchor_id])
    matched_anchor_frames = len({p["reference_time_ns"] for p in points})
    coverage = matched_anchor_frames / denominator
    if len(points) < minimum_points or coverage < minimum_fraction:
        raise ValueError(
            f"insufficient time-matched multiview pose evidence: "
            f"{len(points)} points; anchor coverage {coverage:.3f}"
        )
    correspondence: dict[str, Any] = {
        "schema_version": MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION,
        "rig_id": rig["rig_id"],
        "rig_receipt_sha256": rig_hash,
        "frozen_before_geometry_review": True,
        "points": points,
        "source_pose_tracks_sha256": dict(sorted(track_hashes.items())),
        "source_videos_sha256": dict(sorted(media_hashes.items())),
        "operator_confirmed_single_person_identity": True,
        "min_joint_confidence": confidence,
        "claim_boundary": (
            "Source-timed, confidence-filtered named image points; the operator "
            "confirmed cross-view person identity. MotionOS did not perform "
            "person reidentification, joint interpolation or camera calibration. "
            "These are model-estimated 2D landmarks, not 3D anatomy or measured force."
        ),
    }
    audit_report = {
        "schema_version": AUDIT_SCHEMA,
        "spec_sha256": sha256_file(spec_file),
        "rig_receipt_sha256": rig_hash,
        "subject_id": subject_id,
        "anchor_camera_id": anchor_id,
        "source_pose_tracks_sha256": dict(sorted(track_hashes.items())),
        "source_videos_sha256": dict(sorted(media_hashes.items())),
        "input_anchor_frames": len(tracks[anchor_id]),
        "clock_qualified_anchor_frames": qualifying_anchor_frames,
        "matched_anchor_frames": matched_anchor_frames,
        "matched_anchor_fraction": round(coverage, 6),
        "point_count": len(points),
        "reason_counts": dict(sorted(rejected.items())),
        "frozen_before_geometry_review": True,
        "claim_boundary": correspondence["claim_boundary"],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    if audit is not None:
        audit.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(correspondence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if audit is not None:
        audit.write_text(json.dumps(audit_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return audit_report
