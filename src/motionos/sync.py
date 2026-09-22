from __future__ import annotations

import math
from collections.abc import Iterable

from .schema import SensorEvent


def _magnitude(event: SensorEvent, keys: tuple[str, str, str] = ("ax", "ay", "az")) -> float:
    try:
        x, y, z = (float(event.payload[key]) for key in keys)
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"event {event.stream} does not contain numeric {keys}") from exc
    return math.sqrt(x * x + y * y + z * z)


def estimate_impulse_lag_ns(
    reference: Iterable[SensorEvent],
    target: Iterable[SensorEvent],
    *,
    search_start_ns: int | None = None,
    search_end_ns: int | None = None,
) -> int:
    """Estimate target-reference lag from a deliberate shared impulse."""

    def peak(events: Iterable[SensorEvent]) -> SensorEvent:
        candidates = [
            event
            for event in events
            if (search_start_ns is None or event.canonical_time_ns >= search_start_ns)
            and (search_end_ns is None or event.canonical_time_ns <= search_end_ns)
        ]
        if not candidates:
            raise ValueError("no events in synchronization search window")
        return max(candidates, key=_magnitude)

    ref = peak(reference)
    other = peak(target)
    return other.canonical_time_ns - ref.canonical_time_ns


def nearest_event(
    events: Iterable[SensorEvent], target_time_ns: int, *, tolerance_ns: int
) -> SensorEvent | None:
    best: SensorEvent | None = None
    best_distance = tolerance_ns + 1
    for event in events:
        distance = abs(event.canonical_time_ns - target_time_ns)
        if distance < best_distance:
            best = event
            best_distance = distance
    return best if best_distance <= tolerance_ns else None
