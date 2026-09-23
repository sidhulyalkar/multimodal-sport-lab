from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .provenance import session_evidence_sha256, sha256_file
from .qc import inspect_stream
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionReader, SessionWriter

P0_REQUIRED_STREAMS = {
    "/body/watch/imu",
    "/body/watch/hr",
    "/meta/watch",
}


def import_watch_journal(
    journal_path: str | Path,
    out_root: str | Path,
) -> Path:
    journal = Path(journal_path)
    events: list[SensorEvent] = []

    with journal.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                events.append(SensorEvent.from_json(line))
            except Exception as exc:
                raise ValueError(
                    f"invalid SensorEvent at {journal}:{line_number}"
                ) from exc

    if not events:
        raise ValueError("watch journal contains no events")

    session_ids = {event.session_id for event in events}
    if len(session_ids) != 1:
        raise ValueError(f"watch journal contains multiple session IDs: {sorted(session_ids)}")

    device_ids = {event.device_id for event in events}
    if len(device_ids) != 1:
        raise ValueError(f"watch journal contains multiple device IDs: {sorted(device_ids)}")

    streams = tuple(sorted({event.stream for event in events}))
    session_id = next(iter(session_ids))
    device_id = next(iter(device_ids))

    watch_metadata_events = [
        event for event in events if event.stream == "/meta/watch"
    ]
    watch_metadata = (
        dict(watch_metadata_events[0].payload)
        if watch_metadata_events
        else {}
    )

    host_metadata_path = journal.with_name("iphone-host.json")
    source_evidence_sha256 = {
        "watch_journal": sha256_file(journal),
    }
    iphone_host_metadata: dict[str, object] = {}
    if host_metadata_path.exists():
        source_evidence_sha256["iphone_host_metadata"] = sha256_file(
            host_metadata_path
        )
        raw_host_metadata = json.loads(
            host_metadata_path.read_text(encoding="utf-8")
        )
        if isinstance(raw_host_metadata, dict):
            iphone_host_metadata = dict(raw_host_metadata)

    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="watch-qualification",
        mode="field",
        athlete_id="local-athlete",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="apple_watch",
                placement="wrist",
                streams=streams,
                model=(
                    str(watch_metadata["model"])
                    if watch_metadata.get("model") is not None
                    else None
                ),
                firmware=(
                    str(watch_metadata["system_version"])
                    if watch_metadata.get("system_version") is not None
                    else None
                ),
            ),
        ),
        metadata={
            "qualification_protocol": "P0",
            "source_journal": journal.name,
            "cross_device_sync_qualified": False,
            "watch_capture": watch_metadata,
            "iphone_host": iphone_host_metadata,
            "source_evidence_sha256": source_evidence_sha256,
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            events,
            key=lambda item: (item.canonical_time_ns, item.stream, item.sequence),
        ):
            writer.append(event)

        writer.write_metadata(
            "p0_import",
            {
                "source_path": str(journal),
                "event_count": len(events),
                "streams": list(streams),
                "source_evidence_sha256": source_evidence_sha256,
            },
        )

    return Path(out_root) / session_id


@dataclass(frozen=True)
class P0Receipt:
    passed: bool
    session_id: str
    bundle_sha256: str
    min_duration_s: float
    missing_streams: tuple[str, ...]
    imu_count: int
    imu_duration_s: float
    imu_effective_hz: float
    imu_median_dt_ms: float | None
    imu_max_gap_ms: float | None
    imu_missing_sequences: int
    imu_non_monotonic_timestamps: int
    hr_count: int
    hr_duration_s: float
    hr_median_dt_ms: float | None
    hr_max_gap_ms: float | None
    hr_missing_sequences: int
    hr_non_monotonic_timestamps: int
    mapped_session_time_samples: int
    raw_device_time_samples: int
    watch_model: str | None
    watch_system_version: str | None
    requested_imu_hz: float | None
    iphone_model: str | None
    iphone_system_version: str | None
    missing_environment_fields: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "P0",
            "passed": self.passed,
            "session_id": self.session_id,
            "bundle_sha256": self.bundle_sha256,
            "minimum_required_duration_s": self.min_duration_s,
            "missing_streams": list(self.missing_streams),
            "watch_imu": {
                "count": self.imu_count,
                "duration_s": self.imu_duration_s,
                "effective_hz": self.imu_effective_hz,
                "median_dt_ms": self.imu_median_dt_ms,
                "max_gap_ms": self.imu_max_gap_ms,
                "missing_sequences": self.imu_missing_sequences,
                "non_monotonic_timestamps": self.imu_non_monotonic_timestamps,
            },
            "watch_hr": {
                "count": self.hr_count,
                "duration_s": self.hr_duration_s,
                "median_dt_ms": self.hr_median_dt_ms,
                "max_gap_ms": self.hr_max_gap_ms,
                "missing_sequences": self.hr_missing_sequences,
                "non_monotonic_timestamps": self.hr_non_monotonic_timestamps,
            },
            "time_basis": {
                "mapped_session_time_samples": self.mapped_session_time_samples,
                "raw_device_time_samples": self.raw_device_time_samples,
            },
            "environment": {
                "watch_model": self.watch_model,
                "watch_system_version": self.watch_system_version,
                "requested_imu_hz": self.requested_imu_hz,
                "iphone_model": self.iphone_model,
                "iphone_system_version": self.iphone_system_version,
                "missing_fields": list(self.missing_environment_fields),
            },
            "claim_boundary": (
                "P0 qualifies single-Watch capture continuity and journal recovery only. "
                "It does not qualify cross-device synchronization, physiological accuracy, "
                "pose accuracy, or equipment sensing."
            ),
        }


