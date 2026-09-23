from __future__ import annotations

import csv
import hashlib
import json
import math
import re
import statistics
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path

from .provenance import session_evidence_sha256
from .qc import StreamQC, inspect_stream
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionReader, SessionWriter

SIDES = ("left", "right")
PRESSURE_SENSOR_COUNT = 16
ACCELERATION_MPS2_PER_G = 9.80665
RADIANS_PER_DEGREE = math.pi / 180.0

LEFT_IMU_STREAM = "/body/left_foot/imu"
RIGHT_IMU_STREAM = "/body/right_foot/imu"
LEFT_PRESSURE_STREAM = "/body/left_foot/pressure"
RIGHT_PRESSURE_STREAM = "/body/right_foot/pressure"

P2_REQUIRED_STREAMS = {
    LEFT_IMU_STREAM,
    RIGHT_IMU_STREAM,
    LEFT_PRESSURE_STREAM,
    RIGHT_PRESSURE_STREAM,
}


@dataclass(frozen=True)
class OpenGoExportMetadata:
    start_time: str | None
    duration: str | None
    serial_numbers: dict[str, str]
    sensor_insole_size: int | None
    recording_type: str | None
    name: str | None
    notes: str | None
    tag: str | None
    channel_names: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["channel_names"] = list(self.channel_names)
        return data


@dataclass(frozen=True)
class OpenGoParsedExport:
    metadata: OpenGoExportMetadata
    events: tuple[SensorEvent, ...]
    source_sha256: str
    row_count: int


@dataclass(frozen=True)
class BilateralOverlap:
    left_count: int
    right_count: int
    shared_timestamps: int
    union_timestamps: int
    overlap_fraction: float

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class P2CaptureReceipt:
    session_id: str
    capture_passed: bool
    min_duration_s: float
    missing_streams: tuple[str, ...]
    missing_metadata_fields: tuple[str, ...]
    identity_errors: tuple[str, ...]
    invalid_left_imu_samples: int
    invalid_right_imu_samples: int
    invalid_left_pressure_samples: int
    invalid_right_pressure_samples: int
    left_imu_qc: StreamQC
    right_imu_qc: StreamQC
    left_pressure_qc: StreamQC
    right_pressure_qc: StreamQC
    imu_bilateral_overlap: BilateralOverlap
    pressure_bilateral_overlap: BilateralOverlap
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "P2-capture",
            "session_id": self.session_id,
            "capture_passed": self.capture_passed,
            "minimum_required_duration_s": self.min_duration_s,
            "missing_streams": list(self.missing_streams),
            "missing_metadata_fields": list(self.missing_metadata_fields),
            "identity_errors": list(self.identity_errors),
            "timing_authority": {
                "timestamp_basis": "opengo_export_relative_time",
                "sequence_authority": "motionos_import_order_only",
                "gap_authority": "export_timestamp_spacing",
            },
            "invalid_samples": {
                LEFT_IMU_STREAM: self.invalid_left_imu_samples,
                RIGHT_IMU_STREAM: self.invalid_right_imu_samples,
                LEFT_PRESSURE_STREAM: self.invalid_left_pressure_samples,
                RIGHT_PRESSURE_STREAM: self.invalid_right_pressure_samples,
            },
            "streams": {
                LEFT_IMU_STREAM: self.left_imu_qc.to_dict(),
                RIGHT_IMU_STREAM: self.right_imu_qc.to_dict(),
                LEFT_PRESSURE_STREAM: self.left_pressure_qc.to_dict(),
                RIGHT_PRESSURE_STREAM: self.right_pressure_qc.to_dict(),
            },
            "bilateral_overlap": {
                "imu": self.imu_bilateral_overlap.to_dict(),
                "pressure": self.pressure_bilateral_overlap.to_dict(),
            },
            "source_evidence_sha256": dict(self.source_evidence_sha256),
            "claim_boundary": (
                "P2 capture qualification validates exported bilateral plantar "
                "pressure and foot-IMU evidence only. Plantar pressure / total "
                "normal force is not full 3D ground-reaction force."
            ),
        }


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_serial_numbers(value: str) -> dict[str, str]:
    serials: dict[str, str] = {}
    for part in value.split(","):
        match = re.match(r"\s*(left|right)\s+(.+?)\s*$", part, re.IGNORECASE)
        if match:
            serials[match.group(1).lower()] = match.group(2).strip()
    return serials


def _read_header(path: Path) -> tuple[OpenGoExportMetadata, int]:
    fields: dict[str, str] = {}
    channel_names: tuple[str, ...] = ()
    data_start_line = 0

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.startswith("#"):
                data_start_line = line_number
                break

            line = raw_line[1:].strip()
            if "\t" in line and line.lower().startswith("time"):
                channel_names = tuple(part.strip() for part in line.split("\t"))
                data_start_line = line_number + 1
                break

            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip().lower()] = value.strip()

    if not channel_names:
        raise ValueError("OpenGo export is missing the tab-delimited channel header")

    size_raw = fields.get("size")
    try:
        size = int(size_raw) if size_raw is not None else None
    except ValueError:
        size = None

    metadata = OpenGoExportMetadata(
        start_time=fields.get("start time"),
        duration=fields.get("duration"),
        serial_numbers=_parse_serial_numbers(fields.get("sensor insoles", "")),
        sensor_insole_size=size,
        recording_type=fields.get("recording type"),
        name=fields.get("name"),
        notes=fields.get("notes"),
        tag=fields.get("tag"),
        channel_names=channel_names,
    )
    return metadata, data_start_line


def _channel_index(channel_names: tuple[str, ...]) -> dict[str, int]:
    return {
        name.strip().lower(): index
        for index, name in enumerate(channel_names)
    }


def _find_channel(
    index: dict[str, int],
    pattern: str,
) -> int | None:
    compiled = re.compile(pattern, re.IGNORECASE)
    matches = [column for name, column in index.items() if compiled.fullmatch(name)]
    if len(matches) > 1:
        raise ValueError(f"multiple OpenGo columns match {pattern!r}")
    return matches[0] if matches else None


def _required_side_columns(
    channel_names: tuple[str, ...],
    side: str,
) -> dict[str, object]:
    index = _channel_index(channel_names)

    pressure: list[int] = []
    for sensor in range(1, PRESSURE_SENSOR_COUNT + 1):
        column = _find_channel(
            index,
            rf"{side}\s+pressure\s+{sensor}\[n/cm²\]",
        )
        if column is None:
            # Accept ASCII unit spelling in hand-authored/export-normalized files.
            column = _find_channel(
                index,
                rf"{side}\s+pressure\s+{sensor}\[n/cm\^2\]",
            )
        if column is None:
            raise ValueError(
                f"OpenGo export is missing {side} pressure sensor {sensor}"
            )
        pressure.append(column)

    acceleration = []
    angular = []
    for axis in ("x", "y", "z"):
        accel_column = _find_channel(
            index,
            rf"{side}\s+acceleration\s+{axis}\[g\]",
        )
        angular_column = _find_channel(
            index,
            rf"{side}\s+angular\s+{axis}\[dps\]",
        )
        if accel_column is None or angular_column is None:
            raise ValueError(
                f"OpenGo export is missing complete {side} 6-axis IMU channels"
            )
        acceleration.append(accel_column)
        angular.append(angular_column)

    total_force = _find_channel(
        index,
        rf"{side}\s+total\s+force\[n\]",
    )
    cop_x = _find_channel(
        index,
        rf"{side}\s+center\s+of\s+pressure\s+x\[-0\.5\.\.\.\+0\.5\]",
    )
    cop_y = _find_channel(
        index,
        rf"{side}\s+center\s+of\s+pressure\s+y\[-0\.5\.\.\.\+0\.5\]",
    )

    if total_force is None or cop_x is None or cop_y is None:
        raise ValueError(
            f"OpenGo export is missing {side} total force or CoP channels"
        )

    return {
        "pressure": pressure,
        "acceleration": acceleration,
        "angular": angular,
        "total_force": total_force,
        "cop_x": cop_x,
        "cop_y": cop_y,
    }


def _cell(row: list[str], column: int) -> float | None:
    if column >= len(row):
        return None
    raw = row[column].strip()
    if raw == "":
        return None
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"non-numeric OpenGo cell value: {raw!r}") from exc
    if not math.isfinite(value):
        raise ValueError(f"non-finite OpenGo cell value: {raw!r}")
    return value


def _vector_or_none(
    row: list[str],
    columns: list[int],
    *,
    label: str,
) -> tuple[float, ...] | None:
    values = tuple(_cell(row, column) for column in columns)
    if all(value is None for value in values):
        return None
    if any(value is None for value in values):
        raise ValueError(f"partially missing {label} sample")
    return tuple(float(value) for value in values if value is not None)


def _pressure_payload(
    row: list[str],
    columns: dict[str, object],
    time_s: float,
) -> dict[str, object] | None:
    pressure_columns = columns["pressure"]
    assert isinstance(pressure_columns, list)
    raw_pressure = _vector_or_none(
        row,
        pressure_columns,
        label="pressure",
    )
    if raw_pressure is None:
        return None

    total_force_column = columns["total_force"]
    cop_x_column = columns["cop_x"]
    cop_y_column = columns["cop_y"]
    assert isinstance(total_force_column, int)
    assert isinstance(cop_x_column, int)
    assert isinstance(cop_y_column, int)

    normal_force_n = _cell(row, total_force_column)
    cop_x = _cell(row, cop_x_column)
    cop_y = _cell(row, cop_y_column)

    payload: dict[str, object] = {
        "pressure_n_per_cm2": list(raw_pressure),
        "pressure_kpa": [value * 10.0 for value in raw_pressure],
        "source_time_s": time_s,
        "timestamp_basis": "opengo_export_relative_time",
        "source": "moticon_opengo_text_export",
        "pressure_units": {
            "raw": "N/cm^2",
            "canonical": "kPa",
        },
        "cop_coordinate_basis": "normalized_insole_-0.5_to_0.5",
    }
    if normal_force_n is not None:
        payload["normal_force_n"] = normal_force_n
    if cop_x is not None and cop_y is not None:
        payload["cop_x_normalized"] = cop_x
        payload["cop_y_normalized"] = cop_y
    elif cop_x is not None or cop_y is not None:
        raise ValueError("partially missing OpenGo center-of-pressure sample")
    return payload


