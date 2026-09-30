from __future__ import annotations

import itertools
import json
import math
from dataclasses import dataclass
from pathlib import Path

from .clock import ClockModel, ClockObservation, estimate_clock_model
from .pose2d_io import (
    load_pose2d_journal,
    load_unmapped_pose2d_journal,
)
from .vision_contract import VisionObservation, VisionSessionManifest


@dataclass(frozen=True)
class MotionPeak:
    time_ns: int
    score: float

    def to_dict(self) -> dict[str, float | int]:
        return {
            "time_ns": self.time_ns,
            "score": self.score,
        }


@dataclass(frozen=True)
class ExternalCameraSyncResult:
    model: ClockModel
    cue_host_times_ns: tuple[int, ...]
    iphone_impulse_peaks: tuple[MotionPeak, ...]
    external_impulse_peaks: tuple[MotionPeak, ...]
    candidate_count: int

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": "motionos.external-camera-sync.v1",
            "clock_model": {
                "slope": self.model.slope,
                "intercept_ns": self.model.intercept_ns,
                "residual_rms_ns": self.model.residual_rms_ns,
                "residual_rms_ms": self.model.residual_rms_ns / 1e6,
                "observations_used": self.model.observations_used,
                "drift_ppm": self.model.drift_ppm,
            },
            "cue_host_times_ns": list(self.cue_host_times_ns),
            "iphone_impulse_peaks": [
                peak.to_dict() for peak in self.iphone_impulse_peaks
            ],
            "external_impulse_peaks": [
                peak.to_dict() for peak in self.external_impulse_peaks
            ],
            "external_candidate_count": self.candidate_count,
            "claim_boundary": (
                "The external camera clock is fit from repeated physical "
                "whole-body impulse peaks detected in 2D pose. The cue only "
                "defines a search window on the host-timed iPhone stream; "
                "human response latency is not used as the cross-camera offset."
            ),
        }


def estimate_external_camera_clock(
    iphone_observations: tuple[VisionObservation, ...],
    external_observations: tuple[VisionObservation, ...],
    cue_host_times_ns: tuple[int, ...],
    *,
    minimum_joint_confidence: float = 0.6,
    cue_search_before_ms: float = 250.0,
    cue_search_after_ms: float = 2500.0,
    minimum_peak_separation_ms: float = 500.0,
    maximum_candidates: int = 12,
    maximum_abs_drift_ppm: float = 5000.0,
    maximum_residual_ms: float = 150.0,
) -> ExternalCameraSyncResult:
    if len(cue_host_times_ns) < 3:
        raise ValueError(
            "external camera synchronization requires at least three cues"
        )
    if tuple(sorted(cue_host_times_ns)) != cue_host_times_ns:
        raise ValueError("cue host times must be strictly chronological")
    if maximum_candidates < len(cue_host_times_ns):
        raise ValueError(
            "maximum_candidates must cover every synchronization cue"
        )

    iphone_series = _motion_series(
        iphone_observations,
        use_mapped_time=True,
        minimum_joint_confidence=minimum_joint_confidence,
    )
    external_series = _motion_series(
        external_observations,
        use_mapped_time=False,
        minimum_joint_confidence=minimum_joint_confidence,
    )

    iphone_peaks = _peaks_near_cues(
        iphone_series,
        cue_host_times_ns,
        search_before_ns=round(cue_search_before_ms * 1e6),
        search_after_ns=round(cue_search_after_ms * 1e6),
    )

    external_candidates = _candidate_peaks(
        external_series,
        minimum_separation_ns=round(
            minimum_peak_separation_ms * 1e6
        ),
        maximum_candidates=maximum_candidates,
    )
    cue_count = len(cue_host_times_ns)
    if len(external_candidates) < cue_count:
        raise ValueError(
            "too few external-camera motion peaks for synchronization"
        )

    energy_rank = {
        peak.time_ns: rank
        for rank, peak in enumerate(
            sorted(
                external_candidates,
                key=lambda peak: peak.score,
                reverse=True,
            )
        )
    }

    best: tuple[float, ClockModel, tuple[MotionPeak, ...]] | None = None
    for candidate_group in itertools.combinations(
        sorted(external_candidates, key=lambda peak: peak.time_ns),
        cue_count,
    ):
        observations = [
            ClockObservation(
                device_time_ns=external_peak.time_ns,
                session_time_ns=iphone_peak.time_ns,
                round_trip_ns=1,
            )
            for external_peak, iphone_peak in zip(
                candidate_group,
                iphone_peaks,
                strict=True,
            )
        ]
        try:
            model = estimate_clock_model(
                observations,
                keep_fraction=1.0,
                prune_residual_outliers=False,
            )
        except ValueError:
            continue
        if abs(model.drift_ppm) > maximum_abs_drift_ppm:
            continue

        mean_rank = sum(
            energy_rank[peak.time_ns]
            for peak in candidate_group
        ) / len(candidate_group)
        score = model.residual_rms_ns / 1e6 + 0.05 * mean_rank
        if best is None or score < best[0]:
            best = (score, model, tuple(candidate_group))

    if best is None:
        raise ValueError(
            "no plausible affine external-camera clock fit was found"
        )

    _score, model, selected = best
    if model.residual_rms_ns / 1e6 > maximum_residual_ms:
        raise ValueError(
            "external-camera physical-landmark residual exceeds threshold"
        )

    return ExternalCameraSyncResult(
        model=model,
        cue_host_times_ns=cue_host_times_ns,
        iphone_impulse_peaks=iphone_peaks,
        external_impulse_peaks=selected,
        candidate_count=len(external_candidates),
    )


