from __future__ import annotations

import math
import statistics
from pathlib import Path
from typing import Any

from .camera import CAMERA_POSE_STREAM
from .session import SessionReader

INDO_POSE_METRICS_SCHEMA_VERSION = "motionos.indo-pose-metrics.v1"


def analyze_indo_camera_session(
    session_dir: str | Path,
) -> dict[str, Any]:
    reader = SessionReader(session_dir)
    payloads = [
        event.payload
        for event in reader.iter_stream(CAMERA_POSE_STREAM)
    ]
    result = analyze_indo_pose_payloads(payloads)
    result["session_id"] = reader.manifest.session_id
    return result


def analyze_indo_pose_payloads(
    payloads: list[dict[str, Any]],
) -> dict[str, Any]:
    knee_flexions: list[float] = []
    trunk_offsets: list[float] = []
    stance_widths: list[float] = []
    arm_excursions: list[float] = []
    frame_confidences: list[float] = []
    complete_frames = 0

    for payload in payloads:
        joints = _image_joints(payload)
        bounds = _bounds(payload)
        if not joints or bounds is None:
            continue

        bbox_width = max(bounds[2] - bounds[0], 1e-6)
        bbox_height = max(bounds[3] - bounds[1], 1e-6)

        left_hip = _joint(joints, "left_hip", "lefthip")
        right_hip = _joint(joints, "right_hip", "righthip")
        left_knee = _joint(joints, "left_knee", "leftknee")
        right_knee = _joint(joints, "right_knee", "rightknee")
        left_ankle = _joint(
            joints,
            "left_ankle",
            "leftankle",
            "left_foot",
            "leftfoot",
        )
        right_ankle = _joint(
            joints,
            "right_ankle",
            "rightankle",
            "right_foot",
            "rightfoot",
        )
        left_shoulder = _joint(
            joints,
            "left_shoulder",
            "leftshoulder",
        )
        right_shoulder = _joint(
            joints,
            "right_shoulder",
            "rightshoulder",
        )
        left_wrist = _joint(
            joints,
            "left_wrist",
            "leftwrist",
            "left_hand",
            "lefthand",
        )
        right_wrist = _joint(
            joints,
            "right_wrist",
            "rightwrist",
            "right_hand",
            "righthand",
        )

        left_flexion = _knee_flexion(
            left_hip,
            left_knee,
            left_ankle,
        )
        right_flexion = _knee_flexion(
            right_hip,
            right_knee,
            right_ankle,
        )
        per_frame_flexion = [
            value
            for value in (left_flexion, right_flexion)
            if value is not None
        ]
        knee_flexions.extend(per_frame_flexion)

        pelvis = _midpoint(left_hip, right_hip)
        shoulders = _midpoint(left_shoulder, right_shoulder)
        if pelvis is not None and shoulders is not None:
            trunk_offsets.append(
                abs(shoulders[0] - pelvis[0]) / bbox_width
            )

        if left_ankle is not None and right_ankle is not None:
            stance_widths.append(
                _distance(left_ankle, right_ankle) / bbox_width
            )

        if shoulders is not None:
            wrists = [
                wrist
                for wrist in (left_wrist, right_wrist)
                if wrist is not None
            ]
            if wrists:
                arm_excursions.append(
                    sum(
                        _distance(wrist, shoulders) / bbox_height
                        for wrist in wrists
                    )
                    / len(wrists)
                )

        if (
            pelvis is not None
            and shoulders is not None
            and len(per_frame_flexion) >= 1
            and left_ankle is not None
            and right_ankle is not None
        ):
            complete_frames += 1

        confidence = payload.get("body_pose_2d_mean_confidence")
        if isinstance(confidence, (int, float)):
            value = float(confidence)
            if math.isfinite(value):
                frame_confidences.append(
                    min(1.0, max(0.0, value))
                )

    observed_frames = sum(
        1
        for payload in payloads
        if _image_joints(payload) and _bounds(payload) is not None
    )
    total_frames = len(payloads)
    coverage = (
        observed_frames / total_frames
        if total_frames
        else 0.0
    )
    complete_fraction = (
        complete_frames / observed_frames
        if observed_frames
        else 0.0
    )
    mean_pose_confidence = (
        statistics.fmean(frame_confidences)
        if frame_confidences
        else 0.0
    )
    base_confidence = min(
        1.0,
        max(
            0.0,
            coverage
            * complete_fraction
            * mean_pose_confidence,
        ),
    )

    metrics: dict[str, float] = {}
    confidence: dict[str, float] = {}

    if knee_flexions:
        metrics["median_knee_flexion_deg"] = statistics.median(
            knee_flexions
        )
        metrics["knee_flexion_iqr_deg"] = _iqr(knee_flexions)
        confidence["median_knee_flexion_deg"] = base_confidence
        confidence["knee_flexion_iqr_deg"] = base_confidence

    if trunk_offsets:
        metrics["trunk_excursion"] = statistics.median(
            trunk_offsets
        )
        metrics["trunk_excursion_p90"] = _percentile(
            trunk_offsets,
            0.90,
        )
        confidence["trunk_excursion"] = base_confidence
        confidence["trunk_excursion_p90"] = base_confidence

    if stance_widths:
        metrics["median_stance_width_bbox_ratio"] = (
            statistics.median(stance_widths)
        )
        confidence["median_stance_width_bbox_ratio"] = (
            base_confidence
        )

    if arm_excursions:
        metrics["median_arm_excursion_body_ratio"] = (
            statistics.median(arm_excursions)
        )
        confidence["median_arm_excursion_body_ratio"] = (
            base_confidence
        )

    return {
        "schema_version": INDO_POSE_METRICS_SCHEMA_VERSION,
        "frame_accounting": {
            "total_pose_frames": total_frames,
            "frames_with_2d_pose": observed_frames,
            "complete_frames": complete_frames,
            "coverage_fraction": coverage,
            "complete_fraction": complete_fraction,
            "mean_pose_confidence": mean_pose_confidence,
        },
        "metrics": metrics,
        "confidence": confidence,
        "claim_boundary": (
            "These are image/body-pose posture metrics. Without qualified "
            "board and roller state they are not full balance-state, "
            "center-of-mass, force, or clinical measurements."
        ),
    }


