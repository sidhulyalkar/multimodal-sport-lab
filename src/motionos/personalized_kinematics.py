"""Evidence-bound 3D marker timeline and OpenSim TRC handoff.

This module does not fit an OpenSim model, estimate forces, or invent missing
geometry. It promotes only audited metric multiview points into a kinematics
exchange format; biomechanical inference requires a separate validated stage.
"""

from __future__ import annotations

import hashlib
import json
import math
import statistics
from pathlib import Path
from typing import Any

from .body_model import (
    DEFAULT_FRAME_CONVENTION,
    load_body_model_profile,
    verify_body_model_source_artifact,
)
from .provenance import sha256_file
from .world_geometry import (
    CAMERA_RIG_RECEIPT_SCHEMA_VERSION,
    MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION,
    WORLD_FRAME_SCHEMA_VERSION,
)

JOINT_MAP_SCHEMA = "motionos.kinematic-joint-map.v1"
KINEMATICS_SCHEMA = "motionos.personalized-kinematics.v1"

# A standardized marker vocabulary keeps anatomical left and right independent.
SEGMENTS: dict[str, tuple[str, str]] = {
    "left_femur": ("leftHip", "leftKnee"),
    "right_femur": ("rightHip", "rightKnee"),
    "left_tibia": ("leftKnee", "leftAnkle"),
    "right_tibia": ("rightKnee", "rightAnkle"),
    "left_upper_arm": ("leftShoulder", "leftElbow"),
    "right_upper_arm": ("rightShoulder", "rightElbow"),
    "left_forearm": ("leftElbow", "leftWrist"),
    "right_forearm": ("rightElbow", "rightWrist"),
}
KNEES = {
    "left_knee_flexion_deg": ("leftHip", "leftKnee", "leftAnkle", "left"),
    "right_knee_flexion_deg": ("rightHip", "rightKnee", "rightAnkle", "right"),
}


