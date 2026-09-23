from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

from .clock_sync import (
    ClockLandmark,
    load_clock_sync_receipt,
    validate_clock_sync_receipt,
)
from .provenance import sha256_file
from .session import SessionReader

CLOCK_UNCERTAINTY_SCHEMA_VERSION = "motionos.clock-uncertainty.v1"


@dataclass(frozen=True)
class WeightedAffineClockModel:
    slope: float
    intercept_ns: float
    origin_device_time_ns: float
    origin_session_time_ns: float
    residual_rms_ns: float
    reduced_chi_square: float
    variance_scale: float
    origin_variance_ns2: float
    origin_slope_covariance_ns: float
    slope_variance: float
    observations_used: int
    support_start_ns: int
    support_end_ns: int

    def map_float(self, device_time_ns: int | float) -> float:
        return self.slope * float(device_time_ns) + self.intercept_ns

    def map(self, device_time_ns: int | float) -> int:
        return round(self.map_float(device_time_ns))

    @property
    def drift_ppm(self) -> float:
        return (self.slope - 1.0) * 1_000_000.0

    def parameter_variance_ns2(
        self,
        device_time_ns: int | float,
    ) -> float:
        delta = float(device_time_ns) - self.origin_device_time_ns
        value = (
            self.origin_variance_ns2
            + 2.0 * delta * self.origin_slope_covariance_ns
            + delta * delta * self.slope_variance
        )
        return max(0.0, value)

    def parameter_std_ns(self, device_time_ns: int | float) -> float:
        return math.sqrt(self.parameter_variance_ns2(device_time_ns))

    def predictive_std_ns(self, device_time_ns: int | float) -> float:
        parameter = self.parameter_variance_ns2(device_time_ns)
        return math.sqrt(parameter + self.residual_rms_ns**2)

    def outside_support_ns(self, device_time_ns: int | float) -> float:
        value = float(device_time_ns)
        if value < self.support_start_ns:
            return self.support_start_ns - value
        if value > self.support_end_ns:
            return value - self.support_end_ns
        return 0.0

    def to_dict(self) -> dict[str, object]:
        return {
            "slope": self.slope,
            "intercept_ns": self.intercept_ns,
            "drift_ppm": self.drift_ppm,
            "origin_device_time_ns": self.origin_device_time_ns,
            "origin_session_time_ns": self.origin_session_time_ns,
            "residual_rms_ns": self.residual_rms_ns,
            "residual_rms_ms": self.residual_rms_ns / 1e6,
            "reduced_chi_square": self.reduced_chi_square,
            "variance_scale": self.variance_scale,
            "covariance_at_origin": {
                "origin_variance_ns2": self.origin_variance_ns2,
                "origin_slope_covariance_ns": (
                    self.origin_slope_covariance_ns
                ),
                "slope_variance": self.slope_variance,
            },
            "standard_error": {
                "origin_time_ns": math.sqrt(self.origin_variance_ns2),
                "slope": math.sqrt(self.slope_variance),
                "drift_ppm": math.sqrt(self.slope_variance) * 1e6,
            },
            "observations_used": self.observations_used,
            "support_start_ns": self.support_start_ns,
            "support_end_ns": self.support_end_ns,
        }


@dataclass(frozen=True)
class WeightedObservation:
    index: int
    device_time_ns: int
    session_time_ns: int
    uncertainty_ns: float


def _effective_uncertainty(
    landmark: ClockLandmark,
    *,
    default_uncertainty_ns: float | None,
) -> float:
    declared = float(landmark.uncertainty_ns)
    if declared > 0:
        return declared
    if (
        default_uncertainty_ns is None
        or not math.isfinite(default_uncertainty_ns)
        or default_uncertainty_ns <= 0
    ):
        raise ValueError(
            "clock uncertainty analysis requires positive landmark "
            "uncertainty_ns values or an explicit positive default"
        )
    return float(default_uncertainty_ns)


