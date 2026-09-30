from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .provenance import session_evidence_sha256
from .qc import inspect_stream
from .session import SessionReader

WATCH_SMOKE_REQUIRED_STREAMS = {
    "/body/watch/imu",
    "/meta/watch",
}


@dataclass(frozen=True)
class WatchSmokeReport:
    smoke_ok: bool
    session_id: str
    bundle_sha256: str
    min_duration_s: float
    rate_tolerance_fraction: float
    require_hr: bool
    missing_core_streams: tuple[str, ...]
    imu_count: int
    imu_duration_s: float
    imu_effective_hz: float
    imu_median_dt_ms: float | None
    imu_max_gap_ms: float | None
    imu_missing_sequences: int
    imu_non_monotonic_timestamps: int
    requested_imu_hz: float | None
    imu_rate_ok: bool
    heart_rate_observed: bool
    hr_count: int
    hr_missing_sequences: int
    hr_non_monotonic_timestamps: int

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "watch-smoke-v1",
            "smoke_ok": self.smoke_ok,
            "session_id": self.session_id,
            "bundle_sha256": self.bundle_sha256,
            "minimum_smoke_duration_s": self.min_duration_s,
            "rate_tolerance_fraction": self.rate_tolerance_fraction,
            "require_hr": self.require_hr,
            "missing_core_streams": list(self.missing_core_streams),
            "watch_imu": {
                "count": self.imu_count,
                "duration_s": self.imu_duration_s,
                "effective_hz": self.imu_effective_hz,
                "median_dt_ms": self.imu_median_dt_ms,
                "max_gap_ms": self.imu_max_gap_ms,
                "missing_sequences": self.imu_missing_sequences,
                "non_monotonic_timestamps": self.imu_non_monotonic_timestamps,
                "requested_hz": self.requested_imu_hz,
                "rate_ok": self.imu_rate_ok,
            },
            "watch_hr": {
                "observed": self.heart_rate_observed,
                "count": self.hr_count,
                "missing_sequences": self.hr_missing_sequences,
                "non_monotonic_timestamps": self.hr_non_monotonic_timestamps,
            },
            "claim_boundary": (
                "This is a non-qualifying Watch first-light smoke report. "
                "It checks capture plumbing and timing continuity only. It is not a "
                "P0 qualification receipt and does not qualify physiological accuracy, "
                "cross-device synchronization, biomechanics, pose, or equipment sensing."
            ),
        }


def build_watch_smoke_report(
    reader: SessionReader,
    *,
    min_duration_s: float = 30.0,
    rate_tolerance_fraction: float = 0.25,
    require_hr: bool = False,
) -> WatchSmokeReport:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")
    if not 0 <= rate_tolerance_fraction < 1:
        raise ValueError("rate_tolerance_fraction must be in [0, 1)")

    available = set(reader.list_streams())
    missing = tuple(sorted(WATCH_SMOKE_REQUIRED_STREAMS - available))

    imu_events = list(reader.iter_stream("/body/watch/imu"))
    hr_events = list(reader.iter_stream("/body/watch/hr"))
    imu_qc = inspect_stream("/body/watch/imu", imu_events)
    hr_qc = inspect_stream("/body/watch/hr", hr_events)

    watch_capture = dict(reader.manifest.metadata.get("watch_capture", {}))
    requested_imu_hz = (
        float(watch_capture["requested_imu_hz"])
        if watch_capture.get("requested_imu_hz") is not None
        else None
    )

    imu_rate_ok = False
    if requested_imu_hz is not None and requested_imu_hz > 0:
        lower = requested_imu_hz * (1.0 - rate_tolerance_fraction)
        upper = requested_imu_hz * (1.0 + rate_tolerance_fraction)
        imu_rate_ok = lower <= imu_qc.effective_hz <= upper

    heart_rate_observed = hr_qc.count >= 1
    hr_integrity_ok = (
        heart_rate_observed
        and hr_qc.missing_sequences == 0
        and hr_qc.non_monotonic_timestamps == 0
    )

    imu_integrity_ok = (
        imu_qc.count >= 100
        and imu_qc.duration_s >= min_duration_s
        and imu_qc.missing_sequences == 0
        and imu_qc.non_monotonic_timestamps == 0
        and imu_rate_ok
    )

    smoke_ok = (
        not missing
        and imu_integrity_ok
        and (hr_integrity_ok if require_hr else True)
    )

    return WatchSmokeReport(
        smoke_ok=smoke_ok,
        session_id=reader.manifest.session_id,
        bundle_sha256=session_evidence_sha256(reader),
        min_duration_s=min_duration_s,
        rate_tolerance_fraction=rate_tolerance_fraction,
        require_hr=require_hr,
        missing_core_streams=missing,
        imu_count=imu_qc.count,
        imu_duration_s=imu_qc.duration_s,
        imu_effective_hz=imu_qc.effective_hz,
        imu_median_dt_ms=imu_qc.median_dt_ms,
        imu_max_gap_ms=imu_qc.max_gap_ms,
        imu_missing_sequences=imu_qc.missing_sequences,
        imu_non_monotonic_timestamps=imu_qc.non_monotonic_timestamps,
        requested_imu_hz=requested_imu_hz,
        imu_rate_ok=imu_rate_ok,
        heart_rate_observed=heart_rate_observed,
        hr_count=hr_qc.count,
        hr_missing_sequences=hr_qc.missing_sequences,
        hr_non_monotonic_timestamps=hr_qc.non_monotonic_timestamps,
    )


def write_watch_smoke_report(
    session_dir: str | Path,
    output_path: str | Path,
    *,
    min_duration_s: float = 30.0,
    rate_tolerance_fraction: float = 0.25,
    require_hr: bool = False,
) -> WatchSmokeReport:
    report = build_watch_smoke_report(
        SessionReader(session_dir),
        min_duration_s=min_duration_s,
        rate_tolerance_fraction=rate_tolerance_fraction,
        require_hr=require_hr,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report
