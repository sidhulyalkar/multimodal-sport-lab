from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass

Vector3 = tuple[float, float, float]


@dataclass(frozen=True)
class VectorObservation:
    source_id: str
    quantity_id: str
    coordinate_frame: str
    value: Vector3
    variance: Vector3
    session_time_ns: int
    timing_uncertainty_ns: float = 0.0
    maximum_rate_per_s: Vector3 | None = None

    def __post_init__(self) -> None:
        if not self.source_id:
            raise ValueError("source_id is required")
        if not self.quantity_id:
            raise ValueError("quantity_id is required")
        if not self.coordinate_frame:
            raise ValueError("coordinate_frame is required")
        if self.session_time_ns < 0:
            raise ValueError("session_time_ns must be non-negative")
        if self.timing_uncertainty_ns < 0:
            raise ValueError("timing uncertainty must be non-negative")
        if any(
            (not math.isfinite(value) or value <= 0)
            for value in self.variance
        ):
            raise ValueError("all observation variances must be positive")
        if any(not math.isfinite(value) for value in self.value):
            raise ValueError("observation values must be finite")


@dataclass(frozen=True)
class FusedVectorEstimate:
    quantity_id: str
    coordinate_frame: str
    value: Vector3
    variance: Vector3
    session_time_ns: int
    source_ids: tuple[str, ...]
    maximum_source_time_delta_ns: int

    @property
    def standard_deviation(self) -> Vector3:
        return tuple(math.sqrt(value) for value in self.variance)  # type: ignore[return-value]


def inverse_variance_fuse(
    observations: Iterable[VectorObservation],
    *,
    maximum_source_time_delta_ms: float = 20.0,
) -> FusedVectorEstimate:
    items = tuple(observations)
    if not items:
        raise ValueError("at least one vector observation is required")

    quantity = items[0].quantity_id
    frame = items[0].coordinate_frame
    if any(item.quantity_id != quantity for item in items):
        raise ValueError("cannot fuse observations of different quantities")
    if any(item.coordinate_frame != frame for item in items):
        raise ValueError("cannot fuse observations in different frames")

    times = [item.session_time_ns for item in items]
    span_ns = max(times) - min(times)
    if span_ns / 1e6 > maximum_source_time_delta_ms:
        raise ValueError("source timing span exceeds fusion threshold")

    effective_variances: list[Vector3] = []
    for item in items:
        time_std_s = item.timing_uncertainty_ns / 1e9
        if item.maximum_rate_per_s is None:
            timing_variance = (0.0, 0.0, 0.0)
        else:
            timing_variance = tuple(
                (abs(rate) * time_std_s) ** 2
                for rate in item.maximum_rate_per_s
            )
        effective_variances.append(
            tuple(
                item.variance[axis] + timing_variance[axis]
                for axis in range(3)
            )
        )

    fused_values: list[float] = []
    fused_variances: list[float] = []
    for axis in range(3):
        weights = [
            1.0 / variance[axis]
            for variance in effective_variances
        ]
        total_weight = sum(weights)
        fused_values.append(
            sum(
                weight * item.value[axis]
                for weight, item in zip(weights, items)
            )
            / total_weight
        )
        fused_variances.append(1.0 / total_weight)

    return FusedVectorEstimate(
        quantity_id=quantity,
        coordinate_frame=frame,
        value=tuple(fused_values),  # type: ignore[arg-type]
        variance=tuple(fused_variances),  # type: ignore[arg-type]
        session_time_ns=round(sum(times) / len(times)),
        source_ids=tuple(item.source_id for item in items),
        maximum_source_time_delta_ns=span_ns,
    )



@dataclass(frozen=True)
class ScalarObservation:
    source_id: str
    quantity_id: str
    value: float
    variance: float
    session_time_ns: int
    timing_uncertainty_ns: float = 0.0
    maximum_rate_per_s: float | None = None

    def __post_init__(self) -> None:
        if not self.source_id:
            raise ValueError("source_id is required")
        if not self.quantity_id:
            raise ValueError("quantity_id is required")
        if not math.isfinite(self.value):
            raise ValueError("observation value must be finite")
        if not math.isfinite(self.variance) or self.variance <= 0:
            raise ValueError("observation variance must be positive")
        if self.session_time_ns < 0:
            raise ValueError("session_time_ns must be non-negative")
        if self.timing_uncertainty_ns < 0:
            raise ValueError("timing uncertainty must be non-negative")


@dataclass(frozen=True)
class FusedScalarEstimate:
    quantity_id: str
    value: float
    variance: float
    session_time_ns: int
    source_ids: tuple[str, ...]
    maximum_source_time_delta_ns: int

    @property
    def standard_deviation(self) -> float:
        return math.sqrt(self.variance)


def inverse_variance_fuse_scalar(
    observations: Iterable[ScalarObservation],
    *,
    maximum_source_time_delta_ms: float = 20.0,
) -> FusedScalarEstimate:
    items = tuple(observations)
    if not items:
        raise ValueError("at least one scalar observation is required")

    quantity = items[0].quantity_id
    if any(item.quantity_id != quantity for item in items):
        raise ValueError(
            "cannot fuse scalar observations of different quantities"
        )

    times = [item.session_time_ns for item in items]
    span_ns = max(times) - min(times)
    if span_ns / 1e6 > maximum_source_time_delta_ms:
        raise ValueError("source timing span exceeds fusion threshold")

    effective_variances: list[float] = []
    for item in items:
        timing_variance = 0.0
        if item.maximum_rate_per_s is not None:
            time_std_s = item.timing_uncertainty_ns / 1e9
            timing_variance = (
                abs(item.maximum_rate_per_s) * time_std_s
            ) ** 2
        effective_variances.append(
            item.variance + timing_variance
        )

    weights = [1.0 / variance for variance in effective_variances]
    total_weight = sum(weights)
    value = sum(
        weight * item.value
        for weight, item in zip(weights, items, strict=True)
    ) / total_weight

    return FusedScalarEstimate(
        quantity_id=quantity,
        value=value,
        variance=1.0 / total_weight,
        session_time_ns=round(sum(times) / len(times)),
        source_ids=tuple(item.source_id for item in items),
        maximum_source_time_delta_ns=span_ns,
    )