def observations_from_landmarks(
    landmarks: tuple[ClockLandmark, ...],
    *,
    default_uncertainty_ns: float | None = None,
) -> tuple[WeightedObservation, ...]:
    if len(landmarks) < 3:
        raise ValueError(
            "clock uncertainty analysis requires at least three landmarks"
        )
    observations = tuple(
        WeightedObservation(
            index=landmark.index,
            device_time_ns=landmark.target_device_time_ns,
            session_time_ns=landmark.reference_time_ns,
            uncertainty_ns=_effective_uncertainty(
                landmark,
                default_uncertainty_ns=default_uncertainty_ns,
            ),
        )
        for landmark in landmarks
    )
    ordered = tuple(
        sorted(observations, key=lambda item: item.device_time_ns)
    )
    if len({item.device_time_ns for item in ordered}) != len(ordered):
        raise ValueError("clock landmarks must have unique target times")
    return ordered


def fit_weighted_affine_clock(
    observations: tuple[WeightedObservation, ...],
) -> WeightedAffineClockModel:
    if len(observations) < 2:
        raise ValueError("weighted clock fit requires at least two observations")
    if any(
        not math.isfinite(item.uncertainty_ns)
        or item.uncertainty_ns <= 0
        for item in observations
    ):
        raise ValueError("weighted clock uncertainties must be positive")

    weights = [
        1.0 / (item.uncertainty_ns * item.uncertainty_ns)
        for item in observations
    ]
    weight_sum = sum(weights)
    if weight_sum <= 0 or not math.isfinite(weight_sum):
        raise ValueError("weighted clock fit has invalid total weight")

    origin_x = sum(
        weight * item.device_time_ns
        for weight, item in zip(weights, observations)
    ) / weight_sum
    origin_y = sum(
        weight * item.session_time_ns
        for weight, item in zip(weights, observations)
    ) / weight_sum

    centered_x = [
        float(item.device_time_ns) - origin_x
        for item in observations
    ]
    centered_y = [
        float(item.session_time_ns) - origin_y
        for item in observations
    ]
    weighted_x2 = sum(
        weight * value * value
        for weight, value in zip(weights, centered_x)
    )
    if weighted_x2 <= 0 or not math.isfinite(weighted_x2):
        raise ValueError("weighted clock observations must span target time")

    slope = sum(
        weight * x * y
        for weight, x, y in zip(weights, centered_x, centered_y)
    ) / weighted_x2
    intercept = origin_y - slope * origin_x

    residuals = [
        float(item.session_time_ns)
        - (origin_y + slope * x)
        for item, x in zip(observations, centered_x)
    ]
    residual_rms = math.sqrt(
        sum(value * value for value in residuals) / len(residuals)
    )
    chi_square = sum(
        (residual / item.uncertainty_ns) ** 2
        for residual, item in zip(residuals, observations)
    )
    degrees_of_freedom = len(observations) - 2
    reduced_chi_square = (
        chi_square / degrees_of_freedom
        if degrees_of_freedom > 0
        else 0.0
    )
    variance_scale = max(1.0, reduced_chi_square)

    origin_variance = variance_scale / weight_sum
    slope_variance = variance_scale / weighted_x2

    return WeightedAffineClockModel(
        slope=slope,
        intercept_ns=intercept,
        origin_device_time_ns=origin_x,
        origin_session_time_ns=origin_y,
        residual_rms_ns=residual_rms,
        reduced_chi_square=reduced_chi_square,
        variance_scale=variance_scale,
        origin_variance_ns2=origin_variance,
        origin_slope_covariance_ns=0.0,
        slope_variance=slope_variance,
        observations_used=len(observations),
        support_start_ns=min(item.device_time_ns for item in observations),
        support_end_ns=max(item.device_time_ns for item in observations),
    )


def _loo_diagnostics(
    observations: tuple[WeightedObservation, ...],
) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    errors: list[float] = []
    for held_out_index, held_out in enumerate(observations):
        training = tuple(
            item
            for index, item in enumerate(observations)
            if index != held_out_index
        )
        model = fit_weighted_affine_clock(training)
        predicted = model.map_float(held_out.device_time_ns)
        error = float(held_out.session_time_ns) - predicted
        errors.append(error)
        entries.append(
            {
                "landmark_index": held_out.index,
                "device_time_ns": held_out.device_time_ns,
                "observed_reference_time_ns": held_out.session_time_ns,
                "predicted_reference_time_ns": predicted,
                "error_ns": error,
                "error_ms": error / 1e6,
                "prediction_std_ns": model.predictive_std_ns(
                    held_out.device_time_ns
                ),
                "extrapolated": (
                    model.outside_support_ns(held_out.device_time_ns) > 0
                ),
            }
        )

    rms = math.sqrt(
        sum(value * value for value in errors) / len(errors)
    )
    return {
        "landmarks": entries,
        "rms_error_ns": rms,
        "rms_error_ms": rms / 1e6,
        "max_abs_error_ns": max(abs(value) for value in errors),
        "max_abs_error_ms": max(abs(value) for value in errors) / 1e6,
    }


