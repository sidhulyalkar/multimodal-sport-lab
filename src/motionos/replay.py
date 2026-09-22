from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

from .schema import SensorEvent
from .session import SessionReader


@dataclass(frozen=True)
class ReplayFrame:
    time_ns: int
    latest: dict[str, SensorEvent]


def replay_frames(reader: SessionReader, *, frame_hz: float = 30.0) -> Iterator[ReplayFrame]:
    if frame_hz <= 0:
        raise ValueError("frame_hz must be positive")
    events = list(reader.iter_events())
    if not events:
        return
    start = events[0].canonical_time_ns
    end = events[-1].canonical_time_ns
    step = int(1_000_000_000 / frame_hz)
    cursor = 0
    latest: dict[str, SensorEvent] = {}
    time_ns = start
    while time_ns <= end:
        while cursor < len(events) and events[cursor].canonical_time_ns <= time_ns:
            event = events[cursor]
            latest[event.stream] = event
            cursor += 1
        yield ReplayFrame(time_ns=time_ns, latest=dict(latest))
        time_ns += step
