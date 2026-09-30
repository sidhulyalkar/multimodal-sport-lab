from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from itertools import pairwise
from statistics import median
from collections.abc import Iterable


@dataclass(frozen=True)
class IndoBoardSample:
    time_s: float
    com_x_m: float
    com_y_m: float
    com_z_m: float
    board_roll_deg: float
    board_pitch_deg: float
    left_knee_flexion_deg: float | None = None
    right_knee_flexion_deg: float | None = None
    pose_confidence: float = 1.0
    timing_uncertainty_ms: float = 0.0
    reprojection_rms_px: float = 0.0


@dataclass(frozen=True)
class MetricEstimate:
    metric_id: str
    value: float | None
    unit: str
    direction: str
    confidence: float
    definition: str
    unavailable_reason: str | None = None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class IndoBoardReport:
    schema_version: str
    session_id: str
    sample_count: int
    accepted_sample_count: int
    rejected_sample_count: int
    metrics: tuple[MetricEstimate, ...]
    claim_boundary: str

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "session_id": self.session_id,
            "sample_count": self.sample_count,
            "accepted_sample_count": self.accepted_sample_count,
            "rejected_sample_count": self.rejected_sample_count,
            "metrics": [metric.to_dict() for metric in self.metrics],
            "claim_boundary": self.claim_boundary,
        }


@dataclass
class LongitudinalBaseline:
    metric_id: str
    direction: str
    sample_count: int = 0
    mean: float = 0.0
    m2: float = 0.0
    best_value: float | None = None
    latest_value: float | None = None

    @property
    def sample_standard_deviation(self) -> float | None:
        if self.sample_count < 2:
            return None
        return math.sqrt(self.m2 / (self.sample_count - 1))

    def observe(self, value: float) -> None:
        if not math.isfinite(value):
            return
        self.sample_count += 1
        delta = value - self.mean
        self.mean += delta / self.sample_count
        delta2 = value - self.mean
        self.m2 += delta * delta2
        self.latest_value = value

        if self.best_value is None:
            self.best_value = value
        elif self.direction == "lower_is_better":
            self.best_value = min(self.best_value, value)
        elif self.direction == "higher_is_better":
            self.best_value = max(self.best_value, value)


def analyze_indo_board(
    samples: Iterable[IndoBoardSample],
    *,
    session_id: str,
    minimum_pose_confidence: float = 0.6,
    maximum_timing_uncertainty_ms: float = 20.0,
    maximum_reprojection_rms_px: float = 3.0,
    disturbance_threshold_deg: float = 8.0,
    recovered_board_threshold_deg: float = 3.0,
    recovered_com_radius_m: float = 0.04,
    recovery_hold_s: float = 0.5,
) -> IndoBoardReport:
    if not session_id.strip():
        raise ValueError("session_id is required")
    all_samples = tuple(sorted(samples, key=lambda sample: sample.time_s))
    if len(all_samples) < 3:
        raise ValueError("Indo Board analysis requires at least three samples")
    if any(
        later.time_s <= earlier.time_s
        for earlier, later in pairwise(all_samples)
    ):
        raise ValueError("Indo Board sample times must be strictly increasing")

    accepted = tuple(
        sample
        for sample in all_samples
        if sample.pose_confidence >= minimum_pose_confidence
        and sample.timing_uncertainty_ms <= maximum_timing_uncertainty_ms
        and sample.reprojection_rms_px <= maximum_reprojection_rms_px
    )
    if len(accepted) < 3:
        raise ValueError("too few samples pass Indo Board quality gates")

    quality_fraction = len(accepted) / len(all_samples)
    median_confidence = median(sample.pose_confidence for sample in accepted)
    confidence = min(1.0, quality_fraction * median_confidence)

    center_x = median(sample.com_x_m for sample in accepted)
    center_z = median(sample.com_z_m for sample in accepted)
    radii = [
        math.hypot(sample.com_x_m - center_x, sample.com_z_m - center_z)
        for sample in accepted
    ]
    stability = math.sqrt(sum(radius * radius for radius in radii) / len(radii))
    excursion = _percentile(radii, 0.95)
    smoothness = _board_jerk_rms(accepted)
    recovery_latency = _recovery_latency(
        accepted,
        center_x=center_x,
        center_z=center_z,
        disturbance_threshold_deg=disturbance_threshold_deg,
        recovered_board_threshold_deg=recovered_board_threshold_deg,
        recovered_com_radius_m=recovered_com_radius_m,
        recovery_hold_s=recovery_hold_s,
    )

    asymmetry_values = [
        abs(sample.left_knee_flexion_deg - sample.right_knee_flexion_deg)
        for sample in accepted
        if sample.left_knee_flexion_deg is not None
        and sample.right_knee_flexion_deg is not None
    ]
    stance_asymmetry = (
        sum(asymmetry_values) / len(asymmetry_values)
        if asymmetry_values
        else None
    )

    metrics = (
        MetricEstimate(
            metric_id="balance_stability_rms_m",
            value=stability,
            unit="m",
            direction="lower_is_better",
            confidence=confidence,
            definition=(
                "RMS horizontal center-of-mass displacement from the session "
                "median over quality-gated samples."
            ),
        ),
        MetricEstimate(
            metric_id="com_excursion_p95_m",
            value=excursion,
            unit="m",
            direction="lower_is_better",
            confidence=confidence,
            definition=(
                "95th percentile horizontal center-of-mass displacement from "
                "the session median."
            ),
        ),
        MetricEstimate(
            metric_id="board_control_jerk_rms_deg_s3",
            value=smoothness,
            unit="deg/s^3",
            direction="lower_is_better",
            confidence=confidence,
            definition=(
                "RMS third time derivative of board roll/pitch; lower values "
                "indicate smoother board control for comparable tasks."
            ),
        ),
        MetricEstimate(
            metric_id="recovery_latency_median_s",
            value=recovery_latency,
            unit="s",
            direction="lower_is_better",
            confidence=confidence if recovery_latency is not None else 0.0,
            definition=(
                "Median time from a board-tilt disturbance to a sustained "
                "return inside board-angle and COM recovery bands."
            ),
            unavailable_reason=(
                None
                if recovery_latency is not None
                else "no complete disturbance/recovery episode was observed"
            ),
        ),
        MetricEstimate(
            metric_id="stance_asymmetry_mean_abs_knee_deg",
            value=stance_asymmetry,
            unit="deg",
            direction="descriptive",
            confidence=confidence if stance_asymmetry is not None else 0.0,
            definition=(
                "Mean absolute left/right knee-flexion difference. This is a "
                "geometric stance proxy, not a force or muscle-activation measure."
            ),
            unavailable_reason=(
                None
                if stance_asymmetry is not None
                else "bilateral knee flexion was not available"
            ),
        ),
    )

    return IndoBoardReport(
        schema_version="motionos.indo-board-report.v1",
        session_id=session_id,
        sample_count=len(all_samples),
        accepted_sample_count=len(accepted),
        rejected_sample_count=len(all_samples) - len(accepted),
        metrics=metrics,
        claim_boundary=(
            "These metrics are derived biomechanics estimates. RGB video does "
            "not directly measure muscle activation, muscle mass, or ground "
            "reaction force; those require additional sensing or validated models."
        ),
    )


