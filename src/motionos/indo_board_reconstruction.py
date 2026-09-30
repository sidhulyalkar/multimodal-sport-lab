from __future__ import annotations

import json
import math
import re
import statistics
from dataclasses import dataclass
from pathlib import Path

from .indo_board import IndoBoardSample


_SKELETON_POINT = re.compile(r"^(?P<joint>.+)-ref-(?P<time>\d+)$")


@dataclass(frozen=True)
class SkeletonFrame:
    time_ns: int
    joints_m: dict[str, tuple[float, float, float]]
    joint_confidence: float
    reprojection_rms_px: float
    timing_uncertainty_ms: float


@dataclass(frozen=True)
class COMEstimate:
    position_m: tuple[float, float, float]
    modeled_mass_coverage: float


def build_indo_board_samples(
    skeleton_geometry_path: str | Path,
    skeleton_correspondences_path: str | Path,
    board_pose_series_path: str | Path,
    *,
    maximum_pair_time_delta_ms: float = 20.0,
    minimum_modeled_mass_coverage: float = 0.75,
    maximum_board_fit_residual_m: float = 0.03,
) -> tuple[tuple[IndoBoardSample, ...], dict[str, object]]:
    skeleton_frames = _skeleton_frames(
        skeleton_geometry_path,
        skeleton_correspondences_path,
    )
    board_poses = _board_poses(board_pose_series_path)

    if maximum_pair_time_delta_ms <= 0:
        raise ValueError(
            "maximum_pair_time_delta_ms must be positive"
        )
    max_delta_ns = round(maximum_pair_time_delta_ms * 1e6)

    samples: list[IndoBoardSample] = []
    rejected: list[dict[str, object]] = []
    coverages: list[float] = []

    first_time_ns: int | None = None
    board_index = 0

    for skeleton in skeleton_frames:
        while (
            board_index + 1 < len(board_poses)
            and abs(
                board_poses[board_index + 1]["reference_time_ns"]
                - skeleton.time_ns
            )
            <= abs(
                board_poses[board_index]["reference_time_ns"]
                - skeleton.time_ns
            )
        ):
            board_index += 1

        board = board_poses[board_index]
        delta_ns = abs(
            int(board["reference_time_ns"]) - skeleton.time_ns
        )
        if delta_ns > max_delta_ns:
            rejected.append(
                {
                    "reference_time_ns": skeleton.time_ns,
                    "reason": "no_board_pose_within_tolerance",
                    "nearest_delta_ms": delta_ns / 1e6,
                }
            )
            continue
        if float(board["residual_rms_m"]) > (
            maximum_board_fit_residual_m
        ):
            rejected.append(
                {
                    "reference_time_ns": skeleton.time_ns,
                    "reason": "board_pose_residual_too_large",
                    "board_residual_rms_m":
                        float(board["residual_rms_m"]),
                }
            )
            continue

        com = estimate_center_of_mass(skeleton.joints_m)
        coverages.append(com.modeled_mass_coverage)
        if com.modeled_mass_coverage < minimum_modeled_mass_coverage:
            rejected.append(
                {
                    "reference_time_ns": skeleton.time_ns,
                    "reason": "insufficient_com_mass_coverage",
                    "modeled_mass_coverage":
                        com.modeled_mass_coverage,
                }
            )
            continue

        left_knee = _knee_flexion(
            skeleton.joints_m,
            side="left",
        )
        right_knee = _knee_flexion(
            skeleton.joints_m,
            side="right",
        )

        if first_time_ns is None:
            first_time_ns = skeleton.time_ns
        pose_confidence = min(
            1.0,
            skeleton.joint_confidence
            * com.modeled_mass_coverage,
        )
        samples.append(
            IndoBoardSample(
                time_s=(skeleton.time_ns - first_time_ns) / 1e9,
                com_x_m=com.position_m[0],
                com_y_m=com.position_m[1],
                com_z_m=com.position_m[2],
                board_roll_deg=float(board["roll_deg"]),
                board_pitch_deg=float(board["pitch_deg"]),
                left_knee_flexion_deg=left_knee,
                right_knee_flexion_deg=right_knee,
                pose_confidence=pose_confidence,
                timing_uncertainty_ms=max(
                    skeleton.timing_uncertainty_ms,
                    delta_ns / 1e6,
                ),
                reprojection_rms_px=skeleton.reprojection_rms_px,
            )
        )

    if len(samples) < 3:
        raise ValueError(
            "fewer than three synchronized skeleton/board samples survived"
        )

    diagnostics: dict[str, object] = {
        "schema_version": "motionos.indo-board-reconstruction.v1",
        "skeleton_frame_count": len(skeleton_frames),
        "board_pose_count": len(board_poses),
        "sample_count": len(samples),
        "rejected_sample_count": len(rejected),
        "rejected_samples": rejected,
        "modeled_mass_coverage": {
            "minimum": min(coverages) if coverages else None,
            "median": statistics.median(coverages)
            if coverages
            else None,
            "maximum": max(coverages) if coverages else None,
        },
        "claim_boundary": (
            "Center of mass is an anthropometric segment-model estimate "
            "from reconstructed joint geometry, not a force-platform "
            "measurement. Missing segment mass is quantified and gated."
        ),
    }
    return tuple(samples), diagnostics


