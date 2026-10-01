from __future__ import annotations

import json
import math
from itertools import pairwise
from pathlib import Path

from .indo_board_acquisition import ACQUISITION_PROFILE_ID
from .indo_board_reconstruction import load_skeleton_frames
from .provenance import sha256_file
from .wrist_fusion import (
    infer_watch_wrist_side,
    load_watch_events,
    pair_wrist_acceleration_samples,
    vision_wrist_acceleration,
    watch_acceleration_magnitude,
)

WRIST_FUSION_CALIBRATION_SPEC_SCHEMA_VERSION = (
    "motionos.wrist-fusion-calibration-spec.v1"
)
WRIST_FUSION_CALIBRATION_SCHEMA_VERSION = (
    "motionos.wrist-fusion-calibration.v1"
)


def calibrate_wrist_fusion(
    skeleton_geometry_path: str | Path,
    skeleton_correspondences_path: str | Path,
    watch_journal_path: str | Path,
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    geometry_path = Path(skeleton_geometry_path).resolve()
    correspondences_path = Path(
        skeleton_correspondences_path
    ).resolve()
    watch_path = Path(watch_journal_path).resolve()
    calibration_spec_path = Path(spec_path).resolve()
    spec = _json_object(calibration_spec_path)
    if spec.get("schema_version") != (
        WRIST_FUSION_CALIBRATION_SPEC_SCHEMA_VERSION
    ):
        raise ValueError(
            "unsupported wrist-fusion calibration spec schema"
        )
    reconstruction_receipt_path = _resolve(
        calibration_spec_path.parent,
        spec["reconstruction_receipt"],
    )

    for path in (
        geometry_path,
        correspondences_path,
        watch_path,
        calibration_spec_path,
        reconstruction_receipt_path,
    ):
        if not path.is_file():
            raise FileNotFoundError(path)

    reconstruction = _json_object(reconstruction_receipt_path)
    _validate_reconstruction_binding(
        reconstruction,
        geometry_path=geometry_path,
        correspondences_path=correspondences_path,
        watch_path=watch_path,
    )

    stationary_window = _window(spec, "stationary_window_s")
    dynamic_window = _window(spec, "dynamic_window_s")
    if _overlap(stationary_window, dynamic_window):
        raise ValueError(
            "stationary and dynamic calibration windows must not overlap"
        )

    maximum_time_delta_ms = _positive_float(
        spec,
        "maximum_time_delta_ms",
    )
    minimum_stationary_pairs = _positive_int(
        spec,
        "minimum_stationary_pairs",
    )
    minimum_dynamic_pairs = _positive_int(
        spec,
        "minimum_dynamic_pairs",
    )
    jerk_percentile = _fraction(
        spec,
        "jerk_percentile",
    )
    if jerk_percentile < 0.5:
        raise ValueError(
            "jerk_percentile must be at least 0.5"
        )
    jerk_margin_factor = _positive_float(
        spec,
        "jerk_margin_factor",
    )
    if jerk_margin_factor < 1.0:
        raise ValueError(
            "jerk_margin_factor must be at least 1.0"
        )

    frames = load_skeleton_frames(
        geometry_path,
        correspondences_path,
    )
    watch_events = load_watch_events(watch_path)
    wrist_side_raw = spec.get("wrist_side")
    wrist_side = (
        str(wrist_side_raw)
        if wrist_side_raw is not None
        else infer_watch_wrist_side(watch_events)
    )
    if wrist_side not in {"left", "right"}:
        raise ValueError("wrist_side must be left or right")

    vision = vision_wrist_acceleration(
        frames,
        side=wrist_side,
    )
    watch = watch_acceleration_magnitude(watch_events)
    pairs = pair_wrist_acceleration_samples(
        vision,
        watch,
        maximum_time_delta_ms=maximum_time_delta_ms,
    )
    if not pairs:
        raise ValueError(
            "no Watch/vision wrist acceleration pairs survived timing gate"
        )

    paired = _paired_samples(pairs)
    t0_ns = int(paired[0]["time_ns"])
    for sample in paired:
        sample["relative_time_s"] = (
            int(sample["time_ns"]) - t0_ns
        ) / 1e9

    stationary = _select_window(
        paired,
        stationary_window,
    )
    dynamic = _select_window(
        paired,
        dynamic_window,
    )
    if len(stationary) < minimum_stationary_pairs:
        raise ValueError(
            "stationary calibration window has fewer paired samples "
            "than minimum_stationary_pairs"
        )
    if len(dynamic) < minimum_dynamic_pairs:
        raise ValueError(
            "dynamic calibration window has fewer paired samples "
            "than minimum_dynamic_pairs"
        )

    watch_stationary = [
        float(sample["watch_m_s2"])
        for sample in stationary
    ]
    vision_stationary = [
        float(sample["vision_m_s2"])
        for sample in stationary
    ]
    stationary_residuals = [
        watch_value - vision_value
        for watch_value, vision_value in zip(
            watch_stationary,
            vision_stationary,
            strict=True,
        )
    ]

    watch_std = _rms(watch_stationary)
    vision_std = _rms(vision_stationary)
    if watch_std <= 0 or vision_std <= 0:
        raise ValueError(
            "stationary calibration produced zero acceleration uncertainty; "
            "collect a longer real sensor calibration rather than using zero"
        )

    dynamic_residuals = [
        float(sample["watch_m_s2"])
        - float(sample["vision_m_s2"])
        for sample in dynamic
    ]
    watch_rates = _absolute_rates(
        dynamic,
        value_key="watch_m_s2",
    )
    vision_rates = _absolute_rates(
        dynamic,
        value_key="vision_m_s2",
    )
    combined_rates = [*watch_rates, *vision_rates]
    if not combined_rates:
        raise ValueError(
            "dynamic calibration window has insufficient temporal variation"
        )

    observed_rate = _percentile(
        combined_rates,
        jerk_percentile,
    )
    maximum_rate = observed_rate * jerk_margin_factor
    if maximum_rate <= 0:
        raise ValueError(
            "dynamic calibration produced a zero acceleration-rate bound"
        )

    result: dict[str, object] = {
        "schema_version": WRIST_FUSION_CALIBRATION_SCHEMA_VERSION,
        "acquisition_profile_id": ACQUISITION_PROFILE_ID,
        "reconstruction_receipt_sha256":
            sha256_file(reconstruction_receipt_path),
        "wrist_side": wrist_side,
        "source_sha256": {
            "skeleton_geometry": sha256_file(geometry_path),
            "skeleton_correspondences":
                sha256_file(correspondences_path),
            "watch_journal": sha256_file(watch_path),
            "calibration_spec":
                sha256_file(calibration_spec_path),
            "reconstruction_receipt":
                sha256_file(reconstruction_receipt_path),
        },
        "pair_count": len(paired),
        "time_origin_watch_ns": t0_ns,
        "stationary_window": {
            "start_s": stationary_window[0],
            "end_s": stationary_window[1],
            "pair_count": len(stationary),
            "watch_acceleration_rms_m_s2": watch_std,
            "vision_acceleration_rms_m_s2": vision_std,
            "watch_minus_vision_rms_m_s2":
                _rms(stationary_residuals),
        },
        "dynamic_window": {
            "start_s": dynamic_window[0],
            "end_s": dynamic_window[1],
            "pair_count": len(dynamic),
            "watch_minus_vision_rms_m_s2":
                _rms(dynamic_residuals),
            "watch_acceleration_rate_abs_m_s3":
                _distribution(watch_rates),
            "vision_acceleration_rate_abs_m_s3":
                _distribution(vision_rates),
            "combined_acceleration_rate_abs_m_s3":
                _distribution(combined_rates),
            "jerk_percentile": jerk_percentile,
            "observed_percentile_m_s3": observed_rate,
            "jerk_margin_factor": jerk_margin_factor,
        },
        "recommended_wrist_fusion": {
            "watch_acceleration_std_m_s2": watch_std,
            "vision_acceleration_std_m_s2": vision_std,
            "maximum_acceleration_rate_m_s3": maximum_rate,
            "maximum_time_delta_ms": maximum_time_delta_ms,
        },
        "qualification_observation": {
            "dynamic_watch_minus_vision_rms_m_s2":
                _rms(dynamic_residuals),
            "note": (
                "This observed disagreement is calibration evidence only. "
                "Freeze the later qualification threshold independently "
                "before viewing the scored session."
            ),
        },
        "claim_boundary": (
            "Stationary RMS acceleration magnitude is used as a conservative "
            "empirical uncertainty proxy relative to zero motion. The dynamic "
            "acceleration-rate bound is an observed percentile multiplied by "
            "the predeclared margin factor. These parameters calibrate the "
            "secondary scalar wrist-fusion model; they do not establish "
            "ground-truth biomechanics or choose scored-session qualification "
            "thresholds automatically."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def validate_wrist_fusion_calibration_spec(
    spec_path: str | Path,
) -> dict[str, object]:
    path = Path(spec_path).resolve()
    spec = _json_object(path)
    if spec.get("schema_version") != (
        WRIST_FUSION_CALIBRATION_SPEC_SCHEMA_VERSION
    ):
        raise ValueError(
            "unsupported wrist-fusion calibration spec schema"
        )
    reconstruction_receipt = spec.get("reconstruction_receipt")
    if not isinstance(reconstruction_receipt, str) or not (
        reconstruction_receipt.strip()
    ):
        raise ValueError("reconstruction_receipt is required")
    receipt_path = _resolve(path.parent, reconstruction_receipt)
    if not receipt_path.is_file():
        raise FileNotFoundError(receipt_path)
    receipt = _json_object(receipt_path)
    if receipt.get("schema_version") != (
        "motionos.wrist-fusion-reconstruction.v1"
    ):
        raise ValueError(
            "unsupported wrist-fusion reconstruction receipt schema"
        )
    if receipt.get("acquisition_profile_id") != ACQUISITION_PROFILE_ID:
        raise ValueError(
            "wrist-fusion reconstruction acquisition profile mismatch"
        )

    stationary = _window(spec, "stationary_window_s")
    dynamic = _window(spec, "dynamic_window_s")
    if _overlap(stationary, dynamic):
        raise ValueError(
            "stationary and dynamic calibration windows must not overlap"
        )
    _positive_float(spec, "maximum_time_delta_ms")
    _positive_int(spec, "minimum_stationary_pairs")
    _positive_int(spec, "minimum_dynamic_pairs")
    percentile = _fraction(spec, "jerk_percentile")
    if percentile < 0.5:
        raise ValueError(
            "jerk_percentile must be at least 0.5"
        )
    margin = _positive_float(spec, "jerk_margin_factor")
    if margin < 1.0:
        raise ValueError(
            "jerk_margin_factor must be at least 1.0"
        )
    if spec.get("wrist_side") not in {None, "left", "right"}:
        raise ValueError("wrist_side must be left or right")
    return spec


def _validate_reconstruction_binding(
    receipt: dict[str, object],
    *,
    geometry_path: Path,
    correspondences_path: Path,
    watch_path: Path,
) -> None:
    if receipt.get("schema_version") != (
        "motionos.wrist-fusion-reconstruction.v1"
    ):
        raise ValueError(
            "unsupported wrist-fusion reconstruction receipt schema"
        )
    if receipt.get("acquisition_profile_id") != ACQUISITION_PROFILE_ID:
        raise ValueError(
            "wrist-fusion reconstruction acquisition profile mismatch"
        )

    artifacts = receipt.get("artifacts")
    inputs = receipt.get("input_sha256")
    if not isinstance(artifacts, dict) or not isinstance(inputs, dict):
        raise TypeError(
            "wrist-fusion reconstruction receipt is missing provenance"
        )

    expected_geometry = artifacts.get("skeleton_geometry")
    expected_correspondences = artifacts.get("skeleton_correspondences")
    if not isinstance(expected_geometry, dict) or not isinstance(
        expected_correspondences,
        dict,
    ):
        raise TypeError(
            "wrist-fusion reconstruction receipt is missing skeleton artifacts"
        )

    if expected_geometry.get("sha256") != sha256_file(geometry_path):
        raise ValueError(
            "skeleton geometry does not match reconstruction receipt"
        )
    if expected_correspondences.get("sha256") != sha256_file(
        correspondences_path
    ):
        raise ValueError(
            "skeleton correspondences do not match reconstruction receipt"
        )
    if inputs.get("watch_journal") != sha256_file(watch_path):
        raise ValueError(
            "Watch journal does not match reconstruction receipt"
        )


def _resolve(base: Path, raw: object) -> Path:
    path = Path(str(raw))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _paired_samples(
    pairs: tuple[
        tuple[
            dict[str, float | int],
            dict[str, float | int],
        ],
        ...,
    ],
) -> list[dict[str, float | int]]:
    result: list[dict[str, float | int]] = []
    for vision, watch in pairs:
        vision_time = int(vision["time_ns"])
        watch_time = int(watch["time_ns"])
        result.append(
            {
                "time_ns": round(
                    (vision_time + watch_time) / 2
                ),
                "vision_time_ns": vision_time,
                "watch_time_ns": watch_time,
                "vision_m_s2": float(vision["value"]),
                "watch_m_s2": float(watch["value"]),
                "time_delta_ms":
                    (watch_time - vision_time) / 1e6,
            }
        )
    result.sort(key=lambda item: int(item["time_ns"]))
    return result


def _select_window(
    samples: list[dict[str, float | int]],
    window: tuple[float, float],
) -> list[dict[str, float | int]]:
    start, end = window
    return [
        sample
        for sample in samples
        if start
        <= float(sample["relative_time_s"])
        <= end
    ]


def _absolute_rates(
    samples: list[dict[str, float | int]],
    *,
    value_key: str,
) -> list[float]:
    rates: list[float] = []
    for first, second in pairwise(samples):
        dt_s = (
            int(second["time_ns"])
            - int(first["time_ns"])
        ) / 1e9
        if dt_s <= 0:
            continue
        rates.append(
            abs(
                float(second[value_key])
                - float(first[value_key])
            )
            / dt_s
        )
    return rates


def _distribution(
    values: list[float],
) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "median": None,
            "p95": None,
            "p99": None,
            "max": None,
        }
    return {
        "count": len(values),
        "median": _percentile(values, 0.5),
        "p95": _percentile(values, 0.95),
        "p99": _percentile(values, 0.99),
        "max": max(values),
    }


def _percentile(
    values: list[float],
    fraction: float,
) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    rank = min(
        len(ordered) - 1,
        max(0, math.ceil(fraction * len(ordered)) - 1),
    )
    return ordered[rank]


def _rms(values: list[float]) -> float:
    if not values:
        raise ValueError("RMS requires at least one value")
    return math.sqrt(
        sum(value * value for value in values) / len(values)
    )


def _window(
    spec: dict[str, object],
    key: str,
) -> tuple[float, float]:
    raw = spec.get(key)
    if not isinstance(raw, list) or len(raw) != 2:
        raise ValueError(
            f"{key} must be [start_s, end_s]"
        )
    start = _finite_float(raw[0], label=f"{key}[0]")
    end = _finite_float(raw[1], label=f"{key}[1]")
    if start < 0 or end <= start:
        raise ValueError(
            f"{key} must satisfy 0 <= start < end"
        )
    return start, end


def _overlap(
    first: tuple[float, float],
    second: tuple[float, float],
) -> bool:
    return max(first[0], second[0]) <= min(
        first[1],
        second[1],
    )


def _positive_float(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), label=key)
    if value <= 0:
        raise ValueError(f"{key} must be positive")
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
        raise ValueError(
            f"{key} must be a positive integer"
        ) from exc
    if value <= 0 or float(raw) != value:
        raise ValueError(
            f"{key} must be a positive integer"
        )
    return value


def _fraction(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), label=key)
    if not 0 < value <= 1:
        raise ValueError(
            f"{key} must be greater than 0 and at most 1"
        )
    return value


def _finite_float(
    raw: object,
    *,
    label: str,
) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite")
    return value


def _json_object(
    path: str | Path,
) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw
