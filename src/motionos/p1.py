from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from itertools import pairwise
from pathlib import Path

from .clock import ClockModel, ClockObservation, estimate_clock_model
from .clock_sync import (
    clock_observations_from_json,
    derive_clock_sync,
    write_clock_sync,
)
from .equipment import EquipmentProfile, load_equipment_profile
from .equipment_adapter import (
    ACCEL_STREAM,
    GYRO_STREAM,
    canonicalize_equipment_imu,
)
from .qc import StreamQC, inspect_stream
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionReader, SessionWriter

P1_REQUIRED_STREAMS = {ACCEL_STREAM, GYRO_STREAM}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def derive_impulse_clock_observations(
    reference_reader: SessionReader,
    pod_reader: SessionReader,
    windows: list[dict[str, object]],
    *,
    reference_stream: str = "/body/watch/imu",
    pod_stream: str = ACCEL_STREAM,
) -> list[ClockObservation]:
    """Compatibility wrapper over generic deliberate-landmark synchronization."""

    receipt = derive_clock_sync(
        reference_reader,
        pod_reader,
        windows,
        reference_stream=reference_stream,
        target_stream=pod_stream,
        allow_legacy_pod_windows=True,
    )
    return list(receipt.observations)


def write_impulse_clock_observations(
    reference_session: str | Path,
    pod_session: str | Path,
    windows_path: str | Path,
    output_path: str | Path,
    *,
    reference_stream: str = "/body/watch/imu",
    pod_stream: str = ACCEL_STREAM,
) -> list[ClockObservation]:
    """Write the generic receipt while preserving the legacy P1 return type."""

    receipt = write_clock_sync(
        reference_session,
        pod_session,
        windows_path,
        output_path,
        reference_stream=reference_stream,
        target_stream=pod_stream,
        allow_legacy_pod_windows=True,
    )
    return list(receipt.observations)


def import_pod_journal(
    journal_path: str | Path,
    out_root: str | Path,
    *,
    equipment_profile_path: str | Path | None = None,
    sport: str = "equipment-qualification",
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
        raise ValueError("pod journal contains no events")

    session_ids = {event.session_id for event in events}
    if len(session_ids) != 1:
        raise ValueError(
            f"pod journal contains multiple session IDs: {sorted(session_ids)}"
        )
    device_ids = {event.device_id for event in events}
    if len(device_ids) != 1:
        raise ValueError(
            f"pod journal contains multiple device IDs: {sorted(device_ids)}"
        )

    session_id = next(iter(session_ids))
    device_id = next(iter(device_ids))
    streams = tuple(sorted({event.stream for event in events}))

    metadata_path = journal.with_name("pod-metadata.json")
    evidence_sha256: dict[str, str] = {
        "pod_journal": _sha256_file(journal),
    }
    if metadata_path.exists():
        evidence_sha256["pod_metadata"] = _sha256_file(metadata_path)

    pod_metadata: dict[str, object] = {}
    if metadata_path.exists():
        raw = json.loads(metadata_path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise TypeError("pod-metadata.json must contain an object")
        pod_metadata = dict(raw)

    profile: EquipmentProfile | None = None
    if equipment_profile_path is not None:
        profile_path = Path(equipment_profile_path)
        evidence_sha256["equipment_profile"] = _sha256_file(profile_path)
        profile = load_equipment_profile(profile_path)
        events = [
            (
                canonicalize_equipment_imu(event, profile)
                if event.stream in P1_REQUIRED_STREAMS
                else event
            )
            for event in events
        ]

    device_meta = pod_metadata.get("device")
    device_dict = device_meta if isinstance(device_meta, dict) else {}

    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport=sport,
        mode="field",
        athlete_id="local-athlete",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="metamotion_s",
                placement=(
                    f"{profile.equipment_type}:{profile.mount_id}"
                    if profile is not None
                    else "equipment"
                ),
                streams=streams,
                model=(
                    str(device_dict["model"])
                    if device_dict.get("model") is not None
                    else None
                ),
                firmware=(
                    str(device_dict["firmware_revision"])
                    if device_dict.get("firmware_revision") is not None
                    else None
                ),
            ),
        ),
        metadata={
            "qualification_protocol": "P1",
            "source_journal": journal.name,
            "source_metadata": metadata_path.name if metadata_path.exists() else None,
            "pod_capture": pod_metadata,
            "equipment_profile": profile.to_dict() if profile is not None else None,
            "cross_device_sync_qualified": False,
            "source_evidence_sha256": evidence_sha256,
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            events,
            key=lambda item: (
                item.canonical_time_ns,
                item.stream,
                item.sequence,
            ),
        ):
            writer.append(event)

        writer.write_metadata(
            "p1_import",
            {
                "source_path": str(journal),
                "metadata_path": (
                    str(metadata_path) if metadata_path.exists() else None
                ),
                "event_count": len(events),
                "streams": list(streams),
                "equipment_profile_path": (
                    str(equipment_profile_path)
                    if equipment_profile_path is not None
                    else None
                ),
                "source_evidence_sha256": evidence_sha256,
            },
        )

    return Path(out_root) / session_id


@dataclass(frozen=True)
class TickGapReport:
    expected_interval_ms: float | None
    gaps_over_1_5x: int
    estimated_missing_samples: int
    max_gap_multiple: float | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class P1Receipt:
    session_id: str
    capture_passed: bool
    timing_gate_frozen: bool
    timing_passed: bool
    sync_gate_frozen: bool
    sync_passed: bool
    passed: bool
    min_duration_s: float
    missing_streams: tuple[str, ...]
    missing_metadata_fields: tuple[str, ...]
    metadata_mismatches: tuple[str, ...]
    invalid_accel_payloads: int
    invalid_gyro_payloads: int
    accel_qc: StreamQC
    gyro_qc: StreamQC
    accel_tick_gaps: TickGapReport
    gyro_tick_gaps: TickGapReport
    requested_accel_hz: float | None
    requested_gyro_hz: float | None
    configured_rate_tolerance_fraction: float | None
    configured_max_gap_multiple: float | None
    clock_model: ClockModel | None
    configured_max_sync_residual_ms: float | None
    sync_landmark_coverage_passed: bool
    sync_observation_count: int
    sync_observation_span_s: float | None
    sync_observation_span_fraction: float | None
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "P1",
            "session_id": self.session_id,
            "capture_passed": self.capture_passed,
            "timing_gate": {
                "frozen": self.timing_gate_frozen,
                "passed": self.timing_passed,
                "rate_tolerance_fraction": (
                    self.configured_rate_tolerance_fraction
                ),
                "max_gap_multiple": self.configured_max_gap_multiple,
            },
            "sync_gate": {
                "frozen": self.sync_gate_frozen,
                "passed": self.sync_passed,
                "max_residual_ms": self.configured_max_sync_residual_ms,
                "landmark_coverage_passed": (
                    self.sync_landmark_coverage_passed
                ),
                "observation_count": self.sync_observation_count,
                "observation_span_s": self.sync_observation_span_s,
                "observation_span_fraction": (
                    self.sync_observation_span_fraction
                ),
                "coverage_protocol": (
                    "first landmark <=20%, middle landmark 30-70%, "
                    "last landmark >=80% of pod capture"
                ),
            },
            "passed": self.passed,
            "minimum_required_duration_s": self.min_duration_s,
            "missing_streams": list(self.missing_streams),
            "missing_metadata_fields": list(self.missing_metadata_fields),
            "metadata_mismatches": list(self.metadata_mismatches),
            "payload_contract": {
                "invalid_accelerometer_samples": self.invalid_accel_payloads,
                "invalid_gyroscope_samples": self.invalid_gyro_payloads,
                "timestamp_authority": "device_tick_ms",
                "sequence_authority": "export_order_only",
                "dropout_authority": "device_tick_spacing",
            },
            "source_evidence_sha256": dict(self.source_evidence_sha256),
            "requested_rates_hz": {
                "accelerometer": self.requested_accel_hz,
                "gyroscope": self.requested_gyro_hz,
            },
            "accelerometer": {
                "qc": self.accel_qc.to_dict(),
                "tick_gaps": self.accel_tick_gaps.to_dict(),
            },
            "gyroscope": {
                "qc": self.gyro_qc.to_dict(),
                "tick_gaps": self.gyro_tick_gaps.to_dict(),
            },
            "clock_model": (
                {
                    "slope": self.clock_model.slope,
                    "intercept_ns": self.clock_model.intercept_ns,
                    "drift_ppm": self.clock_model.drift_ppm,
                    "residual_rms_ns": self.clock_model.residual_rms_ns,
                    "residual_rms_ms": self.clock_model.residual_rms_ns / 1e6,
                    "observations_used": self.clock_model.observations_used,
                    "quality": self.clock_model.quality,
                }
                if self.clock_model is not None
                else None
            ),
            "claim_boundary": (
                "capture_passed qualifies durable pod-local evidence only. "
                "passed=true additionally requires predeclared rate/gap and "
                "cross-device synchronization gates."
            ),
        }


