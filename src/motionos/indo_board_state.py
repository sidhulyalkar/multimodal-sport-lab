from __future__ import annotations

import json
import math
import statistics
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path
from typing import Any

INDO_BOARD_STATE_SCHEMA_VERSION = "motionos.indo-board-state.v1"


@dataclass(frozen=True)
class BoardFrameState:
    time_s: float
    deck_angle_deg: float
    roller_position: float
    roller_perpendicular_offset: float
    confidence: float


@dataclass(frozen=True)
class RecoveryEvent:
    start_s: float
    recovered_s: float
    direction: str
    peak_excursion: float
    recovery_time_ms: float
    overshoot_ratio: float
    secondary_correction_count: int


def analyze_board_observations(
    payload: dict[str, Any],
) -> dict[str, Any]:
    frames = derive_board_state(payload)
    recoveries = detect_recoveries(frames)

    if not frames:
        return {
            "schema_version": INDO_BOARD_STATE_SCHEMA_VERSION,
            "frame_count": 0,
            "metrics": {},
            "confidence": {},
            "recoveries": [],
            "claim_boundary": _claim_boundary(),
        }

    positions = [frame.roller_position for frame in frames]
    angles = [frame.deck_angle_deg for frame in frames]
    confidences = [frame.confidence for frame in frames]

    center_time_fraction = sum(
        abs(value) <= 0.20 for value in positions
    ) / len(positions)
    near_edge_fraction = sum(
        abs(value) >= 0.75 for value in positions
    ) / len(positions)

    correction_count = _direction_change_count(frames)
    recovery_times = [
        event.recovery_time_ms for event in recoveries
    ]
    overshoots = [event.overshoot_ratio for event in recoveries]
    secondary_corrections = [
        event.secondary_correction_count for event in recoveries
    ]

    left_recovery = [
        event.recovery_time_ms
        for event in recoveries
        if event.direction == "left"
    ]
    right_recovery = [
        event.recovery_time_ms
        for event in recoveries
        if event.direction == "right"
    ]

    mean_confidence = statistics.fmean(confidences)
    evidence_factor = min(1.0, len(frames) / 120.0)
    confidence = max(
        0.0,
        min(1.0, mean_confidence * evidence_factor),
    )

    metrics: dict[str, float] = {
        "center_time_fraction": center_time_fraction,
        "near_edge_fraction": near_edge_fraction,
        "roller_excursion_p90": _percentile(
            [abs(value) for value in positions],
            0.90,
        ),
        "roller_excursion_max": max(
            abs(value) for value in positions
        ),
        "deck_angle_abs_p90_deg": _percentile(
            [abs(value) for value in angles],
            0.90,
        ),
        "correction_count": float(correction_count),
        "correction_rate_hz": correction_count
        / max(frames[-1].time_s - frames[0].time_s, 1e-6),
    }

    if recovery_times:
        metrics["recovery_time_ms"] = statistics.median(
            recovery_times
        )
    if overshoots:
        metrics["overshoot_ratio"] = statistics.median(
            overshoots
        )
    if secondary_corrections:
        metrics["secondary_correction_count"] = statistics.median(
            secondary_corrections
        )
    if left_recovery:
        metrics["left_recovery_ms"] = statistics.median(
            left_recovery
        )
    if right_recovery:
        metrics["right_recovery_ms"] = statistics.median(
            right_recovery
        )

    metric_confidence = {
        key: confidence for key in metrics
    }

    return {
        "schema_version": INDO_BOARD_STATE_SCHEMA_VERSION,
        "frame_count": len(frames),
        "metrics": metrics,
        "confidence": metric_confidence,
        "recoveries": [
            {
                "start_s": event.start_s,
                "recovered_s": event.recovered_s,
                "direction": event.direction,
                "peak_excursion": event.peak_excursion,
                "recovery_time_ms": event.recovery_time_ms,
                "overshoot_ratio": event.overshoot_ratio,
                "secondary_correction_count":
                    event.secondary_correction_count,
            }
            for event in recoveries
        ],
        "claim_boundary": _claim_boundary(),
    }


