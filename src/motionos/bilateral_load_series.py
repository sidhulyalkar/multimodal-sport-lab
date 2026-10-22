"""A private, source-bound, missingness-aware bilateral OpenGo loading series.

Software validation of derived reference labels is not sensor calibration,
physical qualification, participant authorization, or training approval.
"""
from __future__ import annotations

import json
import math
import os
from itertools import pairwise
from pathlib import Path
from typing import Any

from .clock_sync import load_clock_sync_receipt, validate_clock_sync_receipt
from .insole import LEFT_PRESSURE_STREAM, RIGHT_PRESSURE_STREAM
from .provenance import session_evidence_sha256, sha256_file
from .session import SessionReader
from .teacher_source_qualification import verify_teacher_source_qualification
from .video_alignment import load_video_alignment, validate_video_alignment

SPEC = "motionos.bilateral-load-series-spec.v1"
VERSION = "motionos.bilateral-load-series.v1"
MAX_GAP_NS = 500_000_000
MIN_VALID_FRACTION = 0.80


def _name(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be nonempty")
    return value.strip()


def _file(root: Path, value: object, label: str) -> Path:
    path = (root / _name(value, label)).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{label} not found: {path}")
    return path


def _read(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError(f"expected JSON object: {path}")
    return data


def _portable(path: Path, root: Path) -> str:
    return os.path.relpath(path.resolve(), start=root.resolve())


def _pressure_events(reader: SessionReader, stream: str) -> dict[int, Any]:
    events = list(reader.iter_stream(stream))
    if not events:
        raise ValueError(f"missing original pressure stream: {stream}")
    if any(
        b.sequence <= a.sequence or b.device_time_ns <= a.device_time_ns
        for a, b in pairwise(events)
    ):
        raise ValueError(f"duplicate/nonmonotonic pressure timestamps: {stream}")
    for event in events:
        if event.payload.get("source") != "moticon_opengo_text_export":
            raise ValueError(f"not source-native OpenGo pressure evidence: {stream}")
        if event.payload.get("timestamp_basis") != "opengo_export_relative_time":
            raise ValueError(f"unqualified timebase for: {stream}")
        units = event.payload.get("pressure_units")
        if not isinstance(units, dict) or units.get("canonical") != "kPa":
            raise ValueError(f"unknown pressure units for: {stream}")
    return {e.device_time_ns: e for e in events}


def _force(event: Any) -> tuple[float | None, str | None]:
    if event is None:
        return None, "missing_side"
    value = event.payload.get("normal_force_n")
    if value is None:
        return None, "missing_force"
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None, "non_numeric_force"
    force = float(value)
    if not math.isfinite(force):
        return None, "nonfinite_force"
    if force < 0:
        return None, "negative_force"
    return force, None


def _derive_sample(
    record: dict[str, Any],
    qualification: dict[str, Any],
    candidate: dict[str, Any],
    binding: dict[str, Any],
    spec_dir: Path,
    index_dir: Path,
    output_dir: Path,
) -> dict[str, Any]:
    sample_id = _name(record.get("sample_id"), "sample_id")
    measured = [
        item for item in qualification["labels"]
        if item["target_id"] == "left_load_fraction"
        and item["modality"] == "bilateral_pressure"
    ]
    source_labels = [
        item for item in binding["labels"]
        if item["target_id"] == "left_load_fraction"
        and item["modality"] == "bilateral_pressure"
    ]
    if len(measured) != 1 or len(source_labels) != 1:
        raise ValueError(f"{sample_id}: requires one source-qualified bilateral pressure target")
    qualified, source_label = measured[0], source_labels[0]
    if qualified["sensor_stream"] not in (LEFT_PRESSURE_STREAM, RIGHT_PRESSURE_STREAM):
        raise ValueError(f"{sample_id}: qualified stream must be an original foot pressure stream")
    if not qualified["timing_source_bound"]:
        raise ValueError(f"{sample_id}: original pressure source not qualified")

    sensor_dir = (spec_dir / _name(source_label["sensor_session"], "sensor_session")).resolve()
    reference_dir = (spec_dir / _name(binding["reference_session"], "reference_session")).resolve()
    sensor = SessionReader(sensor_dir)
    reference = SessionReader(reference_dir)
    if session_evidence_sha256(sensor) != qualified["sensor_session_sha256"]:
        raise ValueError("pressure source session digest changed")
    if session_evidence_sha256(reference) != qualification["reference_session_sha256"]:
        raise ValueError("reference source session digest changed")
    streams = sensor.index["streams"]
    original = (sensor_dir / streams[qualified["sensor_stream"]]["path"]).resolve()
    if not original.is_relative_to(sensor_dir):
        raise ValueError("pressure stream escaped original sensor session")
    if sha256_file(original) != qualified["raw_source_sha256"]:
        raise ValueError("qualified label is not the original sensor stream")

    left = _pressure_events(sensor, LEFT_PRESSURE_STREAM)
    right = _pressure_events(sensor, RIGHT_PRESSURE_STREAM)
    video = _file(index_dir, candidate["video"]["path"], "source video")
    if sha256_file(video) != qualification["source_video_sha256"]:
        raise ValueError("source video digest changed")
    video_receipt = _file(spec_dir, binding["video_alignment_receipt"], "video alignment")
    video_alignment = load_video_alignment(video_receipt)
    validate_video_alignment(video_alignment, video)
    if video_alignment.source_metadata.get("reference_session_id") != reference.manifest.session_id:
        raise ValueError("video not bound to original reference session")
    clock_path = _file(spec_dir, source_label["clock_sync_receipt"], "sensor clock")
    clock_receipt = load_clock_sync_receipt(clock_path)
    clock = validate_clock_sync_receipt(clock_receipt, reference, sensor)
    if clock_receipt.target.stream != qualified["sensor_stream"]:
        raise ValueError("pressure clock binds the wrong stream")

    # Both OpenGo streams originate from the same export-relative clock basis,
    # confirmed on each source event above. Arbitrary paired BLE clocks are
    # intentionally unsupported by this v1 materializer.
    t0, t1 = video_alignment.reference_start_ns, video_alignment.reference_end_ns
    rows: list[dict[str, Any]] = []
    gaps: list[dict[str, int]] = []
    previous: int | None = None
    for native_ns in sorted(left.keys() | right.keys()):
        reference_ns = clock.map(native_ns)
        if reference_ns < t0 or reference_ns > t1:
            continue
        if previous is not None and reference_ns - previous > MAX_GAP_NS:
            gaps.append({"start_reference_ns": previous, "end_reference_ns": reference_ns})
        previous = reference_ns
        lf, le = _force(left.get(native_ns))
        rf, re = _force(right.get(native_ns))
        reasons = [
            f"{side}:{reason}" for side, reason in (("left", le), ("right", re))
            if reason is not None
        ]
        total = None
        fraction = None
        if not reasons:
            assert lf is not None and rf is not None
            total = lf + rf
            if total <= 0:
                reasons.append("zero_total_force")
            else:
                fraction = lf / total
        rows.append({
            "native_time_ns": native_ns,
            "reference_time_ns": reference_ns,
            "video_pts_ns": video_alignment.map_reference_to_video_pts(reference_ns),
            "left_force_n": lf,
            "right_force_n": rf,
            "total_force_n": total,
            "left_load_fraction": fraction,
            "valid": not reasons,
            "invalid_reasons": reasons,
        })
    if not rows:
        raise ValueError(f"{sample_id}: no sensor readings overlap aligned video")
    valid = sum(row["valid"] for row in rows)
    calibration = None
    if record.get("calibration_receipt") is not None:
        path = _file(output_dir, record["calibration_receipt"], "calibration receipt")
        calibration = {"path": _portable(path, output_dir), "sha256": sha256_file(path)}
    return {
        "sample_id": sample_id,
        "subject_id": candidate["subject_id"],
        "run_id": candidate["run_id"],
        "target_id": "left_load_fraction",
        "units": "fraction",
        "coordinate_frame": "anatomical_left_right_feet",
        "origin": "derived_from_opengo_bilateral_normal_force_n",
        "original_sensor_session_sha256": qualified["sensor_session_sha256"],
        "original_video_sha256": qualified.get("source_video_sha256", sha256_file(video)),
        "video_alignment_sha256": sha256_file(video_receipt),
        "sensor_clock_sha256": sha256_file(clock_path),
        "sensor_clock_residual_ms": clock.residual_rms_ns / 1e6,
        "calibration_reference": calibration,
        "calibration_verified": False,
        "valid_pair_count": valid,
        "sample_count": len(rows),
        "valid_pair_fraction": round(valid / len(rows), 6),
        "missing_intervals": gaps,
        "numeric_qc_passed": valid / len(rows) >= MIN_VALID_FRACTION and not gaps,
        "rows": rows,
    }


def _build(spec_path: Path, destination: Path) -> dict[str, Any]:
    raw = _read(spec_path)
    if raw.get("schema_version") != SPEC:
        raise ValueError("unsupported bilateral load series spec")
    qualification_path = _file(
        spec_path.parent, raw.get("source_qualification"), "source qualification"
    )
    verify_teacher_source_qualification(qualification_path)
    qual = _read(qualification_path)
    qual_spec_path = _file(
        qualification_path.parent, qual["qualification_spec"], "qualification spec"
    )
    qual_spec = _read(qual_spec_path)
    candidate_path = _file(
        qual_spec_path.parent, qual_spec["candidate_index"], "candidate index"
    )
    candidate_index = _read(candidate_path)
    candidates = {s["sample_id"]: s for s in candidate_index["samples"]}
    bound = {s["sample_id"]: s for s in qual_spec["samples"]}
    qualified = {s["sample_id"]: s for s in qual["samples"]}
    requested = raw.get("samples")
    if not isinstance(requested, list) or not requested:
        raise ValueError("bilateral load spec requires samples")
    used: set[str] = set()
    result = []
    for config in requested:
        if not isinstance(config, dict):
            raise TypeError("sample config must be a JSON object")
        sample_id = _name(config.get("sample_id"), "sample_id")
        if sample_id in used or sample_id not in qualified:
            raise ValueError(f"duplicate or unqualified sample_id: {sample_id}")
        used.add(sample_id)
        result.append(_derive_sample(
            config, qualified[sample_id], candidates[sample_id],
            bound[sample_id], qual_spec_path.parent,
            candidate_path.parent, spec_path.parent,
        ))
    return {
        "schema_version": VERSION,
        "source_spec": _portable(spec_path, destination.parent),
        "source_spec_sha256": sha256_file(spec_path),
        "source_qualification_sha256": sha256_file(qualification_path),
        "privacy_classification": "derived_restricted",
        "training_ready": False,
        "series_count": len(result),
        "series": sorted(result, key=lambda s: s["sample_id"]),
        "claim_boundary": (
            "Numeric loading labels are derived from original OpenGo force channels. "
            "Missing samples are not interpolated; calibration, consent and "
            "physiological accuracy remain unverified. Do not train on this alone."
        ),
    }


def build_bilateral_load_series(spec_path: str | Path, output_path: str | Path) -> dict[str, Any]:
    spec, destination = Path(spec_path).resolve(), Path(output_path).resolve()
    if spec == destination:
        raise ValueError("output must not overwrite source spec")
    if destination.exists():
        try:
            previous = _read(destination)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FileExistsError(
                "refusing to overwrite existing non-series evidence"
            ) from exc
        if previous.get("schema_version") != VERSION:
            raise FileExistsError("refusing to overwrite existing non-series evidence")
    output = _build(spec, destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)
    return output


def verify_bilateral_load_series(path: str | Path) -> dict[str, Any]:
    destination = Path(path).resolve()
    existing = _read(destination)
    if existing.get("schema_version") != VERSION:
        raise ValueError("unsupported bilateral load series")
    spec = _file(destination.parent, existing.get("source_spec"), "source spec")
    rebuilt = _build(spec, destination)
    if existing != rebuilt:
        raise ValueError("bilateral load series no longer matches original evidence")
    return {
        "schema_version": VERSION,
        "passed": True,
        "training_ready": False,
        "series_count": len(rebuilt["series"]),
        "sha256": sha256_file(destination),
    }