def _imu_payload(
    row: list[str],
    columns: dict[str, object],
    time_s: float,
) -> dict[str, object] | None:
    accel_columns = columns["acceleration"]
    angular_columns = columns["angular"]
    assert isinstance(accel_columns, list)
    assert isinstance(angular_columns, list)

    acceleration_g = _vector_or_none(
        row,
        accel_columns,
        label="acceleration",
    )
    angular_dps = _vector_or_none(
        row,
        angular_columns,
        label="angular rate",
    )
    if acceleration_g is None and angular_dps is None:
        return None
    if acceleration_g is None or angular_dps is None:
        raise ValueError("partially missing OpenGo 6-axis IMU sample")

    acceleration_si = tuple(
        value * ACCELERATION_MPS2_PER_G
        for value in acceleration_g
    )
    angular_si = tuple(
        value * RADIANS_PER_DEGREE
        for value in angular_dps
    )
    return {
        "ax": acceleration_si[0],
        "ay": acceleration_si[1],
        "az": acceleration_si[2],
        "gx": angular_si[0],
        "gy": angular_si[1],
        "gz": angular_si[2],
        "acceleration_g": list(acceleration_g),
        "angular_rate_dps": list(angular_dps),
        "source_time_s": time_s,
        "timestamp_basis": "opengo_export_relative_time",
        "source": "moticon_opengo_text_export",
        "units": {
            "acceleration": "m/s^2",
            "angular_rate": "rad/s",
            "raw_acceleration": "g",
            "raw_angular_rate": "deg/s",
        },
    }


def parse_opengo_text_export(
    path: str | Path,
    *,
    session_id: str,
) -> OpenGoParsedExport:
    source = Path(path)
    metadata, data_start_line = _read_header(source)
    index = _channel_index(metadata.channel_names)
    time_column = index.get("time")
    if time_column is None:
        raise ValueError("OpenGo export is missing the time column")

    columns = {
        side: _required_side_columns(metadata.channel_names, side)
        for side in SIDES
    }

    device_ids = {
        side: metadata.serial_numbers.get(side, f"opengo-{side}")
        for side in SIDES
    }
    sequences = {
        (side, kind): 0
        for side in SIDES
        for kind in ("imu", "pressure")
    }

    events: list[SensorEvent] = []
    row_count = 0

    with source.open("r", encoding="utf-8-sig", newline="") as handle:
        for _ in range(data_start_line - 1):
            next(handle, None)

        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if not row or all(cell.strip() == "" for cell in row):
                continue
            row_count += 1

            time_s = _cell(row, time_column)
            if time_s is None:
                raise ValueError("OpenGo data row is missing relative time")
            if time_s < 0:
                raise ValueError("OpenGo relative time must be non-negative")
            device_time_ns = round(time_s * 1e9)

            for side in SIDES:
                imu_payload = _imu_payload(row, columns[side], time_s)
                if imu_payload is not None:
                    stream = f"/body/{side}_foot/imu"
                    sequence = sequences[(side, "imu")]
                    sequences[(side, "imu")] += 1
                    events.append(
                        SensorEvent(
                            session_id=session_id,
                            device_id=device_ids[side],
                            stream=stream,
                            sequence=sequence,
                            device_time_ns=device_time_ns,
                            payload=imu_payload,
                        )
                    )

                pressure_payload = _pressure_payload(
                    row,
                    columns[side],
                    time_s,
                )
                if pressure_payload is not None:
                    stream = f"/body/{side}_foot/pressure"
                    sequence = sequences[(side, "pressure")]
                    sequences[(side, "pressure")] += 1
                    events.append(
                        SensorEvent(
                            session_id=session_id,
                            device_id=device_ids[side],
                            stream=stream,
                            sequence=sequence,
                            device_time_ns=device_time_ns,
                            payload=pressure_payload,
                        )
                    )

    if row_count == 0:
        raise ValueError("OpenGo export contains no data rows")
    if not events:
        raise ValueError("OpenGo export contains no usable bilateral sensor samples")

    return OpenGoParsedExport(
        metadata=metadata,
        events=tuple(events),
        source_sha256=_sha256_file(source),
        row_count=row_count,
    )


