from __future__ import annotations

import json
import math
import statistics
from collections import Counter
from pathlib import Path

QUALITY_REPORT_SCHEMA_VERSION = "motionos.indo-board-quality-report.v1"


def build_indo_board_quality_report(
    *,
    external_sync_path: str | Path,
    clock_bundle_path: str | Path,
    skeleton_correspondences_path: str | Path,
    skeleton_geometry_path: str | Path,
    board_correspondences_path: str | Path,
    board_geometry_path: str | Path,
    board_pose_series_path: str | Path,
    reconstruction_path: str | Path,
    metrics_path: str | Path,
    wrist_fusion_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    external_sync = _json_object(external_sync_path)
    clock_bundle = _json_object(clock_bundle_path)
    skeleton_correspondences = _json_object(
        skeleton_correspondences_path
    )
    skeleton_geometry = _json_object(skeleton_geometry_path)
    board_correspondences = _json_object(
        board_correspondences_path
    )
    board_geometry = _json_object(board_geometry_path)
    board_pose_series = _json_object(board_pose_series_path)
    reconstruction = _json_object(reconstruction_path)
    metrics = _json_object(metrics_path)
    wrist_fusion = _json_object(wrist_fusion_path)

    _require_schema(
        external_sync,
        "motionos.external-camera-sync.v1",
        label="external camera sync",
    )
    _require_schema(
        clock_bundle,
        "motionos.vision-clock-bundle.v1",
        label="vision clock bundle",
    )
    _require_schema(
        skeleton_correspondences,
        "motionos.multiview-correspondences.v1",
        label="skeleton correspondences",
    )
    _require_schema(
        skeleton_geometry,
        "motionos.multiview-geometry-report.v1",
        label="skeleton geometry",
    )
    _require_schema(
        board_correspondences,
        "motionos.multiview-correspondences.v1",
        label="board correspondences",
    )
    _require_schema(
        board_geometry,
        "motionos.multiview-geometry-report.v1",
        label="board geometry",
    )
    _require_schema(
        board_pose_series,
        "motionos.board-pose-series.v1",
        label="board pose series",
    )
    _require_schema(
        reconstruction,
        "motionos.indo-board-reconstruction.v1",
        label="Indo Board reconstruction",
    )
    _require_schema(
        metrics,
        "motionos.indo-board-report.v1",
        label="Indo Board metrics",
    )
    _require_schema(
        wrist_fusion,
        "motionos.wrist-acceleration-fusion.v1",
        label="wrist acceleration fusion",
    )

    board_poses = _object_list(
        board_pose_series.get("poses"),
        label="board pose series poses",
    )
    board_residual_rms = [
        _finite_float(pose["residual_rms_m"])
        for pose in board_poses
    ]
    board_residual_max = [
        _finite_float(pose["residual_max_m"])
        for pose in board_poses
    ]
    board_scale_error = [
        abs(_finite_float(pose["fitted_scale"]) - 1.0)
        for pose in board_poses
    ]

    reconstruction_rejections = _object_list(
        reconstruction.get("rejected_samples", []),
        label="reconstruction rejected_samples",
    )
    rejected_reason_counts = Counter(
        str(item.get("reason", "unknown"))
        for item in reconstruction_rejections
    )

    metric_items = _object_list(
        metrics.get("metrics"),
        label="Indo Board metrics list",
    )
    metric_summary = [
        {
            "metric_id": str(item["metric_id"]),
            "value": item.get("value"),
            "unit": item.get("unit"),
            "confidence": _finite_float(
                item.get("confidence", 0.0)
            ),
            "available": item.get("value") is not None,
            "unavailable_reason": item.get("unavailable_reason"),
        }
        for item in metric_items
    ]

    unavailable_metrics = [
        str(item["metric_id"])
        for item in metric_items
        if item.get("value") is None
    ]

    sample_count = int(metrics["sample_count"])
    accepted_sample_count = int(metrics["accepted_sample_count"])
    rejected_sample_count = int(metrics["rejected_sample_count"])
    accepted_fraction = (
        accepted_sample_count / sample_count
        if sample_count > 0
        else 0.0
    )

    clock_keys = (
        "watch_to_host",
        "iphone_camera_to_watch",
        "action4_to_watch",
    )
    clock_summary: dict[str, object] = {}
    for key in clock_keys:
        model = _mapping(
            clock_bundle,
            key,
            label=f"clock bundle {key}",
        )
        clock_summary[key] = {
            "residual_rms_ms": _finite_float(
                model["residual_rms_ms"]
            ),
            "drift_ppm": _finite_float(model["drift_ppm"]),
            "observations_used": int(model["observations_used"]),
        }

    external_model = _mapping(
        external_sync,
        "clock_model",
        label="external camera clock model",
    )

    board_rejected_count = int(
        board_pose_series.get("rejected_frame_count", 0)
    )
    board_pose_count = int(board_pose_series.get("pose_count", 0))

    attention: list[str] = []
    if rejected_sample_count > 0:
        attention.append("metric_quality_gate_rejections_present")
    if int(reconstruction.get("rejected_sample_count", 0)) > 0:
        attention.append("reconstruction_rejections_present")
    if board_rejected_count > 0:
        attention.append("board_pose_rejections_present")
    if unavailable_metrics:
        attention.append("one_or_more_metrics_unavailable")

    report: dict[str, object] = {
        "schema_version": QUALITY_REPORT_SCHEMA_VERSION,
        "session_id": str(metrics["session_id"]),
        "summary": {
            "pose_frame_pairs": int(
                skeleton_correspondences.get("pair_count", 0)
            ),
            "board_frame_pairs": int(
                board_correspondences.get("pair_count", 0)
            ),
            "skeleton_3d_points": int(
                skeleton_geometry.get("point_count", 0)
            ),
            "board_3d_points": int(
                board_geometry.get("point_count", 0)
            ),
            "board_pose_count": board_pose_count,
            "board_pose_rejected_count": board_rejected_count,
            "reconstruction_sample_count": int(
                reconstruction.get("sample_count", 0)
            ),
            "metric_input_sample_count": sample_count,
            "metric_accepted_sample_count": accepted_sample_count,
            "metric_rejected_sample_count": rejected_sample_count,
            "metric_accepted_fraction": accepted_fraction,
            "wrist_fusion_sample_count": int(
                wrist_fusion.get("sample_count", 0)
            ),
        },
        "timing": {
            "external_physical_landmark_clock": {
                "residual_rms_ms": _finite_float(
                    external_model["residual_rms_ms"]
                ),
                "drift_ppm": _finite_float(
                    external_model["drift_ppm"]
                ),
                "observations_used": int(
                    external_model["observations_used"]
                ),
                "candidate_peak_count": int(
                    external_sync.get("external_candidate_count", 0)
                ),
            },
            "canonical_watch_clock_models": clock_summary,
        },
        "geometry": {
            "skeleton": {
                "reprojection_residual_px":
                    skeleton_geometry.get(
                        "reprojection_residual_px"
                    ),
                "ray_disagreement_rms_m":
                    skeleton_geometry.get(
                        "ray_disagreement_rms_m"
                    ),
            },
            "board_markers": {
                "reprojection_residual_px":
                    board_geometry.get(
                        "reprojection_residual_px"
                    ),
                "ray_disagreement_rms_m":
                    board_geometry.get(
                        "ray_disagreement_rms_m"
                    ),
            },
            "board_pose": {
                "residual_rms_m":
                    _distribution(board_residual_rms),
                "residual_max_m":
                    _distribution(board_residual_max),
                "absolute_scale_error_fraction":
                    _distribution(board_scale_error),
            },
        },
        "reconstruction": {
            "modeled_mass_coverage":
                reconstruction.get("modeled_mass_coverage"),
            "rejected_reason_counts":
                dict(sorted(rejected_reason_counts.items())),
        },
        "metrics": {
            "estimates": metric_summary,
            "unavailable_metric_ids": unavailable_metrics,
        },
        "cross_modal_consistency": {
            "wrist_side": wrist_fusion.get("wrist_side"),
            "watch_minus_vision_rms_m_s2": _finite_float(
                wrist_fusion["watch_minus_vision_rms_m_s2"]
            ),
        },
        "attention_flags": attention,
        "claim_boundary": (
            "This report summarizes evidence quality and rejection patterns. "
            "It is not an aggregate quality score and does not establish "
            "laboratory ground-truth accuracy. Inspect the underlying "
            "artifacts before interpreting performance metrics."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw


def _require_schema(
    document: dict[str, object],
    expected: str,
    *,
    label: str,
) -> None:
    if document.get("schema_version") != expected:
        raise ValueError(f"unsupported {label} schema")


def _mapping(
    document: dict[str, object],
    key: str,
    *,
    label: str,
) -> dict[str, object]:
    raw = document.get(key)
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must be an object")
    return raw


def _object_list(
    raw: object,
    *,
    label: str,
) -> list[dict[str, object]]:
    if not isinstance(raw, list):
        raise TypeError(f"{label} must be a list")
    if any(not isinstance(item, dict) for item in raw):
        raise TypeError(f"{label} entries must be objects")
    return [dict(item) for item in raw]


def _finite_float(raw: object) -> float:
    value = float(raw)
    if not math.isfinite(value):
        raise ValueError("quality report values must be finite")
    return value


def _distribution(
    values: list[float],
) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "rms": None,
            "p95": None,
            "max": None,
        }
    ordered = sorted(values)
    rank = min(
        len(ordered) - 1,
        math.ceil(0.95 * len(ordered)) - 1,
    )
    return {
        "count": len(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "rms": math.sqrt(
            sum(value * value for value in values)
            / len(values)
        ),
        "p95": ordered[rank],
        "max": ordered[-1],
    }
