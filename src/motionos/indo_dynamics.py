"""Gap-aware, time-weighted Indo Board motion analysis.

This is an *image-space* kinematics probe, not a measure of COM, muscle
activation, reaction time, or balance skill. Every output is descriptive.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path
from typing import Sequence

from .indo_board_state import BoardFrameState, derive_board_state

SCHEMA_VERSION = "motionos.indo-dynamics.v1"


@dataclass(frozen=True)
class DynamicsConfig:
    min_confidence: float = 0.65
    max_gap_s: float = 0.25
    min_coverage: float = 0.70
    min_exposure_s: float = 5.0
    min_frames: int = 20
    departure: float = 0.35
    center: float = 0.15
    settle_dwell_s: float = 0.30

    def validate(self) -> None:
        if not (0 <= self.min_confidence <= 1 and 0 <= self.min_coverage <= 1):
            raise ValueError("confidence and coverage thresholds must be in [0, 1]")
        if not (0 < self.center < self.departure <= 1):
            raise ValueError("require 0 < center < departure <= 1")
        if min(self.max_gap_s, self.min_exposure_s, self.settle_dwell_s) <= 0:
            raise ValueError("time thresholds must be positive")
        if self.min_frames < 2:
            raise ValueError("min_frames must be at least two")


def _segments(
    frames: Sequence[BoardFrameState], cfg: DynamicsConfig
) -> tuple[list[list[BoardFrameState]], int]:
    segments: list[list[BoardFrameState]] = []
    current: list[BoardFrameState] = []
    valid_count = 0
    previous_time: float | None = None
    for frame in frames:
        if previous_time is not None and frame.time_s <= previous_time:
            raise ValueError("board frames must have strictly increasing timestamps")
        previous_time = frame.time_s
        valid = (
            all(math.isfinite(v) for v in (frame.time_s, frame.roller_position, frame.confidence))
            and frame.confidence >= cfg.min_confidence
        )
        if not valid:
            if current:
                segments.append(current)
            current = []
            continue
        valid_count += 1
        if current and frame.time_s - current[-1].time_s > cfg.max_gap_s:
            segments.append(current)
            current = []
        current.append(frame)
    if current:
        segments.append(current)
    return segments, valid_count


def _episodes(segments: list[list[BoardFrameState]], cfg: DynamicsConfig) -> list[dict]:
    episodes: list[dict] = []
    for segment in segments:
        active: dict | None = None
        settle_start: float | None = None
        for earlier, current in pairwise(segment):
            if active is None:
                if abs(earlier.roller_position) < cfg.departure <= abs(current.roller_position):
                    active = {
                        "start_s": current.time_s,
                        "direction": "right" if current.roller_position > 0 else "left",
                        "peak_abs_position": abs(current.roller_position),
                    }
                continue
            active["peak_abs_position"] = max(
                active["peak_abs_position"], abs(current.roller_position)
            )
            if abs(current.roller_position) <= cfg.center:
                if settle_start is None:
                    settle_start = current.time_s
                if current.time_s - settle_start >= cfg.settle_dwell_s:
                    episodes.append({
                        **active,
                        "status": "settled",
                        "end_s": current.time_s,
                        "settle_latency_s": current.time_s - active["start_s"],
                    })
                    active = None
                    settle_start = None
            else:
                settle_start = None
        if active is not None:
            episodes.append({
                **active,
                "status": "censored",
                "end_s": segment[-1].time_s,
                "censor_reason": "segment_end_or_tracking_gap",
            })
    return episodes


def analyze_indo_dynamics(
    frames: Sequence[BoardFrameState],
    *,
    config: DynamicsConfig = DynamicsConfig(),
) -> dict:
    """Return descriptive motion features, or abstain on insufficient exposure.

    A tracking gap breaks every dynamic calculation and censors active events.
    Zero-duration samples never contribute to time fractions or rate metrics.
    """
    config.validate()
    segments, valid_count = _segments(frames, config)
    span_s = max(0.0, frames[-1].time_s - frames[0].time_s) if frames else 0.0
    intervals = [
        (a, b, b.time_s - a.time_s)
        for segment in segments
        for a, b in pairwise(segment)
    ]
    exposure_s = sum(dt for _, _, dt in intervals)
    coverage = exposure_s / span_s if span_s > 0 else 0.0
    reasons = []
    if valid_count < config.min_frames:
        reasons.append("too_few_qualified_frames")
    if exposure_s < config.min_exposure_s:
        reasons.append("too_little_observed_time")
    if coverage < config.min_coverage:
        reasons.append("tracking_coverage_below_threshold")
    report = {
        "schema_version": SCHEMA_VERSION,
        "status": "insufficient_evidence" if reasons else "descriptive_only",
        "abstention_reasons": reasons,
        "quality": {
            "input_frame_count": len(frames),
            "qualified_frame_count": valid_count,
            "contiguous_segment_count": len(segments),
            "recording_span_s": round(span_s, 6),
            "observed_exposure_s": round(exposure_s, 6),
            "observed_fraction": round(coverage, 6),
        },
        "config": vars(config).copy(),
        "metrics": {},
        "episodes": [],
        "claim_boundary": (
            "Image-space deck-relative roller motion only. Settling time is not human "
            "reaction latency. No ground-reaction forces, muscle activation, center "
            "of mass, technique quality, clinical inference, or causal benefit inferred."
        ),
    }
    if reasons:
        return report

    center_s = sum(
        dt * (float(abs(a.roller_position) <= 0.20) + float(abs(b.roller_position) <= 0.20)) / 2
        for a, b, dt in intervals
    )
    edge_s = sum(
        dt * (float(abs(a.roller_position) >= 0.75) + float(abs(b.roller_position) >= 0.75)) / 2
        for a, b, dt in intervals
    )
    total_sq_change_per_s = sum(
        ((b.roller_position - a.roller_position) ** 2) / dt
        for a, b, dt in intervals
    )
    episodes = _episodes(segments, config)
    settled = [event for event in episodes if event["status"] == "settled"]
    metrics = {
        "center_time_fraction": center_s / exposure_s,
        "edge_time_fraction": edge_s / exposure_s,
        "roller_speed_rms_per_s": math.sqrt(total_sq_change_per_s / exposure_s),
        "excursion_event_rate_per_min": len(episodes) * 60 / exposure_s,
        "settled_event_fraction": len(settled) / len(episodes) if episodes else None,
    }
    # Avoid presenting a singleton event as a stable personal recovery statistic.
    if len(settled) >= 3:
        metrics["median_settling_time_s"] = statistics.median(
            event["settle_latency_s"] for event in settled
        )
    for direction in ("left", "right"):
        side = [event["settle_latency_s"] for event in settled if event["direction"] == direction]
        if len(side) >= 3:
            metrics[f"{direction}_median_settling_time_s"] = statistics.median(side)
    report["metrics"] = metrics
    report["episodes"] = episodes
    report["event_counts"] = {
        "total": len(episodes),
        "settled": len(settled),
        "censored": len(episodes) - len(settled),
    }
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit gap-aware Indo Board dynamics")
    parser.add_argument("observations", type=Path, help="Board observations JSON with frames")
    parser.add_argument("output", type=Path, help="Derived, versioned report JSON")
    args = parser.parse_args(argv)
    try:
        source = args.observations.read_bytes()
        payload = json.loads(source)
        if not isinstance(payload, dict):
            raise ValueError("board observations must contain a JSON object")
        report = analyze_indo_dynamics(derive_board_state(payload))
        report["source_sha256"] = hashlib.sha256(source).hexdigest()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n")
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, f"motionos-balance-study: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