def import_opengo_text_export(
    path: str | Path,
    out_root: str | Path,
    *,
    session_id: str | None = None,
    athlete_id: str = "local-athlete",
    sport: str = "insole-qualification",
) -> Path:
    source = Path(path)
    resolved_session_id = (
        session_id
        or f"p2-opengo-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}"
    )
    parsed = parse_opengo_text_export(
        source,
        session_id=resolved_session_id,
    )

    serials = parsed.metadata.serial_numbers
    manifest = SessionManifest(
        session_id=resolved_session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport=sport,
        mode="field",
        athlete_id=athlete_id,
        devices=(
            DeviceDescriptor(
                device_id=serials.get("left", "opengo-left"),
                kind="smart_insole",
                placement="left_foot",
                streams=(LEFT_IMU_STREAM, LEFT_PRESSURE_STREAM),
                model="Moticon OpenGo Sensor Insole",
            ),
            DeviceDescriptor(
                device_id=serials.get("right", "opengo-right"),
                kind="smart_insole",
                placement="right_foot",
                streams=(RIGHT_IMU_STREAM, RIGHT_PRESSURE_STREAM),
                model="Moticon OpenGo Sensor Insole",
            ),
        ),
        metadata={
            "qualification_protocol": "P2",
            "source_format": "moticon_opengo_text_export",
            "source_file": source.name,
            "source_evidence_sha256": {
                "opengo_text_export": parsed.source_sha256,
            },
            "opengo_export": parsed.metadata.to_dict(),
            "timestamp_authority": "opengo_export_relative_time",
            "sequence_authority": "motionos_import_order_only",
            "pressure_sensor_count_per_side": PRESSURE_SENSOR_COUNT,
            "cop_coordinate_basis": "normalized_insole_-0.5_to_0.5",
            "normal_force_boundary": (
                "plantar/vertical normal force only; not full 3D GRF"
            ),
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            parsed.events,
            key=lambda item: (
                item.canonical_time_ns,
                item.stream,
                item.sequence,
            ),
        ):
            writer.append(event)

        writer.write_metadata(
            "p2_opengo_import",
            {
                "source_path": str(source),
                "source_sha256": parsed.source_sha256,
                "row_count": parsed.row_count,
                "event_count": len(parsed.events),
                "export_metadata": parsed.metadata.to_dict(),
            },
        )

    return Path(out_root) / resolved_session_id


def _finite_vector(
    payload: dict[str, object],
    keys: tuple[str, ...],
) -> bool:
    try:
        return all(math.isfinite(float(payload[key])) for key in keys)
    except (KeyError, TypeError, ValueError):
        return False


def _invalid_imu_samples(events: list[SensorEvent]) -> int:
    invalid = 0
    for event in events:
        if not _finite_vector(
            event.payload,
            ("ax", "ay", "az", "gx", "gy", "gz"),
        ):
            invalid += 1
            continue
        if event.payload.get("source") != "moticon_opengo_text_export":
            invalid += 1
            continue
        if (
            event.payload.get("timestamp_basis")
            != "opengo_export_relative_time"
        ):
            invalid += 1
    return invalid


def _invalid_pressure_samples(events: list[SensorEvent]) -> int:
    invalid = 0
    for event in events:
        pressure = event.payload.get("pressure_kpa")
        raw = event.payload.get("pressure_n_per_cm2")
        if (
            not isinstance(pressure, list)
            or not isinstance(raw, list)
            or len(pressure) != PRESSURE_SENSOR_COUNT
            or len(raw) != PRESSURE_SENSOR_COUNT
        ):
            invalid += 1
            continue
        try:
            canonical = [float(value) for value in pressure]
            source = [float(value) for value in raw]
        except (TypeError, ValueError):
            invalid += 1
            continue
        if not all(math.isfinite(value) for value in canonical + source):
            invalid += 1
            continue
        if any(
            not math.isclose(kpa, n_per_cm2 * 10.0, rel_tol=1e-9, abs_tol=1e-9)
            for kpa, n_per_cm2 in zip(canonical, source)
        ):
            invalid += 1
            continue
        if event.payload.get("source") != "moticon_opengo_text_export":
            invalid += 1
            continue
        if (
            event.payload.get("timestamp_basis")
            != "opengo_export_relative_time"
        ):
            invalid += 1
            continue

        force = event.payload.get("normal_force_n")
        if force is None:
            invalid += 1
            continue
        try:
            if not math.isfinite(float(force)):
                invalid += 1
                continue
        except (TypeError, ValueError):
            invalid += 1
            continue

        cop_x = event.payload.get("cop_x_normalized")
        cop_y = event.payload.get("cop_y_normalized")
        if cop_x is None or cop_y is None:
            invalid += 1
            continue
        try:
            x = float(cop_x)
            y = float(cop_y)
        except (TypeError, ValueError):
            invalid += 1
            continue
        if (
            not math.isfinite(x)
            or not math.isfinite(y)
            or not -0.55 <= x <= 0.55
            or not -0.55 <= y <= 0.55
        ):
            invalid += 1
    return invalid


def _bilateral_overlap(
    left: list[SensorEvent],
    right: list[SensorEvent],
) -> BilateralOverlap:
    left_times = {event.device_time_ns for event in left}
    right_times = {event.device_time_ns for event in right}
    shared = left_times & right_times
    union = left_times | right_times
    return BilateralOverlap(
        left_count=len(left),
        right_count=len(right),
        shared_timestamps=len(shared),
        union_timestamps=len(union),
        overlap_fraction=(len(shared) / len(union) if union else 0.0),
    )


def build_p2_capture_receipt(
    reader: SessionReader,
    *,
    min_duration_s: float = 60.0,
) -> P2CaptureReceipt:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")

    available = set(reader.list_streams())
    missing_streams = tuple(sorted(P2_REQUIRED_STREAMS - available))

    left_imu = list(reader.iter_stream(LEFT_IMU_STREAM))
    right_imu = list(reader.iter_stream(RIGHT_IMU_STREAM))
    left_pressure = list(reader.iter_stream(LEFT_PRESSURE_STREAM))
    right_pressure = list(reader.iter_stream(RIGHT_PRESSURE_STREAM))

    left_imu_qc = inspect_stream(LEFT_IMU_STREAM, left_imu)
    right_imu_qc = inspect_stream(RIGHT_IMU_STREAM, right_imu)
    left_pressure_qc = inspect_stream(LEFT_PRESSURE_STREAM, left_pressure)
    right_pressure_qc = inspect_stream(RIGHT_PRESSURE_STREAM, right_pressure)

    metadata = reader.manifest.metadata
    export_raw = metadata.get("opengo_export")
    export_metadata = export_raw if isinstance(export_raw, dict) else {}
    serials_raw = export_metadata.get("serial_numbers")
    serials = serials_raw if isinstance(serials_raw, dict) else {}
    hashes_raw = metadata.get("source_evidence_sha256")
    hashes = (
        {str(key): str(value) for key, value in hashes_raw.items()}
        if isinstance(hashes_raw, dict)
        else {}
    )

    required_metadata = {
        "left_serial": serials.get("left"),
        "right_serial": serials.get("right"),
        "source_hash": hashes.get("opengo_text_export"),
        "timestamp_authority": metadata.get("timestamp_authority"),
        "pressure_sensor_count_per_side": metadata.get(
            "pressure_sensor_count_per_side"
        ),
        "cop_coordinate_basis": metadata.get("cop_coordinate_basis"),
    }
    missing_metadata = tuple(
        sorted(
            key
            for key, value in required_metadata.items()
            if value is None
        )
    )

    invalid_left_imu = _invalid_imu_samples(left_imu)
    invalid_right_imu = _invalid_imu_samples(right_imu)
    invalid_left_pressure = _invalid_pressure_samples(left_pressure)
    invalid_right_pressure = _invalid_pressure_samples(right_pressure)

    qcs = (
        left_imu_qc,
        right_imu_qc,
        left_pressure_qc,
        right_pressure_qc,
    )
    imu_overlap = _bilateral_overlap(left_imu, right_imu)
    pressure_overlap = _bilateral_overlap(
        left_pressure,
        right_pressure,
    )

    identity_errors: list[str] = []
    left_serial = serials.get("left")
    right_serial = serials.get("right")
    if (
        left_serial is not None
        and right_serial is not None
        and str(left_serial) == str(right_serial)
    ):
        identity_errors.append("left/right serial identities are identical")

    capture_passed = (
        not missing_streams
        and not missing_metadata
        and not identity_errors
        and imu_overlap.shared_timestamps > 0
        and pressure_overlap.shared_timestamps > 0
        and metadata.get("timestamp_authority")
        == "opengo_export_relative_time"
        and metadata.get("pressure_sensor_count_per_side")
        == PRESSURE_SENSOR_COUNT
        and metadata.get("cop_coordinate_basis")
        == "normalized_insole_-0.5_to_0.5"
        and invalid_left_imu == 0
        and invalid_right_imu == 0
        and invalid_left_pressure == 0
        and invalid_right_pressure == 0
        and all(report.count >= 2 for report in qcs)
        and all(report.duration_s >= min_duration_s for report in qcs)
        and all(report.non_monotonic_timestamps == 0 for report in qcs)
    )

    return P2CaptureReceipt(
        session_id=reader.manifest.session_id,
        capture_passed=capture_passed,
        min_duration_s=min_duration_s,
        missing_streams=missing_streams,
        missing_metadata_fields=missing_metadata,
        identity_errors=tuple(identity_errors),
        invalid_left_imu_samples=invalid_left_imu,
        invalid_right_imu_samples=invalid_right_imu,
        invalid_left_pressure_samples=invalid_left_pressure,
        invalid_right_pressure_samples=invalid_right_pressure,
        left_imu_qc=left_imu_qc,
        right_imu_qc=right_imu_qc,
        left_pressure_qc=left_pressure_qc,
        right_pressure_qc=right_pressure_qc,
        imu_bilateral_overlap=imu_overlap,
        pressure_bilateral_overlap=pressure_overlap,
        source_evidence_sha256=hashes,
    )


def write_p2_capture_receipt(
    session_dir: str | Path,
    output_path: str | Path,
    *,
    min_duration_s: float = 60.0,
) -> P2CaptureReceipt:
    receipt = build_p2_capture_receipt(
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


P2_PHYSICAL_SPEC_SCHEMA_VERSION = "motionos.p2-physical-spec.v1"
P2_PHYSICAL_RECEIPT_SCHEMA_VERSION = "motionos.p2-physical-receipt.v1"
P2_REQUIRED_CONTROLLED_WINDOWS = (
    "unloaded_pre",
    "static_load",
    "repeatability_a",
    "repeatability_b",
    "unloaded_post",
)


@dataclass(frozen=True)
class P2PressureWindow:
    label: str
    start_ns: int
    end_ns: int
    pair_count: int
    median_total_force_n: float
    max_total_force_n: float
    median_left_load_fraction: float

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class P2PhysicalReceipt:
    field_session_id: str
    controlled_session_id: str
    passed: bool
    capture_passed: bool
    overlap_gate_passed: bool
    unloaded_gate_passed: bool
    static_load_gate_passed: bool
    repeatability_gate_passed: bool
    protocol_gate_passed: bool
    min_controlled_duration_s: float
    min_field_duration_s: float
    min_bilateral_overlap_fraction: float
    max_unloaded_total_force_n: float
    known_static_load_n: float
    static_load_tolerance_fraction: float
    max_repeatability_total_force_delta_fraction: float
    max_repeatability_left_fraction_delta: float
    controlled_capture: P2CaptureReceipt
    field_capture: P2CaptureReceipt
    pressure_windows: tuple[P2PressureWindow, ...]
    static_load_relative_error: float
    repeatability_total_force_delta_fraction: float
    repeatability_left_fraction_delta: float
    wireless_separation_completed: bool
    don_doff_completed: bool
    qualification_spec_sha256: str
    controlled_bundle_sha256: str
    field_bundle_sha256: str
    schema_version: str = P2_PHYSICAL_RECEIPT_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "protocol": "P2",
            "controlled_session_id": self.controlled_session_id,
            "field_session_id": self.field_session_id,
            "capture_passed": self.capture_passed,
            "passed": self.passed,
            "gates": {
                "bilateral_overlap": {
                    "passed": self.overlap_gate_passed,
                    "minimum_fraction": self.min_bilateral_overlap_fraction,
                },
                "unloaded_zero": {
                    "passed": self.unloaded_gate_passed,
                    "maximum_total_force_n": self.max_unloaded_total_force_n,
                },
                "known_static_load": {
                    "passed": self.static_load_gate_passed,
                    "known_load_n": self.known_static_load_n,
                    "tolerance_fraction": self.static_load_tolerance_fraction,
                    "relative_error": self.static_load_relative_error,
                },
                "don_doff_repeatability": {
                    "passed": self.repeatability_gate_passed,
                    "max_total_force_delta_fraction": (
                        self.max_repeatability_total_force_delta_fraction
                    ),
                    "observed_total_force_delta_fraction": (
                        self.repeatability_total_force_delta_fraction
                    ),
                    "max_left_fraction_delta": (
                        self.max_repeatability_left_fraction_delta
                    ),
                    "observed_left_fraction_delta": (
                        self.repeatability_left_fraction_delta
                    ),
                },
                "physical_protocol": {
                    "passed": self.protocol_gate_passed,
                    "wireless_separation_completed": (
                        self.wireless_separation_completed
                    ),
                    "don_doff_completed": self.don_doff_completed,
                    "authority": "operator_attestation_in_hashed_spec",
                },
            },
            "minimum_required_duration_s": {
                "controlled": self.min_controlled_duration_s,
                "field": self.min_field_duration_s,
            },
            "pressure_windows": [
                window.to_dict() for window in self.pressure_windows
            ],
            "controlled_capture": self.controlled_capture.to_dict(),
            "field_capture": self.field_capture.to_dict(),
            "qualification_spec_sha256": self.qualification_spec_sha256,
            "session_bundle_sha256": {
                "controlled": self.controlled_bundle_sha256,
                "field": self.field_bundle_sha256,
            },
            "claim_boundary": (
                "P2 passed=true qualifies bilateral insole capture, explicit "
                "controlled pressure checks, and the attested physical protocol "
                "against thresholds frozen in the hashed qualification spec. "
                "Cross-device timing is qualified separately by the calibration "
                "bundle clock receipt. Plantar/normal force is not full 3D "
                "ground-reaction force."
            ),
        }


def _p2_spec_number(
    mapping: dict[str, object],
    key: str,
    *,
    minimum: float = 0.0,
    maximum: float | None = None,
    strictly_positive: bool = False,
) -> float:
    try:
        value = float(mapping[key])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"P2 physical spec requires numeric {key!r}") from exc
    if not math.isfinite(value):
        raise ValueError(f"P2 physical spec {key!r} must be finite")
    if strictly_positive and value <= minimum:
        raise ValueError(f"P2 physical spec {key!r} must be > {minimum}")
    if not strictly_positive and value < minimum:
        raise ValueError(f"P2 physical spec {key!r} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"P2 physical spec {key!r} must be <= {maximum}")
    return value


def load_p2_physical_spec(
    path: str | Path,
) -> dict[str, object]:
    spec_path = Path(path)
    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("P2 physical spec must contain a JSON object")
    if raw.get("schema_version") != P2_PHYSICAL_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported P2 physical spec schema")

    thresholds_raw = raw.get("thresholds")
    windows_raw = raw.get("controlled_windows")
    protocol_raw = raw.get("protocol")
    if not isinstance(thresholds_raw, dict):
        raise TypeError("P2 physical spec thresholds must be an object")
    if not isinstance(windows_raw, dict):
        raise TypeError("P2 physical spec controlled_windows must be an object")
    if not isinstance(protocol_raw, dict):
        raise TypeError("P2 physical spec protocol must be an object")

    _p2_spec_number(
        thresholds_raw,
        "min_bilateral_overlap_fraction",
        maximum=1.0,
    )
    _p2_spec_number(thresholds_raw, "max_unloaded_total_force_n")
    _p2_spec_number(
        thresholds_raw,
        "known_static_load_n",
        strictly_positive=True,
    )
    _p2_spec_number(
        thresholds_raw,
        "static_load_tolerance_fraction",
        maximum=1.0,
    )
    _p2_spec_number(
        thresholds_raw,
        "max_repeatability_total_force_delta_fraction",
        maximum=1.0,
    )
    _p2_spec_number(
        thresholds_raw,
        "max_repeatability_left_fraction_delta",
        maximum=1.0,
    )

    for label in P2_REQUIRED_CONTROLLED_WINDOWS:
        window = windows_raw.get(label)
        if not isinstance(window, dict):
            raise ValueError(
                f"P2 physical spec requires controlled window {label!r}"
            )
        try:
            start_ns = int(window["start_ns"])
            end_ns = int(window["end_ns"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"invalid P2 controlled window {label!r}"
            ) from exc
        if start_ns < 0 or end_ns <= start_ns:
            raise ValueError(
                f"P2 controlled window {label!r} must have 0 <= start < end"
            )

    for key in (
        "wireless_separation_completed",
        "don_doff_completed",
    ):
        if not isinstance(protocol_raw.get(key), bool):
            raise TypeError(
                f"P2 physical spec protocol.{key} must be boolean"
            )

    return dict(raw)


def _paired_pressure_samples(
    reader: SessionReader,
    *,
    start_ns: int,
    end_ns: int,
) -> list[tuple[float, float]]:
    left = {
        event.device_time_ns: event
        for event in reader.iter_stream(LEFT_PRESSURE_STREAM)
        if start_ns <= event.device_time_ns <= end_ns
    }
    right = {
        event.device_time_ns: event
        for event in reader.iter_stream(RIGHT_PRESSURE_STREAM)
        if start_ns <= event.device_time_ns <= end_ns
    }

    pairs: list[tuple[float, float]] = []
    for timestamp in sorted(left.keys() & right.keys()):
        try:
            left_force = float(left[timestamp].payload["normal_force_n"])
            right_force = float(right[timestamp].payload["normal_force_n"])
        except (KeyError, TypeError, ValueError):
            continue
        if (
            math.isfinite(left_force)
            and math.isfinite(right_force)
            and left_force >= 0
            and right_force >= 0
        ):
            pairs.append((left_force, right_force))
    return pairs


def _pressure_window(
    reader: SessionReader,
    *,
    label: str,
    start_ns: int,
    end_ns: int,
) -> P2PressureWindow:
    pairs = _paired_pressure_samples(
        reader,
        start_ns=start_ns,
        end_ns=end_ns,
    )
    if not pairs:
        raise ValueError(
            f"P2 controlled window {label!r} contains no bilateral pressure pairs"
        )

    totals = [left + right for left, right in pairs]
    fractions = [
        left / total
        for (left, _right), total in zip(pairs, totals)
        if total > 0
    ]
    if not fractions:
        raise ValueError(
            f"P2 controlled window {label!r} has zero total force only"
        )

    return P2PressureWindow(
        label=label,
        start_ns=start_ns,
        end_ns=end_ns,
        pair_count=len(pairs),
        median_total_force_n=statistics.median(totals),
        max_total_force_n=max(totals),
        median_left_load_fraction=statistics.median(fractions),
    )


def build_p2_physical_receipt(
    field_reader: SessionReader,
    controlled_reader: SessionReader,
    spec: dict[str, object],
    *,
    spec_sha256: str,
    min_controlled_duration_s: float = 600.0,
    min_field_duration_s: float = 1800.0,
) -> P2PhysicalReceipt:
    if min_controlled_duration_s <= 0 or min_field_duration_s <= 0:
        raise ValueError("P2 physical minimum durations must be positive")
    if spec.get("schema_version") != P2_PHYSICAL_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported P2 physical spec schema")

    thresholds_raw = spec.get("thresholds")
    windows_raw = spec.get("controlled_windows")
    protocol_raw = spec.get("protocol")
    if not isinstance(thresholds_raw, dict):
        raise TypeError("P2 physical spec thresholds must be an object")
    if not isinstance(windows_raw, dict):
        raise TypeError("P2 physical spec controlled_windows must be an object")
    if not isinstance(protocol_raw, dict):
        raise TypeError("P2 physical spec protocol must be an object")

    min_overlap = _p2_spec_number(
        thresholds_raw,
        "min_bilateral_overlap_fraction",
        maximum=1.0,
    )
    max_unloaded = _p2_spec_number(
        thresholds_raw,
        "max_unloaded_total_force_n",
    )
    known_load = _p2_spec_number(
        thresholds_raw,
        "known_static_load_n",
        strictly_positive=True,
    )
    static_tolerance = _p2_spec_number(
        thresholds_raw,
        "static_load_tolerance_fraction",
        maximum=1.0,
    )
    max_repeat_force = _p2_spec_number(
        thresholds_raw,
        "max_repeatability_total_force_delta_fraction",
        maximum=1.0,
    )
    max_repeat_fraction = _p2_spec_number(
        thresholds_raw,
        "max_repeatability_left_fraction_delta",
        maximum=1.0,
    )

    controlled_capture = build_p2_capture_receipt(
        controlled_reader,
        min_duration_s=min_controlled_duration_s,
    )
    field_capture = build_p2_capture_receipt(
        field_reader,
        min_duration_s=min_field_duration_s,
    )
    capture_passed = (
        controlled_capture.capture_passed
        and field_capture.capture_passed
    )

    overlap_values = (
        controlled_capture.imu_bilateral_overlap.overlap_fraction,
        controlled_capture.pressure_bilateral_overlap.overlap_fraction,
        field_capture.imu_bilateral_overlap.overlap_fraction,
        field_capture.pressure_bilateral_overlap.overlap_fraction,
    )
    overlap_gate = all(value >= min_overlap for value in overlap_values)

    measurements: list[P2PressureWindow] = []
    for label in P2_REQUIRED_CONTROLLED_WINDOWS:
        window = windows_raw.get(label)
        if not isinstance(window, dict):
            raise ValueError(
                f"P2 physical spec requires controlled window {label!r}"
            )
        measurements.append(
            _pressure_window(
                controlled_reader,
                label=label,
                start_ns=int(window["start_ns"]),
                end_ns=int(window["end_ns"]),
            )
        )
    by_label = {item.label: item for item in measurements}

    unloaded_gate = (
        by_label["unloaded_pre"].max_total_force_n <= max_unloaded
        and by_label["unloaded_post"].max_total_force_n <= max_unloaded
    )

    static_force = by_label["static_load"].median_total_force_n
    static_error = abs(static_force - known_load) / known_load
    static_gate = static_error <= static_tolerance

    repeat_a = by_label["repeatability_a"]
    repeat_b = by_label["repeatability_b"]
    repeat_denominator = (
        repeat_a.median_total_force_n + repeat_b.median_total_force_n
    ) / 2.0
    if repeat_denominator <= 0:
        repeat_force_delta = math.inf
    else:
        repeat_force_delta = (
            abs(
                repeat_a.median_total_force_n
                - repeat_b.median_total_force_n
            )
            / repeat_denominator
        )
    repeat_fraction_delta = abs(
        repeat_a.median_left_load_fraction
        - repeat_b.median_left_load_fraction
    )
    repeatability_gate = (
        repeat_force_delta <= max_repeat_force
        and repeat_fraction_delta <= max_repeat_fraction
    )

    wireless_completed = (
        protocol_raw.get("wireless_separation_completed") is True
    )
    don_doff_completed = protocol_raw.get("don_doff_completed") is True
    protocol_gate = wireless_completed and don_doff_completed

    passed = (
        capture_passed
        and overlap_gate
        and unloaded_gate
        and static_gate
        and repeatability_gate
        and protocol_gate
    )

    return P2PhysicalReceipt(
        field_session_id=field_reader.manifest.session_id,
        controlled_session_id=controlled_reader.manifest.session_id,
        passed=passed,
        capture_passed=capture_passed,
        overlap_gate_passed=overlap_gate,
        unloaded_gate_passed=unloaded_gate,
        static_load_gate_passed=static_gate,
        repeatability_gate_passed=repeatability_gate,
        protocol_gate_passed=protocol_gate,
        min_controlled_duration_s=min_controlled_duration_s,
        min_field_duration_s=min_field_duration_s,
        min_bilateral_overlap_fraction=min_overlap,
        max_unloaded_total_force_n=max_unloaded,
        known_static_load_n=known_load,
        static_load_tolerance_fraction=static_tolerance,
        max_repeatability_total_force_delta_fraction=max_repeat_force,
        max_repeatability_left_fraction_delta=max_repeat_fraction,
        controlled_capture=controlled_capture,
        field_capture=field_capture,
        pressure_windows=tuple(measurements),
        static_load_relative_error=static_error,
        repeatability_total_force_delta_fraction=repeat_force_delta,
        repeatability_left_fraction_delta=repeat_fraction_delta,
        wireless_separation_completed=wireless_completed,
        don_doff_completed=don_doff_completed,
        qualification_spec_sha256=spec_sha256,
        controlled_bundle_sha256=session_evidence_sha256(controlled_reader),
        field_bundle_sha256=session_evidence_sha256(field_reader),
    )


def write_p2_physical_receipt(
    field_session_dir: str | Path,
    controlled_session_dir: str | Path,
    spec_path: str | Path,
    output_path: str | Path,
    *,
    min_controlled_duration_s: float = 600.0,
    min_field_duration_s: float = 1800.0,
) -> P2PhysicalReceipt:
    spec_file = Path(spec_path)
    spec = load_p2_physical_spec(spec_file)
    receipt = build_p2_physical_receipt(
        SessionReader(field_session_dir),
        SessionReader(controlled_session_dir),
        spec,
        spec_sha256=_sha256_file(spec_file),
        min_controlled_duration_s=min_controlled_duration_s,
        min_field_duration_s=min_field_duration_s,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