def _discontinuity_diagnostics(
    observations: tuple[WeightedObservation, ...],
    model: WeightedAffineClockModel,
) -> dict[str, object]:
    residuals = [
        float(item.session_time_ns) - model.map_float(item.device_time_ns)
        for item in observations
    ]
    local_slopes: list[float] = []
    for left, right in zip(observations, observations[1:]):
        delta_x = right.device_time_ns - left.device_time_ns
        if delta_x <= 0:
            raise ValueError("clock observations must be strictly ordered")
        local_slopes.append(
            (right.session_time_ns - left.session_time_ns) / delta_x
        )
    local_drifts = [
        (slope - 1.0) * 1e6
        for slope in local_slopes
    ]
    slope_jumps = [
        abs(right - left) * 1e6
        for left, right in zip(local_slopes, local_slopes[1:])
    ]
    residual_jumps = [
        abs(right - left)
        for left, right in zip(residuals, residuals[1:])
    ]
    span_ns = (
        observations[-1].device_time_ns
        - observations[0].device_time_ns
    )
    trend_ns_per_min = (
        (residuals[-1] - residuals[0]) / (span_ns / 60e9)
        if span_ns > 0
        else 0.0
    )
    return {
        "adjacent_segment_drift_ppm": local_drifts,
        "max_adjacent_slope_jump_ppm": (
            max(slope_jumps) if slope_jumps else 0.0
        ),
        "max_adjacent_residual_jump_ns": (
            max(residual_jumps) if residual_jumps else 0.0
        ),
        "max_adjacent_residual_jump_ms": (
            max(residual_jumps) / 1e6
            if residual_jumps
            else 0.0
        ),
        "residual_trend_ns_per_min": trend_ns_per_min,
        "interpretation": (
            "Numeric discontinuity diagnostics only; MotionOS does not "
            "invent a universal pass threshold."
        ),
    }


def _solve_3x3(
    matrix: list[list[float]],
    vector: list[float],
) -> tuple[float, float, float]:
    augmented = [
        list(row) + [value]
        for row, value in zip(matrix, vector)
    ]
    for pivot in range(3):
        swap = max(
            range(pivot, 3),
            key=lambda row: abs(augmented[row][pivot]),
        )
        if abs(augmented[swap][pivot]) <= 1e-24:
            raise ValueError("piecewise clock fit is singular")
        augmented[pivot], augmented[swap] = (
            augmented[swap],
            augmented[pivot],
        )
        scale = augmented[pivot][pivot]
        augmented[pivot] = [
            value / scale
            for value in augmented[pivot]
        ]
        for row in range(3):
            if row == pivot:
                continue
            factor = augmented[row][pivot]
            augmented[row] = [
                value - factor * pivot_value
                for value, pivot_value in zip(
                    augmented[row],
                    augmented[pivot],
                )
            ]
    return tuple(augmented[row][3] for row in range(3))


def _aicc(chi_square: float, *, parameters: int, count: int) -> float:
    aic = chi_square + 2.0 * parameters
    denominator = count - parameters - 1
    if denominator <= 0:
        return math.inf
    return (
        aic
        + 2.0 * parameters * (parameters + 1) / denominator
    )