def _requested_rates(
    metadata: dict[str, object],
) -> tuple[float | None, float | None]:
    raw = metadata.get("requested_capture")
    capture = raw if isinstance(raw, dict) else {}

    accel = capture.get("accelerometer_hz")
    gyro = capture.get("gyroscope_hz")

    def parse(value: object) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    return parse(accel), parse(gyro)


def _tick_gap_report(
    events: list[SensorEvent],
    requested_hz: float | None,
) -> TickGapReport:
    if requested_hz is None or requested_hz <= 0 or len(events) < 2:
        return TickGapReport(None, 0, 0, None)

    expected_ns = 1e9 / requested_hz
    diffs = [
        current.device_time_ns - previous.device_time_ns
        for previous, current in pairwise(events)
        if current.device_time_ns > previous.device_time_ns
    ]
    if not diffs:
        return TickGapReport(
            expected_interval_ms=expected_ns / 1e6,
            gaps_over_1_5x=0,
            estimated_missing_samples=0,
            max_gap_multiple=None,
        )

    large = [gap for gap in diffs if gap > 1.5 * expected_ns]
    estimated_missing = sum(
        max(1, round(gap / expected_ns) - 1)
        for gap in large
    )
    return TickGapReport(
        expected_interval_ms=expected_ns / 1e6,
        gaps_over_1_5x=len(large),
        estimated_missing_samples=estimated_missing,
        max_gap_multiple=max(diffs) / expected_ns,
    )


def _read_sync_observations(
    path: str | Path | None,
) -> list[ClockObservation]:
    return clock_observations_from_json(path)


def _payload_contract_error_count(
    events: list[SensorEvent],
    *,
    vector_keys: tuple[str, str, str],
    expected_units: str,
    expected_sensor: str,
) -> int:
    invalid = 0
    for event in events:
        try:
            for key in vector_keys:
                float(event.payload[key])
        except (KeyError, TypeError, ValueError):
            invalid += 1
            continue

        if event.payload.get("timestamp_basis") != "device_tick_ms":
            invalid += 1
            continue
        if event.payload.get("units") != expected_units:
            invalid += 1
            continue
        if event.payload.get("sensor") != expected_sensor:
            invalid += 1
            continue
        if event.payload.get("source") != "metamotion_s_bmi270_flash":
            invalid += 1
    return invalid