def build_p0_receipt(
    reader: SessionReader,
    *,
    min_duration_s: float = 60.0,
) -> P0Receipt:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")

    available = set(reader.list_streams())
    missing = tuple(sorted(P0_REQUIRED_STREAMS - available))

    imu_events = list(reader.iter_stream("/body/watch/imu"))
    hr_events = list(reader.iter_stream("/body/watch/hr"))
    imu_qc = inspect_stream("/body/watch/imu", imu_events)
    hr_qc = inspect_stream("/body/watch/hr", hr_events)

    all_events = imu_events + hr_events
    mapped = sum(event.session_time_ns is not None for event in all_events)
    raw = len(all_events) - mapped

    watch_capture = dict(reader.manifest.metadata.get("watch_capture", {}))
    iphone_host = dict(reader.manifest.metadata.get("iphone_host", {}))

    watch_model = (
        str(watch_capture["model"])
        if watch_capture.get("model") is not None
        else None
    )
    watch_system_version = (
        str(watch_capture["system_version"])
        if watch_capture.get("system_version") is not None
        else None
    )
    requested_imu_hz = (
        float(watch_capture["requested_imu_hz"])
        if watch_capture.get("requested_imu_hz") is not None
        else None
    )
    iphone_model = (
        str(iphone_host["iphone_model"])
        if iphone_host.get("iphone_model") is not None
        else None
    )
    iphone_system_version = (
        str(iphone_host["iphone_system_version"])
        if iphone_host.get("iphone_system_version") is not None
        else None
    )

    required_environment = {
        "watch_model": watch_model,
        "watch_system_version": watch_system_version,
        "requested_imu_hz": requested_imu_hz,
        "iphone_system_version": iphone_system_version,
    }
    missing_environment = tuple(
        sorted(
            key
            for key, value in required_environment.items()
            if value is None
        )
    )

    passed = (
        not missing
        and not missing_environment
        and imu_qc.count >= 100
        and imu_qc.duration_s >= min_duration_s
        and imu_qc.missing_sequences == 0
        and imu_qc.non_monotonic_timestamps == 0
        and hr_qc.count >= 1
        and hr_qc.missing_sequences == 0
        and hr_qc.non_monotonic_timestamps == 0
    )

    return P0Receipt(
        passed=passed,
        session_id=reader.manifest.session_id,
        bundle_sha256=session_evidence_sha256(reader),
        min_duration_s=min_duration_s,
        missing_streams=missing,
        imu_count=imu_qc.count,
        imu_duration_s=imu_qc.duration_s,
        imu_effective_hz=imu_qc.effective_hz,
        imu_median_dt_ms=imu_qc.median_dt_ms,
        imu_max_gap_ms=imu_qc.max_gap_ms,
        imu_missing_sequences=imu_qc.missing_sequences,
        imu_non_monotonic_timestamps=imu_qc.non_monotonic_timestamps,
        hr_count=hr_qc.count,
        hr_duration_s=hr_qc.duration_s,
        hr_median_dt_ms=hr_qc.median_dt_ms,
        hr_max_gap_ms=hr_qc.max_gap_ms,
        hr_missing_sequences=hr_qc.missing_sequences,
        hr_non_monotonic_timestamps=hr_qc.non_monotonic_timestamps,
        mapped_session_time_samples=mapped,
        raw_device_time_samples=raw,
        watch_model=watch_model,
        watch_system_version=watch_system_version,
        requested_imu_hz=requested_imu_hz,
        iphone_model=iphone_model,
        iphone_system_version=iphone_system_version,
        missing_environment_fields=missing_environment,
    )


def write_p0_receipt(
    session_dir: str | Path,
    output_path: str | Path,
    *,
    min_duration_s: float = 60.0,
) -> P0Receipt:
    receipt = build_p0_receipt(
        SessionReader(session_dir),
        min_duration_s=min_duration_s,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