def _image_joints(
    payload: dict[str, Any],
) -> dict[str, tuple[float, float, float]]:
    raw = payload.get("body_pose_2d_joints")
    if not isinstance(raw, dict):
        return {}

    result: dict[str, tuple[float, float, float]] = {}
    for name, point in raw.items():
        if not isinstance(point, list) or len(point) < 2:
            continue
        try:
            x = float(point[0])
            y = float(point[1])
            confidence = float(point[2]) if len(point) >= 3 else 1.0
        except (TypeError, ValueError):
            continue
        if not all(math.isfinite(v) for v in (x, y, confidence)):
            continue
        if confidence < 0.25:
            continue
        result[_normalize(str(name))] = (x, y, confidence)
    return result


def _bounds(
    payload: dict[str, Any],
) -> tuple[float, float, float, float] | None:
    raw = payload.get("body_bbox_image_normalized")
    if not isinstance(raw, list) or len(raw) != 4:
        return None
    try:
        values = tuple(float(value) for value in raw)
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(value) for value in values):
        return None
    if values[2] <= values[0] or values[3] <= values[1]:
        return None
    return values


def _joint(
    joints: dict[str, tuple[float, float, float]],
    *aliases: str,
) -> tuple[float, float, float] | None:
    for alias in aliases:
        point = joints.get(_normalize(alias))
        if point is not None:
            return point
    return None


def _midpoint(
    first: tuple[float, float, float] | None,
    second: tuple[float, float, float] | None,
) -> tuple[float, float] | None:
    if first is None or second is None:
        return None
    return (
        (first[0] + second[0]) / 2,
        (first[1] + second[1]) / 2,
    )


def _distance(
    first: tuple[float, ...],
    second: tuple[float, ...],
) -> float:
    return math.hypot(
        first[0] - second[0],
        first[1] - second[1],
    )


def _knee_flexion(
    hip: tuple[float, float, float] | None,
    knee: tuple[float, float, float] | None,
    ankle: tuple[float, float, float] | None,
) -> float | None:
    if hip is None or knee is None or ankle is None:
        return None

    first = (hip[0] - knee[0], hip[1] - knee[1])
    second = (ankle[0] - knee[0], ankle[1] - knee[1])
    first_norm = math.hypot(*first)
    second_norm = math.hypot(*second)
    if first_norm <= 1e-9 or second_norm <= 1e-9:
        return None

    cosine = (
        first[0] * second[0] + first[1] * second[1]
    ) / (first_norm * second_norm)
    angle = math.degrees(
        math.acos(min(1.0, max(-1.0, cosine)))
    )
    return max(0.0, 180.0 - angle)


def _percentile(values: list[float], quantile: float) -> float:
    if not values:
        raise ValueError("percentile requires values")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return (
        ordered[lower] * (1 - fraction)
        + ordered[upper] * fraction
    )


def _iqr(values: list[float]) -> float:
    return _percentile(values, 0.75) - _percentile(values, 0.25)


def _normalize(value: str) -> str:
    return "".join(
        character
        for character in value.lower()
        if character.isalnum()
    )