def estimate_center_of_mass(
    joints_m: dict[str, tuple[float, float, float]],
) -> COMEstimate:
    joints = {
        _canonical_joint(name): point
        for name, point in joints_m.items()
    }

    shoulder_mid = _midpoint_optional(
        joints.get("leftshoulder"),
        joints.get("rightshoulder"),
    )
    hip_mid = _midpoint_optional(
        joints.get("lefthip"),
        joints.get("righthip"),
    )
    neck = joints.get("neck") or shoulder_mid
    nose = joints.get("nose")

    segments: list[
        tuple[
            float,
            tuple[float, float, float] | None,
        ]
    ] = []

    segments.append(
        (
            0.081,
            _segment_point(neck, nose, 0.50),
        )
    )
    segments.append(
        (
            0.497,
            _segment_point(shoulder_mid, hip_mid, 0.50),
        )
    )

    for side in ("left", "right"):
        shoulder = joints.get(f"{side}shoulder")
        elbow = joints.get(f"{side}elbow")
        wrist = joints.get(f"{side}wrist")
        hip = joints.get(f"{side}hip")
        knee = joints.get(f"{side}knee")
        ankle = joints.get(f"{side}ankle")

        segments.extend(
            [
                (0.028, _segment_point(shoulder, elbow, 0.436)),
                (0.016, _segment_point(elbow, wrist, 0.430)),
                (0.006, wrist),
                (0.100, _segment_point(hip, knee, 0.433)),
                (0.0465, _segment_point(knee, ankle, 0.433)),
                (0.0145, ankle),
            ]
        )

    available = [
        (mass, point)
        for mass, point in segments
        if point is not None
    ]
    coverage = sum(mass for mass, _point in available)
    if coverage <= 0:
        raise ValueError(
            "skeleton has no joints usable by the COM segment model"
        )

    position = tuple(
        sum(
            mass * point[axis]
            for mass, point in available
            if point is not None
        )
        / coverage
        for axis in range(3)
    )
    return COMEstimate(
        position_m=position,
        modeled_mass_coverage=coverage,
    )


def _skeleton_frames(
    geometry_path: str | Path,
    correspondences_path: str | Path,
) -> tuple[SkeletonFrame, ...]:
    geometry = json.loads(
        Path(geometry_path).read_text(encoding="utf-8")
    )
    correspondence = json.loads(
        Path(correspondences_path).read_text(encoding="utf-8")
    )
    if not isinstance(geometry, dict) or not isinstance(
        correspondence,
        dict,
    ):
        raise TypeError(
            "skeleton geometry and correspondences must be objects"
        )
    if geometry.get("schema_version") != (
        "motionos.multiview-geometry-report.v1"
    ):
        raise ValueError("unsupported skeleton geometry schema")
    if correspondence.get("schema_version") != (
        "motionos.multiview-correspondences.v1"
    ):
        raise ValueError("unsupported skeleton correspondence schema")

    confidence_by_point: dict[str, float] = {}
    for point in correspondence.get("points", []):
        if not isinstance(point, dict):
            continue
        observations = point.get("observations")
        if not isinstance(observations, dict):
            continue
        confidences = [
            float(observation["joint_confidence"])
            for observation in observations.values()
            if isinstance(observation, dict)
            and observation.get("joint_confidence") is not None
        ]
        if confidences:
            confidence_by_point[str(point["point_id"])] = min(
                confidences
            )

    grouped: dict[
        int,
        list[tuple[str, tuple[float, float, float], float, float, float]],
    ] = {}
    for point in geometry.get("points", []):
        if not isinstance(point, dict):
            continue
        point_id = str(point.get("point_id", ""))
        if point_id.startswith("board-marker-"):
            continue
        match = _SKELETON_POINT.match(point_id)
        if match is None:
            continue
        confidence = confidence_by_point.get(point_id)
        if confidence is None:
            continue

        raw_position = point.get("world_position_m")
        timing = point.get("timing")
        if (
            not isinstance(raw_position, list)
            or len(raw_position) != 3
            or not isinstance(timing, dict)
        ):
            continue
        predictive = [
            float(value["clock_predictive_std_ms"])
            for value in timing.values()
            if isinstance(value, dict)
            and value.get("clock_predictive_std_ms") is not None
        ]
        max_timing = max(predictive) if predictive else 0.0
        reference_time_ns = int(point["reference_time_ns"])
        grouped.setdefault(reference_time_ns, []).append(
            (
                match.group("joint"),
                (
                    float(raw_position[0]),
                    float(raw_position[1]),
                    float(raw_position[2]),
                ),
                confidence,
                float(point["mean_reprojection_residual_px"]),
                max_timing,
            )
        )

    frames: list[SkeletonFrame] = []
    for time_ns, values in sorted(grouped.items()):
        joints = {
            joint: position
            for joint, position, _confidence, _reprojection, _timing
            in values
        }
        confidences = [
            confidence
            for _joint, _position, confidence, _reprojection, _timing
            in values
        ]
        reprojections = [
            reprojection
            for _joint, _position, _confidence, reprojection, _timing
            in values
        ]
        timings = [
            timing
            for _joint, _position, _confidence, _reprojection, timing
            in values
        ]
        frames.append(
            SkeletonFrame(
                time_ns=time_ns,
                joints_m=joints,
                joint_confidence=statistics.median(confidences),
                reprojection_rms_px=math.sqrt(
                    sum(value * value for value in reprojections)
                    / len(reprojections)
                ),
                timing_uncertainty_ms=max(timings),
            )
        )

    if not frames:
        raise ValueError(
            "no confidence-linked skeleton frames were reconstructed"
        )
    return tuple(frames)


def _board_poses(path: str | Path) -> tuple[dict[str, object], ...]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("board pose series must be an object")
    if raw.get("schema_version") != "motionos.board-pose-series.v1":
        raise ValueError("unsupported board pose series schema")
    poses = raw.get("poses")
    if not isinstance(poses, list) or not poses:
        raise ValueError("board pose series contains no poses")
    return tuple(
        dict(pose)
        for pose in poses
        if isinstance(pose, dict)
    )


def _canonical_joint(name: str) -> str:
    return "".join(
        character
        for character in name.lower()
        if character.isalnum()
    )


def _midpoint_optional(
    first: tuple[float, float, float] | None,
    second: tuple[float, float, float] | None,
) -> tuple[float, float, float] | None:
    if first is None or second is None:
        return None
    return tuple(
        (first[axis] + second[axis]) / 2
        for axis in range(3)
    )


def _segment_point(
    proximal: tuple[float, float, float] | None,
    distal: tuple[float, float, float] | None,
    fraction: float,
) -> tuple[float, float, float] | None:
    if proximal is None or distal is None:
        return None
    return tuple(
        proximal[axis]
        + fraction * (distal[axis] - proximal[axis])
        for axis in range(3)
    )


def _knee_flexion(
    joints: dict[str, tuple[float, float, float]],
    *,
    side: str,
) -> float | None:
    canonical = {
        _canonical_joint(name): point
        for name, point in joints.items()
    }
    hip = canonical.get(f"{side}hip")
    knee = canonical.get(f"{side}knee")
    ankle = canonical.get(f"{side}ankle")
    if hip is None or knee is None or ankle is None:
        return None

    first = tuple(hip[axis] - knee[axis] for axis in range(3))
    second = tuple(ankle[axis] - knee[axis] for axis in range(3))
    first_norm = math.sqrt(sum(value * value for value in first))
    second_norm = math.sqrt(sum(value * value for value in second))
    if first_norm <= 1e-9 or second_norm <= 1e-9:
        return None
    cosine = sum(
        first[axis] * second[axis]
        for axis in range(3)
    ) / (first_norm * second_norm)
    cosine = max(-1.0, min(1.0, cosine))
    return math.degrees(math.acos(cosine))