def write_external_camera_sync(
    vision_session_path: str | Path,
    iphone_pose_journal_path: str | Path,
    external_pose_journal_path: str | Path,
    output_path: str | Path,
    *,
    iphone_source_id: str = "iphone-rear",
    external_source_id: str = "dji-action4",
) -> ExternalCameraSyncResult:
    manifest_raw = json.loads(
        Path(vision_session_path).read_text(encoding="utf-8")
    )
    if not isinstance(manifest_raw, dict):
        raise TypeError("vision session manifest must be an object")
    manifest = VisionSessionManifest.from_dict(manifest_raw)
    cue_times = tuple(
        landmark.host_monotonic_time_ns
        for landmark in manifest.sync_landmarks
        if landmark.kind == "whole_body_impulse"
    )

    iphone = load_pose2d_journal(
        iphone_pose_journal_path,
        source_id=iphone_source_id,
    )
    external = load_unmapped_pose2d_journal(
        external_pose_journal_path,
        source_id=external_source_id,
    )
    result = estimate_external_camera_clock(
        iphone.observations,
        external,
        cue_times,
    )

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _motion_series(
    observations: tuple[VisionObservation, ...],
    *,
    use_mapped_time: bool,
    minimum_joint_confidence: float,
) -> tuple[MotionPeak, ...]:
    values: list[MotionPeak] = []
    for first, second in itertools.pairwise(observations):
        if use_mapped_time:
            if (
                first.mapped_session_time_ns is None
                or second.mapped_session_time_ns is None
            ):
                raise ValueError(
                    "host-timed motion series requires mapped session time"
                )
            first_time = int(first.mapped_session_time_ns)
            second_time = int(second.mapped_session_time_ns)
        else:
            first_time = first.frame_source_time_ns
            second_time = second.frame_source_time_ns

        dt_ns = second_time - first_time
        if dt_ns <= 0:
            continue
        dt_s = dt_ns / 1e9

        speeds: list[float] = []
        for joint_name in first.joints.keys() & second.joints.keys():
            a = first.joints[joint_name]
            b = second.joints[joint_name]
            if (
                a.confidence < minimum_joint_confidence
                or b.confidence < minimum_joint_confidence
            ):
                continue
            speeds.append(
                math.hypot(b.x - a.x, b.y - a.y) / dt_s
            )
        if not speeds:
            continue

        speeds.sort(reverse=True)
        top_count = max(1, math.ceil(len(speeds) * 0.35))
        selected = speeds[:top_count]
        score = math.sqrt(
            sum(value * value for value in selected)
            / len(selected)
        )
        values.append(
            MotionPeak(
                time_ns=round((first_time + second_time) / 2),
                score=score,
            )
        )
    if not values:
        raise ValueError("pose observations contain no usable motion series")
    return tuple(values)


def _peaks_near_cues(
    series: tuple[MotionPeak, ...],
    cue_times_ns: tuple[int, ...],
    *,
    search_before_ns: int,
    search_after_ns: int,
) -> tuple[MotionPeak, ...]:
    selected: list[MotionPeak] = []
    used_times: set[int] = set()
    for cue_time in cue_times_ns:
        candidates = [
            item
            for item in series
            if cue_time - search_before_ns
            <= item.time_ns
            <= cue_time + search_after_ns
            and item.time_ns not in used_times
        ]
        if not candidates:
            raise ValueError(
                "no iPhone pose-motion peak was found near a sync cue"
            )
        peak = max(candidates, key=lambda item: item.score)
        selected.append(peak)
        used_times.add(peak.time_ns)

    if any(
        later.time_ns <= earlier.time_ns
        for earlier, later in itertools.pairwise(selected)
    ):
        raise ValueError(
            "detected iPhone impulse peaks are not chronological"
        )
    return tuple(selected)


def _candidate_peaks(
    series: tuple[MotionPeak, ...],
    *,
    minimum_separation_ns: int,
    maximum_candidates: int,
) -> tuple[MotionPeak, ...]:
    local: list[MotionPeak] = []
    for index, item in enumerate(series):
        previous_score = (
            series[index - 1].score
            if index > 0
            else -math.inf
        )
        next_score = (
            series[index + 1].score
            if index + 1 < len(series)
            else -math.inf
        )
        if item.score >= previous_score and item.score >= next_score:
            local.append(item)

    selected: list[MotionPeak] = []
    for candidate in sorted(
        local,
        key=lambda item: item.score,
        reverse=True,
    ):
        if all(
            abs(candidate.time_ns - existing.time_ns)
            >= minimum_separation_ns
            for existing in selected
        ):
            selected.append(candidate)
        if len(selected) >= maximum_candidates:
            break
    return tuple(sorted(selected, key=lambda item: item.time_ns))
