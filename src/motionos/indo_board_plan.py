from __future__ import annotations

import json
import math
from pathlib import Path

from .indo_board_acquisition import ACQUISITION_PROFILE_ID
from .indo_board_qualification import validate_qualification_contract
from .provenance import sha256_file

PLAN_SPEC_SCHEMA_VERSION = (
    "motionos.indo-board-qualification-plan-spec.v1"
)
PLAN_SCHEMA_VERSION = "motionos.indo-board-qualification-plan.v1"


def build_indo_board_qualification_plan(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    source = Path(spec_path).resolve()
    spec = _json_object(source)
    if spec.get("schema_version") != PLAN_SPEC_SCHEMA_VERSION:
        raise ValueError(
            "unsupported Indo Board qualification-plan spec schema"
        )

    plan_id = str(spec.get("plan_id", "")).strip()
    if not plan_id:
        raise ValueError("plan_id is required")

    base = source.parent
    rig_path = _resolve(base, spec["rig_receipt"])
    layout_path = _resolve(base, spec["board_marker_layout"])
    marker_receipt_path = _resolve(
        base,
        spec["board_marker_asset_receipt"],
    )
    fusion_receipt_path = _resolve(
        base,
        spec["wrist_fusion_calibration_receipt"],
    )
    for path in (
        rig_path,
        layout_path,
        marker_receipt_path,
        fusion_receipt_path,
    ):
        if not path.is_file():
            raise FileNotFoundError(path)

    rig = _json_object(rig_path)
    if rig.get("schema_version") != "motionos.camera-rig-receipt.v1":
        raise ValueError("qualification plan requires a camera-rig receipt")
    if rig.get("passed") is not True:
        raise ValueError(
            "qualification plan requires a passing camera-rig receipt"
        )

    layout = _json_object(layout_path)
    marker_receipt = _json_object(marker_receipt_path)
    _validate_marker_binding(
        layout,
        marker_receipt,
        marker_receipt_path,
    )

    fusion_receipt = _json_object(fusion_receipt_path)
    if fusion_receipt.get("schema_version") != (
        "motionos.wrist-fusion-calibration.v1"
    ):
        raise ValueError(
            "qualification plan requires a wrist-fusion calibration receipt"
        )
    if fusion_receipt.get("acquisition_profile_id") != (
        ACQUISITION_PROFILE_ID
    ):
        raise ValueError(
            "wrist-fusion calibration acquisition profile does not match "
            "the current M0-Vision profile"
        )

    fusion = fusion_receipt.get("recommended_wrist_fusion")
    if not isinstance(fusion, dict):
        raise TypeError(
            "wrist-fusion calibration receipt requires "
            "recommended_wrist_fusion"
        )
    frozen_fusion = _validate_fusion_contract(dict(fusion))

    thresholds = _mapping(spec, "thresholds")
    frozen_thresholds = _validate_analysis_thresholds(thresholds)

    qualification = _mapping(spec, "qualification")
    validate_qualification_contract(qualification)

    protocol = _mapping(spec, "protocol")
    coaching_condition = str(
        protocol.get("coaching_condition", "")
    )
    if coaching_condition not in {
        "feedback_disabled",
        "feedback_enabled",
    }:
        raise ValueError(
            "protocol.coaching_condition must be feedback_disabled "
            "or feedback_enabled"
        )
    minimum_sync_landmarks = _positive_int(
        protocol,
        "minimum_sync_landmarks",
    )
    if minimum_sync_landmarks < 3:
        raise ValueError(
            "protocol.minimum_sync_landmarks must be at least 3"
        )

    result: dict[str, object] = {
        "schema_version": PLAN_SCHEMA_VERSION,
        "plan_id": plan_id,
        "source_spec_sha256": sha256_file(source),
        "frozen_before_scored_capture": True,
        "acquisition_profile_id": ACQUISITION_PROFILE_ID,
        "evidence": {
            "rig_receipt": _evidence_entry(rig_path),
            "board_marker_layout": _evidence_entry(layout_path),
            "board_marker_asset_receipt":
                _evidence_entry(marker_receipt_path),
            "wrist_fusion_calibration_receipt":
                _evidence_entry(fusion_receipt_path),
        },
        "rig_id": str(rig.get("rig_id", "")),
        "thresholds": frozen_thresholds,
        "wrist_fusion": frozen_fusion,
        "qualification": qualification,
        "protocol": {
            "coaching_condition": coaching_condition,
            "minimum_sync_landmarks": minimum_sync_landmarks,
        },
        "claim_boundary": (
            "This plan freezes MotionOS M0-Vision analysis and qualification "
            "inputs before a scored Indo Board capture. It prevents "
            "outcome-informed edits to thresholds, fusion parameters, rig, "
            "marker geometry, feedback condition, and minimum synchronization "
            "coverage. It does not itself prove that the later session passes."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def validate_indo_board_qualification_plan(
    plan_path: str | Path,
) -> dict[str, object]:
    path = Path(plan_path).resolve()
    plan = _json_object(path)
    if plan.get("schema_version") != PLAN_SCHEMA_VERSION:
        raise ValueError(
            "unsupported Indo Board qualification-plan schema"
        )
    if plan.get("frozen_before_scored_capture") is not True:
        raise ValueError(
            "qualification plan must declare frozen_before_scored_capture"
        )
    if not str(plan.get("plan_id", "")).strip():
        raise ValueError("qualification plan requires plan_id")
    if plan.get("acquisition_profile_id") != ACQUISITION_PROFILE_ID:
        raise ValueError(
            "qualification plan acquisition profile does not match "
            "the current M0-Vision profile"
        )

    evidence = _mapping(plan, "evidence")
    for key in (
        "rig_receipt",
        "board_marker_layout",
        "board_marker_asset_receipt",
        "wrist_fusion_calibration_receipt",
    ):
        entry = evidence.get(key)
        if not isinstance(entry, dict):
            raise TypeError(
                f"qualification plan evidence.{key} must be an object"
            )
        if not str(entry.get("sha256", "")).strip():
            raise ValueError(
                f"qualification plan evidence.{key} requires sha256"
            )

    _validate_analysis_thresholds(_mapping(plan, "thresholds"))
    _validate_fusion_contract(_mapping(plan, "wrist_fusion"))
    qualification = _mapping(plan, "qualification")
    validate_qualification_contract(qualification)

    protocol = _mapping(plan, "protocol")
    condition = str(protocol.get("coaching_condition", ""))
    if condition not in {"feedback_disabled", "feedback_enabled"}:
        raise ValueError("unsupported qualification-plan coaching condition")
    minimum_sync = _positive_int(protocol, "minimum_sync_landmarks")
    if minimum_sync < 3:
        raise ValueError(
            "qualification-plan minimum_sync_landmarks must be at least 3"
        )
    return plan


def _validate_analysis_thresholds(
    thresholds: dict[str, object],
) -> dict[str, object]:
    result = dict(thresholds)
    _positive_float(result, "maximum_pose_pair_ms")
    _positive_float(result, "maximum_marker_pair_ms")
    _fraction(result, "minimum_joint_confidence")
    _positive_int(result, "marker_frame_stride")
    _nonnegative_float(
        result,
        "maximum_board_scale_error_fraction",
    )
    _positive_float(
        result,
        "maximum_skeleton_board_pair_ms",
    )
    _fraction(
        result,
        "minimum_modeled_mass_coverage",
    )
    _positive_float(
        result,
        "maximum_board_fit_residual_m",
    )
    _fraction(result, "minimum_pose_confidence")
    _positive_float(
        result,
        "maximum_timing_uncertainty_ms",
    )
    _positive_float(
        result,
        "maximum_reprojection_rms_px",
    )
    _fraction(
        result,
        "minimum_longitudinal_confidence",
    )
    return result


def _validate_fusion_contract(
    fusion: dict[str, object],
) -> dict[str, object]:
    result = dict(fusion)
    for key in (
        "watch_acceleration_std_m_s2",
        "vision_acceleration_std_m_s2",
        "maximum_acceleration_rate_m_s3",
        "maximum_time_delta_ms",
    ):
        _positive_float(result, key)
    return result


def _validate_marker_binding(
    layout: dict[str, object],
    receipt: dict[str, object],
    receipt_path: Path,
) -> None:
    if layout.get("schema_version") != "motionos.board-marker-layout.v1":
        raise ValueError("unsupported board marker layout schema")
    if receipt.get("schema_version") != (
        "motionos.aruco-marker-build-receipt.v1"
    ):
        raise ValueError("unsupported ArUco marker build receipt schema")
    if layout.get("marker_asset_receipt_sha256") != sha256_file(
        receipt_path
    ):
        raise ValueError(
            "board marker layout is not bound to the supplied "
            "ArUco build receipt"
        )

    if str(layout.get("layout_id", "")) != str(
        receipt.get("asset_id", "")
    ):
        raise ValueError(
            "board marker layout_id must match ArUco asset_id"
        )
    if str(layout.get("marker_dictionary", "")) != str(
        receipt.get("dictionary", "")
    ):
        raise ValueError(
            "board marker dictionary must match ArUco build receipt"
        )


def _evidence_entry(path: Path) -> dict[str, object]:
    return {
        "filename": path.name,
        "sha256": sha256_file(path),
    }


def _mapping(
    source: dict[str, object],
    key: str,
) -> dict[str, object]:
    value = source.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"{key} must be an object")
    return dict(value)


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
    value = _finite_float(source.get(key), key=key)
    if value <= 0:
        raise ValueError(f"{key} must be positive")
    return value


def _nonnegative_float(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), key=key)
    if value < 0:
        raise ValueError(f"{key} must be non-negative")
    return value


def _fraction(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), key=key)
    if not 0 <= value <= 1:
        raise ValueError(f"{key} must be between 0 and 1")
    return value


def _finite_float(
    raw: object,
    *,
    key: str,
) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be numeric") from exc
    if not math.isfinite(value):
        raise ValueError(f"{key} must be finite")
    return value


def _resolve(base: Path, value: object) -> Path:
    path = Path(str(value))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw
