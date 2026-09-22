from __future__ import annotations

import statistics
from dataclasses import asdict, dataclass
from itertools import pairwise

from .schema import SensorEvent
from .session import SessionReader


@dataclass(frozen=True)
class StreamQC:
    stream: str
    count: int
    duration_s: float
    effective_hz: float
    median_dt_ms: float | None
    max_gap_ms: float | None
    missing_sequences: int
    non_monotonic_timestamps: int
    mean_sync_quality: float | None

    @property
    def passed(self) -> bool:
        return self.count > 0 and self.non_monotonic_timestamps == 0

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["passed"] = self.passed
        return data


def inspect_stream(stream: str, events: list[SensorEvent]) -> StreamQC:
    if not events:
        return StreamQC(stream, 0, 0.0, 0.0, None, None, 0, 0, None)
    times = [event.canonical_time_ns for event in events]
    diffs = [b - a for a, b in pairwise(times)]
    positive = [value for value in diffs if value > 0]
    duration_ns = max(0, times[-1] - times[0])
    duration_s = duration_ns / 1e9
    effective_hz = (len(events) - 1) / duration_s if duration_s > 0 else 0.0
    missing = 0
    for prev, current in pairwise(events):
        if current.sequence > prev.sequence + 1:
            missing += current.sequence - prev.sequence - 1
    quality = [event.sync_quality for event in events if event.sync_quality is not None]
    return StreamQC(
        stream=stream,
        count=len(events),
        duration_s=duration_s,
        effective_hz=effective_hz,
        median_dt_ms=(statistics.median(positive) / 1e6 if positive else None),
        max_gap_ms=(max(positive) / 1e6 if positive else None),
        missing_sequences=missing,
        non_monotonic_timestamps=sum(1 for value in diffs if value <= 0),
        mean_sync_quality=(sum(quality) / len(quality) if quality else None),
    )


def session_qc(reader: SessionReader) -> dict[str, object]:
    reports = {
        stream: inspect_stream(stream, list(reader.iter_stream(stream)))
        for stream in reader.list_streams()
    }
    return {
        "session_id": reader.manifest.session_id,
        "schema_version": reader.manifest.schema_version,
        "passed": all(report.passed for report in reports.values()),
        "streams": {stream: report.to_dict() for stream, report in reports.items()},
    }