def _piecewise_comparison(
    observations: tuple[WeightedObservation, ...],
    affine_model: WeightedAffineClockModel,
) -> dict[str, object]:
    count = len(observations)
    if count < 6:
        return {
            "available": False,
            "reason": (
                "At least six landmarks are required for the penalized "
                "continuous piecewise comparison."
            ),
        }

    affine_residuals = [
        float(item.session_time_ns)
        - affine_model.map_float(item.device_time_ns)
        for item in observations
    ]
    affine_chi_square = sum(
        (residual / item.uncertainty_ns) ** 2
        for residual, item in zip(affine_residuals, observations)
    )
    affine_aicc = _aicc(
        affine_chi_square,
        parameters=2,
        count=count,
    )

    origin = affine_model.origin_device_time_ns
    y_origin = affine_model.origin_session_time_ns
    candidates: list[dict[str, object]] = []
    for breakpoint_item in observations[2:-2]:
        breakpoint_seconds = (
            breakpoint_item.device_time_ns - origin
        ) / 1e9

        normal = [[0.0] * 3 for _ in range(3)]
        rhs = [0.0] * 3
        rows: list[tuple[list[float], float, float]] = []
        for item in observations:
            x_seconds = (item.device_time_ns - origin) / 1e9
            hinge = max(0.0, x_seconds - breakpoint_seconds)
            design = [1.0, x_seconds, hinge]
            y = float(item.session_time_ns) - y_origin
            weight = 1.0 / (item.uncertainty_ns**2)
            rows.append((design, y, item.uncertainty_ns))
            for row in range(3):
                rhs[row] += weight * design[row] * y
                for column in range(3):
                    normal[row][column] += (
                        weight * design[row] * design[column]
                    )

        try:
            parameters = _solve_3x3(normal, rhs)
        except ValueError:
            continue
        residuals = [
            y - sum(
                coefficient * value
                for coefficient, value in zip(parameters, design)
            )
            for design, y, _uncertainty in rows
        ]
        chi_square = sum(
            (residual / uncertainty) ** 2
            for residual, (_design, _y, uncertainty)
            in zip(residuals, rows)
        )
        candidates.append(
            {
                "breakpoint_device_time_ns": (
                    breakpoint_item.device_time_ns
                ),
                "chi_square": chi_square,
                "aicc": _aicc(
                    chi_square,
                    parameters=3,
                    count=count,
                ),
                "pre_break_slope": parameters[1] / 1e9,
                "post_break_slope": (
                    parameters[1] + parameters[2]
                ) / 1e9,
            }
        )

    if not candidates:
        return {
            "available": False,
            "reason": "No non-singular piecewise candidate could be fit.",
        }

    best = min(candidates, key=lambda item: float(item["aicc"]))
    return {
        "available": True,
        "affine": {
            "chi_square": affine_chi_square,
            "aicc": affine_aicc,
        },
        "best_continuous_piecewise": best,
        "delta_aicc_affine_minus_piecewise": (
            affine_aicc - float(best["aicc"])
        ),
        "interpretation": (
            "Positive delta means the penalized piecewise candidate has "
            "lower AICc. This diagnostic does not automatically authorize "
            "piecewise clock mapping."
        ),
    }


def _query(
    model: WeightedAffineClockModel,
    device_time_ns: int,
) -> dict[str, object]:
    outside = model.outside_support_ns(device_time_ns)
    parameter_std = model.parameter_std_ns(device_time_ns)
    predictive_std = model.predictive_std_ns(device_time_ns)
    return {
        "device_time_ns": device_time_ns,
        "mapped_reference_time_ns": model.map(device_time_ns),
        "fit_parameter_std_ns": parameter_std,
        "fit_parameter_std_ms": parameter_std / 1e6,
        "predictive_std_ns": predictive_std,
        "predictive_std_ms": predictive_std / 1e6,
        "extrapolated": outside > 0,
        "distance_outside_support_ns": outside,
        "distance_outside_support_s": outside / 1e9,
    }