def _metadata_contract(
    *,
    session_id: str,
    pod_capture: dict[str, object],
    accel_count: int,
    gyro_count: int,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    device_raw = pod_capture.get("device")
    device = device_raw if isinstance(device_raw, dict) else {}
    recovered_raw = pod_capture.get("recovered_samples")
    recovered = recovered_raw if isinstance(recovered_raw, dict) else {}

    requested_accel_hz, requested_gyro_hz = _requested_rates(pod_capture)

    required_metadata = {
        "schema_version": pod_capture.get("schema_version"),
        "session_id": pod_capture.get("session_id"),
        "device.model": device.get("model"),
        "device.model_number": device.get("model_number"),
        "device.firmware_revision": device.get("firmware_revision"),
        "device.hardware_revision": device.get("hardware_revision"),
        "device.metawear_sdk_revision": device.get("metawear_sdk_revision"),
        "requested_capture.accelerometer_hz": requested_accel_hz,
        "requested_capture.accelerometer_range_g": (
            pod_capture.get("requested_capture", {}).get("accelerometer_range_g")
            if isinstance(pod_capture.get("requested_capture"), dict)
            else None
        ),
        "requested_capture.gyroscope_hz": requested_gyro_hz,
        "requested_capture.gyroscope_range_dps": (
            pod_capture.get("requested_capture", {}).get("gyroscope_range_dps")
            if isinstance(pod_capture.get("requested_capture"), dict)
            else None
        ),
        "recovered_samples.accelerometer": recovered.get("accelerometer"),
        "recovered_samples.gyroscope": recovered.get("gyroscope"),
        "timestamp_authority": pod_capture.get("timestamp_authority"),
        "live_preview_timestamp_authority": pod_capture.get(
            "live_preview_timestamp_authority"
        ),
        "streams": pod_capture.get("streams"),
        "flash_clear_policy": pod_capture.get(
            "flash_cleared_only_after_successful_dual_download"
        ),
    }
    missing = tuple(
        sorted(
            key
            for key, value in required_metadata.items()
            if value is None
        )
    )

    expected = {
        "schema_version": "motionos.p1.pod.v1",
        "session_id": session_id,
        "device.model": "MetaMotion S",
        "device.model_number": "8",
        "device.hardware_revision": "r0.1",
        "device.metawear_sdk_revision": (
            "7dd2a5dbddafb2f8d583cb8d018be476d8ee9a71"
        ),
        "timestamp_authority": "device_tick_ms",
        "flash_clear_policy": True,
        "recovered_samples.accelerometer": accel_count,
        "recovered_samples.gyroscope": gyro_count,
    }

    actual = {
        "schema_version": pod_capture.get("schema_version"),
        "session_id": pod_capture.get("session_id"),
        "device.model": device.get("model"),
        "device.model_number": device.get("model_number"),
        "device.hardware_revision": device.get("hardware_revision"),
        "device.metawear_sdk_revision": device.get("metawear_sdk_revision"),
        "timestamp_authority": pod_capture.get("timestamp_authority"),
        "flash_clear_policy": pod_capture.get(
            "flash_cleared_only_after_successful_dual_download"
        ),
        "recovered_samples.accelerometer": recovered.get("accelerometer"),
        "recovered_samples.gyroscope": recovered.get("gyroscope"),
    }

    mismatch_set = {
        key
        for key, expected_value in expected.items()
        if actual.get(key) is not None
        and actual.get(key) != expected_value
    }

    if requested_accel_hz is not None and requested_accel_hz <= 0:
        mismatch_set.add("requested_capture.accelerometer_hz")
    if requested_gyro_hz is not None and requested_gyro_hz <= 0:
        mismatch_set.add("requested_capture.gyroscope_hz")

    capture_raw = pod_capture.get("requested_capture")
    capture = capture_raw if isinstance(capture_raw, dict) else {}
    for key in ("accelerometer_range_g", "gyroscope_range_dps"):
        value = capture.get(key)
        if value is not None:
            try:
                if float(value) <= 0:
                    mismatch_set.add(f"requested_capture.{key}")
            except (TypeError, ValueError):
                mismatch_set.add(f"requested_capture.{key}")

    streams = pod_capture.get("streams")
    if (
        streams is not None
        and (
            not isinstance(streams, list)
            or set(map(str, streams)) != P1_REQUIRED_STREAMS
        )
    ):
        mismatch_set.add("streams")

    live_authority = pod_capture.get("live_preview_timestamp_authority")
    if (
        live_authority is not None
        and live_authority != "ble_host_arrival_only"
    ):
        mismatch_set.add("live_preview_timestamp_authority")

    mismatches = tuple(sorted(mismatch_set))
    return missing, mismatches


def _sync_landmark_coverage(
    observations: list[ClockObservation],
    pod_events: list[SensorEvent],
) -> tuple[bool, float | None, float | None]:
    if len(observations) < 3 or len(pod_events) < 2:
        return False, None, None

    pod_start = pod_events[0].device_time_ns
    pod_end = pod_events[-1].device_time_ns
    pod_span = pod_end - pod_start
    if pod_span <= 0:
        return False, None, None

    ordered = sorted(
        observation.device_time_ns
        for observation in observations
    )
    normalized = [
        (value - pod_start) / pod_span
        for value in ordered
    ]
    observation_span = ordered[-1] - ordered[0]
    coverage = observation_span / pod_span

    positions_in_range = all(0.0 <= value <= 1.0 for value in normalized)
    start_ok = normalized[0] <= 0.20
    end_ok = normalized[-1] >= 0.80
    middle_ok = any(0.30 <= value <= 0.70 for value in normalized[1:-1])
    return (
        positions_in_range and start_ok and middle_ok and end_ok,
        observation_span / 1e9,
        coverage,
    )


def build_p1_receipt(
    reader: SessionReader,
    *,
    min_duration_s: float = 60.0,
    rate_tolerance_fraction: float | None = None,
    max_gap_multiple: float | None = None,
    sync_observations: list[ClockObservation] | None = None,
    max_sync_residual_ms: float | None = None,
) -> P1Receipt:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")
    if rate_tolerance_fraction is not None and rate_tolerance_fraction <= 0:
        raise ValueError("rate_tolerance_fraction must be positive")
    if max_gap_multiple is not None and max_gap_multiple <= 1:
        raise ValueError("max_gap_multiple must be greater than 1")
    if max_sync_residual_ms is not None and max_sync_residual_ms <= 0:
        raise ValueError("max_sync_residual_ms must be positive")

    available = set(reader.list_streams())
    missing_streams = tuple(sorted(P1_REQUIRED_STREAMS - available))
    accel_events = list(reader.iter_stream(ACCEL_STREAM))
    gyro_events = list(reader.iter_stream(GYRO_STREAM))
    accel_qc = inspect_stream(ACCEL_STREAM, accel_events)
    gyro_qc = inspect_stream(GYRO_STREAM, gyro_events)

    pod_capture_raw = reader.manifest.metadata.get("pod_capture")
    pod_capture = (
        pod_capture_raw if isinstance(pod_capture_raw, dict) else {}
    )
    evidence_hashes_raw = reader.manifest.metadata.get(
        "source_evidence_sha256"
    )
    source_evidence_sha256 = (
        {
            str(key): str(value)
            for key, value in evidence_hashes_raw.items()
        }
        if isinstance(evidence_hashes_raw, dict)
        else {}
    )
    requested_accel_hz, requested_gyro_hz = _requested_rates(pod_capture)
    missing_metadata, metadata_mismatches = _metadata_contract(
        session_id=reader.manifest.session_id,
        pod_capture=pod_capture,
        accel_count=len(accel_events),
        gyro_count=len(gyro_events),
    )

    invalid_accel_payloads = _payload_contract_error_count(
        accel_events,
        vector_keys=("ax", "ay", "az"),
        expected_units="m/s^2",
        expected_sensor="accelerometer",
    )
    invalid_gyro_payloads = _payload_contract_error_count(
        gyro_events,
        vector_keys=("gx", "gy", "gz"),
        expected_units="rad/s",
        expected_sensor="gyroscope",
    )

    accel_gaps = _tick_gap_report(accel_events, requested_accel_hz)
    gyro_gaps = _tick_gap_report(gyro_events, requested_gyro_hz)

    capture_passed = (
        not missing_streams
        and not missing_metadata
        and not metadata_mismatches
        and "pod_journal" in source_evidence_sha256
        and "pod_metadata" in source_evidence_sha256
        and invalid_accel_payloads == 0
        and invalid_gyro_payloads == 0
        and accel_qc.count >= 2
        and gyro_qc.count >= 2
        and accel_qc.duration_s >= min_duration_s
        and gyro_qc.duration_s >= min_duration_s
        and accel_qc.non_monotonic_timestamps == 0
        and gyro_qc.non_monotonic_timestamps == 0
    )

    timing_gate_frozen = (
        rate_tolerance_fraction is not None
        and max_gap_multiple is not None
        and requested_accel_hz is not None
        and requested_gyro_hz is not None
        and requested_accel_hz > 0
        and requested_gyro_hz > 0
    )

    timing_passed = False
    if timing_gate_frozen:
        assert rate_tolerance_fraction is not None
        assert max_gap_multiple is not None
        assert requested_accel_hz is not None
        assert requested_gyro_hz is not None

        rate_ok = (
            abs(accel_qc.effective_hz - requested_accel_hz)
            / requested_accel_hz
            <= rate_tolerance_fraction
            and abs(gyro_qc.effective_hz - requested_gyro_hz)
            / requested_gyro_hz
            <= rate_tolerance_fraction
        )
        gap_ok = (
            accel_gaps.max_gap_multiple is not None
            and gyro_gaps.max_gap_multiple is not None
            and accel_gaps.max_gap_multiple <= max_gap_multiple
            and gyro_gaps.max_gap_multiple <= max_gap_multiple
        )
        timing_passed = rate_ok and gap_ok

    observations = sync_observations or []
    clock_model = (
        estimate_clock_model(
            observations,
            keep_fraction=1.0,
            prune_residual_outliers=False,
        )
        if len(observations) >= 3
        else None
    )
    (
        sync_landmark_coverage_passed,
        sync_observation_span_s,
        sync_observation_span_fraction,
    ) = _sync_landmark_coverage(observations, accel_events)

    sync_gate_frozen = (
        max_sync_residual_ms is not None
        and clock_model is not None
    )
    sync_passed = (
        sync_gate_frozen
        and sync_landmark_coverage_passed
        and clock_model is not None
        and max_sync_residual_ms is not None
        and clock_model.residual_rms_ns / 1e6 <= max_sync_residual_ms
    )

    passed = (
        capture_passed
        and timing_gate_frozen
        and timing_passed
        and sync_gate_frozen
        and sync_passed
    )

    return P1Receipt(
        session_id=reader.manifest.session_id,
        capture_passed=capture_passed,
        timing_gate_frozen=timing_gate_frozen,
        timing_passed=timing_passed,
        sync_gate_frozen=sync_gate_frozen,
        sync_passed=sync_passed,
        passed=passed,
        min_duration_s=min_duration_s,
        missing_streams=missing_streams,
        missing_metadata_fields=missing_metadata,
        metadata_mismatches=metadata_mismatches,
        invalid_accel_payloads=invalid_accel_payloads,
        invalid_gyro_payloads=invalid_gyro_payloads,
        accel_qc=accel_qc,
        gyro_qc=gyro_qc,
        accel_tick_gaps=accel_gaps,
        gyro_tick_gaps=gyro_gaps,
        requested_accel_hz=requested_accel_hz,
        requested_gyro_hz=requested_gyro_hz,
        configured_rate_tolerance_fraction=rate_tolerance_fraction,
        configured_max_gap_multiple=max_gap_multiple,
        clock_model=clock_model,
        configured_max_sync_residual_ms=max_sync_residual_ms,
        sync_landmark_coverage_passed=sync_landmark_coverage_passed,
        sync_observation_count=len(observations),
        sync_observation_span_s=sync_observation_span_s,
        sync_observation_span_fraction=sync_observation_span_fraction,
        source_evidence_sha256=source_evidence_sha256,
    )


def write_p1_receipt(
    session_dir: str | Path,
    output_path: str | Path,
    *,
    min_duration_s: float = 60.0,
    rate_tolerance_fraction: float | None = None,
    max_gap_multiple: float | None = None,
    sync_observations_path: str | Path | None = None,
    max_sync_residual_ms: float | None = None,
) -> P1Receipt:
    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=min_duration_s,
        rate_tolerance_fraction=rate_tolerance_fraction,
        max_gap_multiple=max_gap_multiple,
        sync_observations=_read_sync_observations(sync_observations_path),
        max_sync_residual_ms=max_sync_residual_ms,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