def _object(path: Path, what: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{what} must be a JSON object")
    return data


def _nonnegative_int(value: object, what: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{what} must be a non-negative integer")
    return value


def _positive(value: object, what: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{what} must be a positive finite number")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{what} must be a positive finite number") from exc
    if not math.isfinite(number) or number <= 0:
        raise ValueError(f"{what} must be a positive finite number")
    return number


def _point(value: object, what: str) -> tuple[float, float, float]:
    if not isinstance(value, list) or len(value) != 3:
        raise ValueError(f"{what} must be a three-element array")
    if any(isinstance(item, bool) for item in value):
        raise ValueError(f"{what} must contain finite coordinates")
    try:
        result = tuple(float(item) for item in value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{what} must contain numeric coordinates") from exc
    if not all(math.isfinite(item) for item in result):
        raise ValueError(f"{what} must contain finite coordinates")
    return result  # type: ignore[return-value]


def _distance(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def _knee_flexion(
    hip: tuple[float, ...],
    knee: tuple[float, ...],
    ankle: tuple[float, ...],
) -> float | None:
    a = tuple(x - y for x, y in zip(hip, knee))
    b = tuple(x - y for x, y in zip(ankle, knee))
    na = math.sqrt(sum(v * v for v in a))
    nb = math.sqrt(sum(v * v for v in b))
    if na <= 1e-9 or nb <= 1e-9:
        return None
    cosine = sum(x * y for x, y in zip(a, b)) / (na * nb)
    return round(180.0 - math.degrees(math.acos(max(-1.0, min(1.0, cosine)))), 5)


def _trc(
    frames: list[dict[str, Any]], marker_names: list[str], name: str
) -> bytes:
    if len(frames) < 2:
        raise ValueError("TRC export requires two or more frames")
    seconds = [frame["time_s"] for frame in frames]
    deltas = [b - a for a, b in zip(seconds, seconds[1:])]
    median_dt = statistics.median(deltas)
    if median_dt <= 0 or any(abs(dt - median_dt) > 0.02 * median_dt for dt in deltas):
        raise ValueError(
            "TRC requires a near-uniform capture grid; no interpolation or synthetic frames "
            "will be silently introduced. Export the JSON timeline instead."
        )
    rate = 1.0 / median_dt
    count = len(frames)
    columns = ["Frame#", "Time"]
    for joint in marker_names:
        columns.extend([joint, "", ""])
    axes = ["", ""]
    for index, _ in enumerate(marker_names, start=1):
        axes.extend([f"X{index}", f"Y{index}", f"Z{index}"])
    lines = [
        f"PathFileType\t4\t(X/Y/Z)\t{name}",
        "DataRate\tCameraRate\tNumFrames\tNumMarkers\tUnits\t"
        "OrigDataRate\tOrigDataStartFrame\tOrigNumFrames",
        f"{rate:.8f}\t{rate:.8f}\t{count}\t{len(marker_names)}\tm\t"
        f"{rate:.8f}\t1\t{count}",
        "\t".join(columns),
        "\t".join(axes),
        "",
    ]
    for number, frame in enumerate(frames, start=1):
        fields = [str(number), f'{frame["time_s"]:.9f}']
        markers = frame["markers_world_m"]
        for joint in marker_names:
            point = markers.get(joint)
            fields.extend([f"{v:.9f}" for v in point] if point is not None else ["", "", ""])
        lines.append("\t".join(fields))
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_personalized_kinematics(
    geometry_report_path: str | Path,
    rig_receipt_path: str | Path,
    world_frame_path: str | Path,
    body_profile_path: str | Path,
    joint_map_path: str | Path,
    output_path: str | Path,
    *,
    trc_path: str | Path | None = None,
    body_source_artifact_path: str | Path | None = None,
    max_reprojection_px: float = 8.0,
    max_ray_disagreement_m: float = 0.04,
    max_segment_deviation_fraction: float = 0.25,
    max_contiguous_gap_s: float = 0.15,
) -> dict[str, Any]:
    """Join a passing multiview report to a personal profile without per-frame refits.

    The output is derived motion *kinematics*, not inverse dynamics or muscle
    activation. A passing rig only qualifies internal geometry consistency.
    """
    reproj_limit = _positive(max_reprojection_px, "max_reprojection_px")
    ray_limit = _positive(max_ray_disagreement_m, "max_ray_disagreement_m")
    segment_limit = _positive(max_segment_deviation_fraction, "max_segment_deviation_fraction")
    gap_limit = _positive(max_contiguous_gap_s, "max_contiguous_gap_s")

    geometry_path, rig_path, world_path, profile_path, map_path, output = (
        Path(p).resolve()
        for p in (
            geometry_report_path, rig_receipt_path, world_frame_path,
            body_profile_path, joint_map_path, output_path,
        )
    )
    inputs = [geometry_path, rig_path, world_path, profile_path, map_path]
    if body_source_artifact_path is not None:
        inputs.append(Path(body_source_artifact_path).resolve())
    trc_output = Path(trc_path).resolve() if trc_path is not None else None
    if output in inputs or (trc_output is not None and (trc_output in inputs or trc_output == output)):
        raise ValueError("output files may not overwrite immutable input evidence")

    geo = _object(geometry_path, "multiview geometry report")
    rig = _object(rig_path, "camera rig")
    world = _object(world_path, "world frame")
    mapping = _object(map_path, "joint map")
    profile = load_body_model_profile(profile_path)

    if geo.get("schema_version") != MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION:
        raise ValueError("expected a MotionOS multiview geometry report")
    if rig.get("schema_version") != CAMERA_RIG_RECEIPT_SCHEMA_VERSION or rig.get("passed") is not True:
        raise ValueError("personalized metric kinematics requires a passing camera rig receipt")
    if world.get("schema_version") != WORLD_FRAME_SCHEMA_VERSION or world.get("units") != "m":
        raise ValueError("world frame must declare MotionOS metric coordinates")
    if sha256_file(rig_path) != geo.get("rig_receipt_sha256"):
        raise ValueError("geometry report camera rig hash mismatch")
    if sha256_file(world_path) != rig.get("world_frame_sha256"):
        raise ValueError("rig receipt world frame hash mismatch")
    if sha256_file(world_path) != geo.get("world_frame_sha256"):
        raise ValueError("geometry report world frame hash mismatch")
    if geo.get("rig_id") != rig.get("rig_id"):
        raise ValueError("geometry report rig identity mismatch")
    if profile.frame_convention != DEFAULT_FRAME_CONVENTION:
        raise ValueError("body frame axes require an explicit transform before this adapter can run")
    axes = world.get("axes")
    gravity = _point(world.get("gravity_direction"), "world gravity direction")
    if (
        not isinstance(axes, dict)
        or "up" not in str(axes.get("y", "")).lower()
        or _distance(gravity, (0.0, -1.0, 0.0)) > 1e-3
    ):
        raise ValueError("TRC adapter requires +Y up and gravity along -Y")
    if mapping.get("schema_version") != JOINT_MAP_SCHEMA:
        raise ValueError("unsupported kinematic joint-map schema")
    if mapping.get("geometry_report_sha256") != sha256_file(geometry_path):
        raise ValueError("joint map geometry hash mismatch")
    if not isinstance(mapping.get("subject_id"), str) or not mapping["subject_id"].strip():
        raise ValueError("joint map requires a pseudonymous subject_id")

    source_hash = profile.source.artifact_sha256
    if source_hash is not None:
        if body_source_artifact_path is None:
            raise ValueError("the declared body scan/source must be supplied for hash verification")
        verify_body_model_source_artifact(profile, body_source_artifact_path)
    elif body_source_artifact_path is not None:
        raise ValueError("body profile has no source hash to verify")
    personalized_qualified = source_hash is not None and profile.source.type != "example_only"

    points_raw = geo.get("points")
    if not isinstance(points_raw, list) or not points_raw:
        raise ValueError("geometry report has no points")
    point_index: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(points_raw):
        if not isinstance(raw, dict) or not isinstance(raw.get("point_id"), str):
            raise ValueError(f"invalid geometry point at index {index}")
        name = raw["point_id"]
        if not name or name in point_index:
            raise ValueError("geometry point IDs must be unique and nonempty")
        point_index[name] = raw

    frames_raw = mapping.get("frames")
    if not isinstance(frames_raw, list) or not frames_raw:
        raise ValueError("joint map must contain at least one frame")
    output_frames: list[dict[str, Any]] = []
    all_joint_names: set[str] = set()
    used_point_ids: set[str] = set()
    prev_ns: int | None = None
    start_ns: int | None = None
    gaps: list[dict[str, Any]] = []
    rejected = 0
    for frame_index, raw in enumerate(frames_raw):
        if not isinstance(raw, dict):
            raise ValueError("joint-map frames must be objects")
        time_ns = _nonnegative_int(raw.get("reference_time_ns"), "reference_time_ns")
        if prev_ns is not None and time_ns <= prev_ns:
            raise ValueError("joint-map reference timestamps must strictly increase")
        if start_ns is None:
            start_ns = time_ns
        if prev_ns is not None and (time_ns - prev_ns) / 1e9 > gap_limit:
            gaps.append({
                "before_frame_index": frame_index,
                "delta_s": round((time_ns - prev_ns) / 1e9, 9),
            })
        prev_ns = time_ns
        joints = raw.get("joints")
        if not isinstance(joints, dict) or not joints:
            raise ValueError(f"frame {frame_index} requires a nonempty joint mapping")
        accepted: dict[str, tuple[float, float, float]] = {}
        rejected_joints: dict[str, str] = {}
        observation_refs: dict[str, str] = {}
        for joint, point_id in joints.items():
            if not isinstance(joint, str) or not joint or not isinstance(point_id, str):
                raise ValueError("joint map requires string joint names and point IDs")
            if point_id in used_point_ids:
                raise ValueError(f"geometry point {point_id} is reused across joint mappings")
            used_point_ids.add(point_id)
            if point_id not in point_index:
                raise ValueError(f"joint {joint} references missing geometry point {point_id}")
            point_data = point_index[point_id]
            if _nonnegative_int(point_data.get("reference_time_ns"), "point time") != time_ns:
                raise ValueError(f"joint {joint} source timestamp does not match frame")
            xyz = _point(point_data.get("world_position_m"), f"{point_id}.world_position_m")
            reprojection = _positive(
                point_data.get("mean_reprojection_residual_px", 0.0) + 1e-15,
                f"{point_id}.mean_reprojection_residual_px",
            ) - 1e-15
            disagreement = _positive(
                point_data.get("ray_disagreement_rms_m", 0.0) + 1e-15,
                f"{point_id}.ray_disagreement_rms_m",
            ) - 1e-15
            all_joint_names.add(joint)
            if reprojection > reproj_limit or disagreement > ray_limit:
                rejected_joints[joint] = "geometry_quality_threshold"
                rejected += 1
                continue
            accepted[joint] = xyz
            observation_refs[joint] = point_id

        deviations: dict[str, float] = {}
        for segment, (a, b) in SEGMENTS.items():
            if a in accepted and b in accepted and segment in profile.segments_m:
                expected = profile.segments_m[segment]
                deviations[segment] = round(
                    abs(_distance(accepted[a], accepted[b]) - expected) / expected, 6
                )
        angles: dict[str, float] = {}
        skipped_angles: dict[str, str] = {}
        for name, (a, b, c, side) in KNEES.items():
            if not all(marker in accepted for marker in (a, b, c)):
                skipped_angles[name] = "joint_unobserved_or_rejected"
                continue
            if any(
                deviations.get(segment, 0.0) > segment_limit
                for segment in (f"{side}_femur", f"{side}_tibia")
            ):
                skipped_angles[name] = "personal_segment_geometry_disagreement"
                continue
            angle = _knee_flexion(accepted[a], accepted[b], accepted[c])
            if angle is None:
                skipped_angles[name] = "degenerate_segment"
                continue
            angles[name] = angle

        output_frames.append({
            "frame_index": frame_index,
            "reference_time_ns": time_ns,
            "time_s": round((time_ns - start_ns) / 1e9, 9),
            "markers_world_m": {k: list(v) for k, v in sorted(accepted.items())},
            "point_source_ids": dict(sorted(observation_refs.items())),
            "rejected_joints": dict(sorted(rejected_joints.items())),
            "segment_length_relative_deviation": dict(sorted(deviations.items())),
            "joint_angles_deg": dict(sorted(angles.items())),
            "skipped_joint_angles": dict(sorted(skipped_angles.items())),
        })

    if not any(frame["markers_world_m"] for frame in output_frames):
        raise ValueError("no geometry points passed the quality thresholds")
    trc_content: bytes | None = None
    if trc_output is not None:
        trc_content = _trc(output_frames, sorted(all_joint_names), trc_output.name)

    report: dict[str, Any] = {
        "schema_version": KINEMATICS_SCHEMA,
        "subject_id": mapping["subject_id"],
        "body_model_id": profile.model_id,
        "body_model_personalized_source_verified": personalized_qualified,
        "source": {
            "geometry_report_sha256": sha256_file(geometry_path),
            "rig_receipt_sha256": sha256_file(rig_path),
            "world_frame_sha256": sha256_file(world_path),
            "body_profile_sha256": sha256_file(profile_path),
            "body_source_artifact_sha256": source_hash,
            "joint_map_sha256": sha256_file(map_path),
            "source_correspondences_sha256": geo.get("correspondences_sha256"),
        },
        "coordinate_frame": {
            "world_frame_id": world.get("frame_id"),
            "units": "m",
            "axes": axes,
        },
        "thresholds": {
            "max_reprojection_px": reproj_limit,
            "max_ray_disagreement_m": ray_limit,
            "max_segment_deviation_fraction": segment_limit,
            "max_contiguous_gap_s": gap_limit,
        },
        "marker_names": sorted(all_joint_names),
        "frame_count": len(output_frames),
        "rejected_joint_observations": rejected,
        "discontinuities": gaps,
        "frames": output_frames,
        "trc_sha256": hashlib.sha256(trc_content).hexdigest() if trc_content else None,
        "evidence_level": "calibrated_multiview_kinematics_candidate",
        "claim_boundary": (
            "This is a derived, calibrated multi-view marker trajectory with "
            "model consistency diagnostics, not ground-truth motion capture. "
            "Angles are geometric estimates. No joint torque, muscle activation, "
            "muscle force, tissue strain, injury risk, or physiological asymmetry "
            "is identified from these data alone."
        ),
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    if trc_output is not None and trc_content is not None:
        trc_output.parent.mkdir(parents=True, exist_ok=True)
        trc_output.write_bytes(trc_content)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report