def analyze_clock_uncertainty(
    reference_session: str | Path,
    target_session: str | Path,
    clock_sync_receipt: str | Path,
    output_path: str | Path,
    *,
    default_uncertainty_ns: float | None = None,
) -> dict[str, object]:
    receipt_path = Path(clock_sync_receipt).resolve()
    receipt = load_clock_sync_receipt(receipt_path)
    reference_reader = SessionReader(reference_session)
    target_reader = SessionReader(target_session)

    # Recompute all v1 invariants first. The derived analysis never upgrades a
    # stale or forged synchronization receipt.
    validate_clock_sync_receipt(
        receipt,
        reference_reader,
        target_reader,
    )

    observations = observations_from_landmarks(
        receipt.landmarks,
        default_uncertainty_ns=default_uncertainty_ns,
    )
    model = fit_weighted_affine_clock(observations)

    landmark_diagnostics = []
    for item in observations:
        predicted = model.map_float(item.device_time_ns)
        residual = float(item.session_time_ns) - predicted
        query = _query(model, item.device_time_ns)
        landmark_diagnostics.append(
            {
                "landmark_index": item.index,
                "device_time_ns": item.device_time_ns,
                "reference_time_ns": item.session_time_ns,
                "effective_uncertainty_ns": item.uncertainty_ns,
                "weighted_prediction_ns": predicted,
                "weighted_residual_ns": residual,
                "weighted_residual_ms": residual / 1e6,
                "fit_parameter_std_ns": query[
                    "fit_parameter_std_ns"
                ],
                "predictive_std_ns": query["predictive_std_ns"],
            }
        )

    analysis = {
        "schema_version": CLOCK_UNCERTAINTY_SCHEMA_VERSION,
        "source_clock_sync": {
            "schema_version": receipt.schema_version,
            "sha256": sha256_file(receipt_path),
        },
        "reference": receipt.reference.to_dict(),
        "target": receipt.target.to_dict(),
        "uncertainty_semantics": {
            "landmark_field": "uncertainty_ns",
            "interpretation": (
                "treated as one-sigma-equivalent timing uncertainty for "
                "this derived weighted analysis"
            ),
            "default_uncertainty_ns": default_uncertainty_ns,
            "missing_uncertainty_policy": (
                "fail unless an explicit positive default is supplied"
            ),
        },
        "weighted_affine": model.to_dict(),
        "landmark_diagnostics": landmark_diagnostics,
        "leave_one_out": _loo_diagnostics(observations),
        "discontinuity": _discontinuity_diagnostics(
            observations,
            model,
        ),
        "model_comparison": _piecewise_comparison(
            observations,
            model,
        ),
        "example_queries": {
            "support_start": _query(
                model,
                model.support_start_ns,
            ),
            "support_midpoint": _query(
                model,
                round(
                    (
                        model.support_start_ns
                        + model.support_end_ns
                    )
                    / 2
                ),
            ),
            "support_end": _query(
                model,
                model.support_end_ns,
            ),
        },
        "claim_boundary": (
            "This M1 analysis quantifies timing consistency and uncertainty "
            "under the declared landmark-uncertainty semantics. It does not "
            "alter the M0 clock-sync v1 receipt, prove the landmark errors "
            "are Gaussian, or establish sensor/biomechanical accuracy."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(analysis, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return analysis


def query_clock_uncertainty(
    analysis_path: str | Path,
    device_time_ns: int,
) -> dict[str, object]:
    raw = json.loads(Path(analysis_path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("clock uncertainty analysis must be a JSON object")
    if raw.get("schema_version") != CLOCK_UNCERTAINTY_SCHEMA_VERSION:
        raise ValueError("unsupported clock uncertainty schema")

    model_raw = raw.get("weighted_affine")
    if not isinstance(model_raw, dict):
        raise TypeError("weighted_affine must be an object")
    covariance = model_raw.get("covariance_at_origin")
    if not isinstance(covariance, dict):
        raise TypeError("weighted clock covariance must be an object")

    model = WeightedAffineClockModel(
        slope=float(model_raw["slope"]),
        intercept_ns=float(model_raw["intercept_ns"]),
        origin_device_time_ns=float(
            model_raw["origin_device_time_ns"]
        ),
        origin_session_time_ns=float(
            model_raw["origin_session_time_ns"]
        ),
        residual_rms_ns=float(model_raw["residual_rms_ns"]),
        reduced_chi_square=float(
            model_raw["reduced_chi_square"]
        ),
        variance_scale=float(model_raw["variance_scale"]),
        origin_variance_ns2=float(
            covariance["origin_variance_ns2"]
        ),
        origin_slope_covariance_ns=float(
            covariance["origin_slope_covariance_ns"]
        ),
        slope_variance=float(covariance["slope_variance"]),
        observations_used=int(model_raw["observations_used"]),
        support_start_ns=int(model_raw["support_start_ns"]),
        support_end_ns=int(model_raw["support_end_ns"]),
    )
    return _query(model, int(device_time_ns))
