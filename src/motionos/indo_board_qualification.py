from __future__ import annotations

import json
import math
from pathlib import Path

QUALIFICATION_RECEIPT_SCHEMA_VERSION = (
    "motionos.indo-board-qualification-receipt.v1"
)

FIRST_FIVE_METRIC_IDS = (
    "balance_stability_rms_m",
    "com_excursion_p95_m",
    "board_control_jerk_rms_deg_s3",
    "recovery_latency_median_s",
    "stance_asymmetry_mean_abs_knee_deg",
)


def build_indo_board_qualification_receipt(
    quality_report_path: str | Path,
    qualification: dict[str, object],
    output_path: str | Path,
) -> dict[str, object]:
    quality = _json_object(quality_report_path)
    if quality.get("schema_version") != (
        "motionos.indo-board-quality-report.v1"
    ):
        raise ValueError("unsupported Indo Board quality report schema")

    summary = _mapping(quality, "summary")
    timing = _mapping(quality, "timing")
    geometry = _mapping(quality, "geometry")
    metrics = _mapping(quality, "metrics")
    consistency = _mapping(quality, "cross_modal_consistency")

    external = _mapping(
        timing,
        "external_physical_landmark_clock",
    )
    clocks = _mapping(
        timing,
        "canonical_watch_clock_models",
    )
    iphone_clock = _mapping(clocks, "iphone_camera_to_watch")
    action4_clock = _mapping(clocks, "action4_to_watch")

    skeleton_geometry = _mapping(geometry, "skeleton")
    board_geometry = _mapping(geometry, "board_markers")
    board_pose = _mapping(geometry, "board_pose")

    skeleton_reprojection = _mapping(
        skeleton_geometry,
        "reprojection_residual_px",
    )
    board_reprojection = _mapping(
        board_geometry,
        "reprojection_residual_px",
    )
    board_pose_residual = _mapping(
        board_pose,
        "residual_rms_m",
    )
    board_scale_error = _mapping(
        board_pose,
        "absolute_scale_error_fraction",
    )

    required_metric_ids = _required_metric_ids(qualification)
    unavailable = {
        str(value)
        for value in metrics.get("unavailable_metric_ids", [])
    }
    estimates = metrics.get("estimates")
    if not isinstance(estimates, list):
        raise TypeError("quality metrics.estimates must be a list")
    present_metric_ids = {
        str(item.get("metric_id"))
        for item in estimates
        if isinstance(item, dict)
    }
    missing_metric_ids = sorted(
        set(required_metric_ids) - present_metric_ids
    )
    unavailable_required = sorted(
        set(required_metric_ids) & unavailable
    )

    board_pose_count = int(summary["board_pose_count"])
    board_pose_rejected_count = int(
        summary["board_pose_rejected_count"]
    )
    board_total = board_pose_count + board_pose_rejected_count
    board_rejected_fraction = (
        board_pose_rejected_count / board_total
        if board_total > 0
        else 1.0
    )
    reconstruction_count = int(
        summary["reconstruction_sample_count"]
    )
    reconstruction_rejected = sum(
        int(value)
        for value in _mapping(
            quality,
            "reconstruction",
        ).get("rejected_reason_counts", {}).values()
    )
    reconstruction_total = (
        reconstruction_count + reconstruction_rejected
    )
    reconstruction_rejected_fraction = (
        reconstruction_rejected / reconstruction_total
        if reconstruction_total > 0
        else 1.0
    )

    gates = [
        _minimum_gate(
            "pose_frame_pairs",
            int(summary["pose_frame_pairs"]),
            _positive_int(
                qualification,
                "minimum_pose_frame_pairs",
            ),
        ),
        _minimum_gate(
            "board_frame_pairs",
            int(summary["board_frame_pairs"]),
            _positive_int(
                qualification,
                "minimum_board_frame_pairs",
            ),
        ),
        _minimum_gate(
            "board_pose_count",
            board_pose_count,
            _positive_int(
                qualification,
                "minimum_board_pose_count",
            ),
        ),
        _minimum_gate(
            "metric_accepted_samples",
            int(summary["metric_accepted_sample_count"]),
            _positive_int(
                qualification,
                "minimum_metric_accepted_samples",
            ),
        ),
        _minimum_gate(
            "metric_accepted_fraction",
            _finite_float(
                summary["metric_accepted_fraction"]
            ),
            _fraction(
                qualification,
                "minimum_metric_accepted_fraction",
            ),
        ),
        _maximum_gate(
            "external_clock_residual_rms_ms",
            _finite_float(external["residual_rms_ms"]),
            _positive_float(
                qualification,
                "maximum_external_clock_residual_ms",
            ),
        ),
        _maximum_gate(
            "iphone_to_watch_clock_residual_rms_ms",
            _finite_float(iphone_clock["residual_rms_ms"]),
            _positive_float(
                qualification,
                "maximum_iphone_clock_residual_ms",
            ),
        ),
        _maximum_gate(
            "action4_to_watch_clock_residual_rms_ms",
            _finite_float(action4_clock["residual_rms_ms"]),
            _positive_float(
                qualification,
                "maximum_action4_clock_residual_ms",
            ),
        ),
        _maximum_gate(
            "skeleton_reprojection_rms_px",
            _finite_float(skeleton_reprojection["rms"]),
            _positive_float(
                qualification,
                "maximum_skeleton_reprojection_rms_px",
            ),
        ),
        _maximum_gate(
            "board_reprojection_rms_px",
            _finite_float(board_reprojection["rms"]),
            _positive_float(
                qualification,
                "maximum_board_reprojection_rms_px",
            ),
        ),
        _maximum_gate(
            "board_pose_residual_p95_m",
            _finite_float(board_pose_residual["p95"]),
            _positive_float(
                qualification,
                "maximum_board_pose_residual_p95_m",
            ),
        ),
        _maximum_gate(
            "board_pose_scale_error_p95_fraction",
            _finite_float(board_scale_error["p95"]),
            _nonnegative_float(
                qualification,
                "maximum_board_pose_scale_error_p95_fraction",
            ),
        ),
        _maximum_gate(
            "board_pose_rejected_fraction",
            board_rejected_fraction,
            _fraction(
                qualification,
                "maximum_board_pose_rejected_fraction",
            ),
        ),
        _maximum_gate(
            "reconstruction_rejected_fraction",
            reconstruction_rejected_fraction,
            _fraction(
                qualification,
                "maximum_reconstruction_rejected_fraction",
            ),
        ),
        _maximum_gate(
            "watch_minus_vision_rms_m_s2",
            _finite_float(
                consistency["watch_minus_vision_rms_m_s2"]
            ),
            _positive_float(
                qualification,
                "maximum_watch_vision_rms_m_s2",
            ),
        ),
        {
            "gate_id": "required_metrics_available",
            "observed": {
                "required_metric_ids": list(required_metric_ids),
                "missing_metric_ids": missing_metric_ids,
                "unavailable_metric_ids": unavailable_required,
            },
            "criterion": "all_required_metrics_present_and_available",
            "passed": not missing_metric_ids
            and not unavailable_required,
        },
    ]

    passed = all(bool(gate["passed"]) for gate in gates)
    receipt: dict[str, object] = {
        "schema_version": QUALIFICATION_RECEIPT_SCHEMA_VERSION,
        "session_id": str(quality["session_id"]),
        "passed": passed,
        "gates": gates,
        "failed_gate_ids": [
            str(gate["gate_id"])
            for gate in gates
            if not bool(gate["passed"])
        ],
        "longitudinal_update_permitted": passed,
        "claim_boundary": (
            "This qualification receipt applies predeclared engineering "
            "evidence gates to one Indo Board session. passed=true permits "
            "this session to update the MotionOS longitudinal baseline; it "
            "does not establish laboratory ground-truth biomechanical "
            "accuracy or clinical validity."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def validate_qualification_contract(
    qualification: dict[str, object],
) -> None:
    _positive_int(qualification, "minimum_pose_frame_pairs")
    _positive_int(qualification, "minimum_board_frame_pairs")
    _positive_int(qualification, "minimum_board_pose_count")
    _positive_int(qualification, "minimum_metric_accepted_samples")
    _fraction(qualification, "minimum_metric_accepted_fraction")
    _positive_float(
        qualification,
        "maximum_external_clock_residual_ms",
    )
    _positive_float(
        qualification,
        "maximum_iphone_clock_residual_ms",
    )
    _positive_float(
        qualification,
        "maximum_action4_clock_residual_ms",
    )
    _positive_float(
        qualification,
        "maximum_skeleton_reprojection_rms_px",
    )
    _positive_float(
        qualification,
        "maximum_board_reprojection_rms_px",
    )
    _positive_float(
        qualification,
        "maximum_board_pose_residual_p95_m",
    )
    _nonnegative_float(
        qualification,
        "maximum_board_pose_scale_error_p95_fraction",
    )
    _fraction(
        qualification,
        "maximum_board_pose_rejected_fraction",
    )
    _fraction(
        qualification,
        "maximum_reconstruction_rejected_fraction",
    )
    _positive_float(
        qualification,
        "maximum_watch_vision_rms_m_s2",
    )
    _required_metric_ids(qualification)


def _required_metric_ids(
    qualification: dict[str, object],
) -> tuple[str, ...]:
    raw = qualification.get("required_metric_ids")
    if not isinstance(raw, list) or not raw:
        raise ValueError(
            "required_metric_ids must be a non-empty list"
        )
    values = tuple(str(value).strip() for value in raw)
    if any(not value for value in values):
        raise ValueError(
            "required_metric_ids may not contain empty values"
        )
    if len(set(values)) != len(values):
        raise ValueError(
            "required_metric_ids must not contain duplicates"
        )
    return values


def _minimum_gate(
    gate_id: str,
    observed: int | float,
    threshold: int | float,
) -> dict[str, object]:
    return {
        "gate_id": gate_id,
        "observed": observed,
        "criterion": ">=",
        "threshold": threshold,
        "passed": observed >= threshold,
    }


def _maximum_gate(
    gate_id: str,
    observed: int | float,
    threshold: int | float,
) -> dict[str, object]:
    return {
        "gate_id": gate_id,
        "observed": observed,
        "criterion": "<=",
        "threshold": threshold,
        "passed": observed <= threshold,
    }


def _mapping(
    source: dict[str, object],
    key: str,
) -> dict[str, object]:
    value = source.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"{key} must be an object")
    return value


def _positive_int(
    source: dict[str, object],
    key: str,
) -> int:
    raw = source.get(key)
    if isinstance(raw, bool):
        raise TypeError(f"{key} must be a positive integer")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be a positive integer") from exc
    if value <= 0 or float(raw) != value:
        raise ValueError(f"{key} must be a positive integer")
    return value


def _positive_float(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key))
    if value <= 0:
        raise ValueError(f"{key} must be positive")
    return value


def _nonnegative_float(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key))
    if value < 0:
        raise ValueError(f"{key} must be non-negative")
    return value


def _fraction(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key))
    if not 0 <= value <= 1:
        raise ValueError(f"{key} must be between 0 and 1")
    return value


def _finite_float(raw: object) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            "qualification threshold/value must be numeric"
        ) from exc
    if not math.isfinite(value):
        raise ValueError(
            "qualification threshold/value must be finite"
        )
    return value


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw
