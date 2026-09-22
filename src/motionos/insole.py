from __future__ import annotations

import csv
import hashlib
import json
import math
import re
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path

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
