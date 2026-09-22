from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class ClockObservation:
    """One device/session clock correspondence from a coordinator probe.

    device_time_ns and session_time_ns should represent the estimated midpoint
    of the same exchange. round_trip_ns is used to down-select low-jitter probes.
    """

    device_time_ns: int
    session_time_ns: int
    round_trip_ns: int


@dataclass(frozen=True)
class ClockModel:
    """Affine mapping from device monotonic time into session monotonic time."""

    slope: float
    intercept_ns: float
    residual_rms_ns: float
    observations_used: int

    def map(self, device_time_ns: int) -> int:
        return round(self.slope * device_time_ns + self.intercept_ns)

    @property
    def drift_ppm(self) -> float:
        return (self.slope - 1.0) * 1_000_000.0

    @property
    def quality(self) -> float:
        residual_factor = 1.0 / (1.0 + self.residual_rms_ns / 1_000_000.0)
        count_factor = min(1.0, self.observations_used / 8.0)
        return max(0.0, min(1.0, residual_factor * count_factor))


def _linear_fit(xs: list[int], ys: list[int]) -> tuple[float, float, float]:
    if len(xs) != len(ys) or len(xs) < 2:
        raise ValueError("at least two paired observations are required")

    x0 = xs[0]
    y0 = ys[0]
    x = [float(v - x0) for v in xs]
    y = [float(v - y0) for v in ys]
    mean_x = sum(x) / len(x)
    mean_y = sum(y) / len(y)
    denom = sum((value - mean_x) ** 2 for value in x)
    if denom == 0:
        raise ValueError("device timestamps must span time")
    slope = sum((a - mean_x) * (b - mean_y) for a, b in zip(x, y)) / denom
    local_intercept = mean_y - slope * mean_x
    intercept = y0 + local_intercept - slope * x0
    residuals = [b - (slope * a + local_intercept) for a, b in zip(x, y)]
    rms = math.sqrt(sum(value * value for value in residuals) / len(residuals))
    return slope, intercept, rms


def estimate_clock_model(
    observations: list[ClockObservation],
    *,
    keep_fraction: float = 0.6,
    prune_residual_outliers: bool = True,
) -> ClockModel:
    """Estimate an affine device→session mapping.

    RTT-style coordinator probes keep the historical low-jitter/outlier
    pruning behavior by default. Deliberate physical landmarks can disable
    residual pruning so every predeclared correspondence remains in the fit.
    """

    if len(observations) < 3:
        raise ValueError("at least three clock observations are required")
    if not 0.25 <= keep_fraction <= 1.0:
        raise ValueError("keep_fraction must be between 0.25 and 1.0")

    ordered = sorted(observations, key=lambda item: item.round_trip_ns)
    keep = max(3, math.ceil(len(ordered) * keep_fraction))
    selected = sorted(ordered[:keep], key=lambda item: item.device_time_ns)

    slope, intercept, _ = _linear_fit(
        [item.device_time_ns for item in selected],
        [item.session_time_ns for item in selected],
    )

    residual_pairs = [
        (abs(item.session_time_ns - (slope * item.device_time_ns + intercept)), item)
        for item in selected
    ]
    if prune_residual_outliers and len(residual_pairs) >= 5:
        residual_pairs.sort(key=lambda item: item[0])
        selected = sorted(
            [item for _, item in residual_pairs[: max(3, int(len(residual_pairs) * 0.8))]],
            key=lambda item: item.device_time_ns,
        )

    slope, intercept, rms = _linear_fit(
        [item.device_time_ns for item in selected],
        [item.session_time_ns for item in selected],
    )
    return ClockModel(
        slope=slope,
        intercept_ns=intercept,
        residual_rms_ns=rms,
        observations_used=len(selected),
    )