def derive_board_state(
    payload: dict[str, Any],
) -> list[BoardFrameState]:
    raw_frames = payload.get("frames")
    if not isinstance(raw_frames, list):
        raise TypeError("board observation payload requires frames")

    frames: list[BoardFrameState] = []
    for raw in raw_frames:
        if not isinstance(raw, dict):
            continue

        try:
            time_s = float(raw["time_s"])
        except (KeyError, TypeError, ValueError):
            continue
        if not math.isfinite(time_s):
            continue

        deck = raw.get("deck")
        roller = raw.get("roller")
        if not isinstance(deck, dict) or not isinstance(
            roller,
            dict,
        ):
            continue

        deck_left = _point(deck.get("left"))
        deck_right = _point(deck.get("right"))
        roller_left = _point(roller.get("left"))
        roller_right = _point(roller.get("right"))
        if None in (
            deck_left,
            deck_right,
            roller_left,
            roller_right,
        ):
            continue

        assert deck_left is not None
        assert deck_right is not None
        assert roller_left is not None
        assert roller_right is not None

        dx = deck_right[0] - deck_left[0]
        dy = deck_right[1] - deck_left[1]
        deck_length = math.hypot(dx, dy)
        if deck_length <= 1e-6:
            continue

        axis_x = dx / deck_length
        axis_y = dy / deck_length
        if axis_x < 0:
            axis_x *= -1
            axis_y *= -1

        deck_center = (
            (deck_left[0] + deck_right[0]) / 2,
            (deck_left[1] + deck_right[1]) / 2,
        )
        roller_center = (
            (roller_left[0] + roller_right[0]) / 2,
            (roller_left[1] + roller_right[1]) / 2,
        )
        relative = (
            roller_center[0] - deck_center[0],
            roller_center[1] - deck_center[1],
        )

        half_length = deck_length / 2
        along = (
            relative[0] * axis_x + relative[1] * axis_y
        ) / half_length
        perpendicular = (
            -relative[0] * axis_y + relative[1] * axis_x
        ) / half_length

        angle = math.degrees(math.atan2(axis_y, axis_x))
        if angle >= 90:
            angle -= 180
        elif angle < -90:
            angle += 180

        deck_confidence = _confidence(deck.get("confidence"))
        roller_confidence = _confidence(
            roller.get("confidence")
        )

        frames.append(
            BoardFrameState(
                time_s=time_s,
                deck_angle_deg=angle,
                roller_position=along,
                roller_perpendicular_offset=perpendicular,
                confidence=min(
                    deck_confidence,
                    roller_confidence,
                ),
            )
        )

    frames.sort(key=lambda frame: frame.time_s)

    deduped: list[BoardFrameState] = []
    for frame in frames:
        if (
            deduped
            and frame.time_s <= deduped[-1].time_s
        ):
            continue
        deduped.append(frame)
    return deduped


def detect_recoveries(
    frames: list[BoardFrameState],
    *,
    departure_threshold: float = 0.35,
    recovered_threshold: float = 0.15,
    overshoot_window_s: float = 1.0,
) -> list[RecoveryEvent]:
    events: list[RecoveryEvent] = []
    start_index: int | None = None
    peak_index: int | None = None

    for index, frame in enumerate(frames):
        position = frame.roller_position

        if start_index is None:
            if abs(position) >= departure_threshold:
                start_index = index
                peak_index = index
            continue

        assert peak_index is not None
        if abs(position) > abs(
            frames[peak_index].roller_position
        ):
            peak_index = index

        if abs(position) > recovered_threshold:
            continue

        start = frames[start_index]
        peak = frames[peak_index]
        recovered = frame
        direction = (
            "right"
            if peak.roller_position > 0
            else "left"
        )
        peak_excursion = abs(peak.roller_position)

        opposite_peak = 0.0
        post_recovery: list[BoardFrameState] = [recovered]
        for later in frames[index + 1 :]:
            if later.time_s - recovered.time_s > overshoot_window_s:
                break
            post_recovery.append(later)
            if (
                later.roller_position
                * peak.roller_position
                < 0
            ):
                opposite_peak = max(
                    opposite_peak,
                    abs(later.roller_position),
                )

        events.append(
            RecoveryEvent(
                start_s=start.time_s,
                recovered_s=recovered.time_s,
                direction=direction,
                peak_excursion=peak_excursion,
                recovery_time_ms=(
                    recovered.time_s - start.time_s
                )
                * 1000,
                overshoot_ratio=(
                    opposite_peak / peak_excursion
                    if peak_excursion > 1e-9
                    else 0.0
                ),
                secondary_correction_count=
                    _direction_change_count(post_recovery),
            )
        )

        start_index = None
        peak_index = None

    return events


def load_board_observations(
    path: str | Path,
) -> dict[str, Any]:
    payload = json.loads(
        Path(path).read_text(encoding="utf-8")
    )
    if not isinstance(payload, dict):
        raise TypeError(
            "board observation file must contain a JSON object"
        )
    return payload


def _direction_change_count(
    frames: list[BoardFrameState],
) -> int:
    signs: list[int] = []
    for first, second in pairwise(frames):
        dt = second.time_s - first.time_s
        if dt <= 0:
            continue
        speed = (
            second.roller_position - first.roller_position
        ) / dt
        if abs(speed) < 0.15:
            continue
        signs.append(1 if speed > 0 else -1)

    return sum(
        first != second
        for first, second in pairwise(signs)
    )


def _point(
    value: object,
) -> tuple[float, float] | None:
    if not isinstance(value, list) or len(value) != 2:
        return None
    try:
        x = float(value[0])
        y = float(value[1])
    except (TypeError, ValueError):
        return None
    if not math.isfinite(x) or not math.isfinite(y):
        return None
    return x, y


def _confidence(value: object) -> float:
    if not isinstance(value, (int, float)):
        return 0.5
    number = float(value)
    if not math.isfinite(number):
        return 0.0
    return min(1.0, max(0.0, number))


def _percentile(
    values: list[float],
    quantile: float,
) -> float:
    if not values:
        raise ValueError("percentile requires values")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    position = (
        len(ordered) - 1
    ) * min(1.0, max(0.0, quantile))
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return (
        ordered[lower] * (1 - fraction)
        + ordered[upper] * fraction
    )


def _claim_boundary() -> str:
    return (
        "Board-state metrics are geometric estimates derived from detected "
        "deck and roller endpoints. They become product coaching evidence "
        "only after detector accuracy and camera geometry are qualified."
    )