def update_longitudinal_baselines(
    baselines: dict[str, LongitudinalBaseline],
    report: IndoBoardReport,
) -> dict[str, LongitudinalBaseline]:
    updated = dict(baselines)
    for metric in report.metrics:
        if metric.value is None:
            continue
        baseline = updated.get(metric.metric_id)
        if baseline is None:
            baseline = LongitudinalBaseline(
                metric_id=metric.metric_id,
                direction=metric.direction,
            )
            updated[metric.metric_id] = baseline
        baseline.observe(metric.value)
    return updated


def _board_tilt_deg(sample: IndoBoardSample) -> float:
    return math.hypot(sample.board_roll_deg, sample.board_pitch_deg)


def _board_jerk_rms(samples: tuple[IndoBoardSample, ...]) -> float:
    if len(samples) < 4:
        return 0.0

    velocities: list[tuple[float, float, float]] = []
    for first, second in pairwise(samples):
        dt = second.time_s - first.time_s
        velocities.append(
            (
                (first.time_s + second.time_s) / 2,
                (second.board_roll_deg - first.board_roll_deg) / dt,
                (second.board_pitch_deg - first.board_pitch_deg) / dt,
            )
        )

    accelerations: list[tuple[float, float, float]] = []
    for first, second in pairwise(velocities):
        dt = second[0] - first[0]
        accelerations.append(
            (
                (first[0] + second[0]) / 2,
                (second[1] - first[1]) / dt,
                (second[2] - first[2]) / dt,
            )
        )

    jerks: list[float] = []
    for first, second in pairwise(accelerations):
        dt = second[0] - first[0]
        roll_jerk = (second[1] - first[1]) / dt
        pitch_jerk = (second[2] - first[2]) / dt
        jerks.append(math.hypot(roll_jerk, pitch_jerk))

    if not jerks:
        return 0.0
    return math.sqrt(sum(value * value for value in jerks) / len(jerks))


def _recovery_latency(
    samples: tuple[IndoBoardSample, ...],
    *,
    center_x: float,
    center_z: float,
    disturbance_threshold_deg: float,
    recovered_board_threshold_deg: float,
    recovered_com_radius_m: float,
    recovery_hold_s: float,
) -> float | None:
    latencies: list[float] = []
    index = 0
    while index < len(samples):
        if _board_tilt_deg(samples[index]) < disturbance_threshold_deg:
            index += 1
            continue

        onset = samples[index].time_s
        candidate = index + 1
        found = False
        while candidate < len(samples):
            sample = samples[candidate]
            com_radius = math.hypot(
                sample.com_x_m - center_x,
                sample.com_z_m - center_z,
            )
            if (
                _board_tilt_deg(sample) <= recovered_board_threshold_deg
                and com_radius <= recovered_com_radius_m
            ):
                hold_start = sample.time_s
                hold_index = candidate
                while hold_index < len(samples):
                    held = samples[hold_index]
                    held_radius = math.hypot(
                        held.com_x_m - center_x,
                        held.com_z_m - center_z,
                    )
                    if (
                        _board_tilt_deg(held) > recovered_board_threshold_deg
                        or held_radius > recovered_com_radius_m
                    ):
                        break
                    if held.time_s - hold_start >= recovery_hold_s:
                        latencies.append(hold_start - onset)
                        index = hold_index + 1
                        found = True
                        break
                    hold_index += 1
                if found:
                    break
            candidate += 1

        if not found:
            index += 1

    return median(latencies) if latencies else None


def _percentile(values: list[float], quantile: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = quantile * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight
