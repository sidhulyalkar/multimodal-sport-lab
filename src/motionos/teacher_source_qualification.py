"""Source-bound timing qualification for private video/sensor teacher candidates.

This validates source identity and synchronized time coverage, NOT physiological
accuracy, participant authorization, or readiness for supervised training.
"""
from __future__ import annotations

import json
import os
from itertools import pairwise
from pathlib import Path
from typing import Any

from .clock_sync import load_clock_sync_receipt, validate_clock_sync_receipt
from .provenance import session_evidence_sha256, sha256_file
from .session import SessionReader
from .video_alignment import load_video_alignment, validate_video_alignment
from .video_teacher_dataset import verify_video_teacher_index

SPEC_VERSION = "motionos.teacher-source-qualification-spec.v1"
REPORT_VERSION = "motionos.teacher-source-qualification.v1"
# These are *binding* hygiene limits, not biomechanical accuracy thresholds.
MAX_CLOCK_RMS_NS = 20_000_000
MAX_SENSOR_GAP_NS = 500_000_000
MIN_OBSERVED_SECONDS = 2.0
MIN_SENSOR_SAMPLES = 20
MIN_OBSERVED_FRACTION = 0.80


def _string(value: object, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a nonempty string")
    return value.strip()


def _file(raw: object, base: Path, name: str) -> Path:
    path = (base / _string(raw, name)).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{name} does not exist: {path}")
    return path


def _dir(raw: object, base: Path, name: str) -> Path:
    path = (base / _string(raw, name)).resolve()
    if not path.is_dir():
        raise FileNotFoundError(f"{name} does not exist: {path}")
    return path


def _bound_hash(ref: object, root: Path, *, name: str) -> Path:
    if not isinstance(ref, dict):
        raise TypeError(f"{name} must be an artifact reference")
    path = _file(ref.get("path"), root, name)
    if sha256_file(path) != _string(ref.get("sha256"), name + ".sha256"):
        raise ValueError(f"{name} source hash mismatch")
    if path.stat().st_size != ref.get("bytes"):
        raise ValueError(f"{name} source byte count mismatch")
    return path


def _portable(path: Path, root: Path) -> str:
    return os.path.relpath(path.resolve(), start=root.resolve())


def _binding(spec: dict[str, object], sample: dict[str, object], base: Path,
             index_root: Path) -> dict[str, Any]:
    sample_id = _string(sample.get("sample_id"), "sample_id")
    bindings = spec.get("labels")
    if not isinstance(bindings, list) or not bindings:
        raise ValueError(f"{sample_id}: expected nonempty sensor source bindings")

    reference_root = _dir(
        spec.get("reference_session"), base, sample_id + ".reference_session"
    )
    reference = SessionReader(reference_root)
    video = _bound_hash(sample.get("video"), index_root, name=sample_id + ".video")
    video_alignment_file = _file(
        spec.get("video_alignment_receipt"), base, sample_id + ".video_alignment"
    )
    video_alignment = load_video_alignment(video_alignment_file)
    validate_video_alignment(video_alignment, video)
    if video_alignment.run_id != sample.get("run_id"):
        raise ValueError(f"{sample_id}: video alignment run_id mismatch")
    if not video_alignment.coverage.passed:
        raise ValueError(f"{sample_id}: video alignment lacks start/middle/end coverage")
    if video_alignment.source_metadata.get("reference_session_id") != reference.manifest.session_id:
        raise ValueError(f"{sample_id}: video reference session identity not bound")
    if video_alignment.clock_model.residual_rms_ns > MAX_CLOCK_RMS_NS:
        raise ValueError(f"{sample_id}: video alignment residual exceeds threshold")

    measured = {
        (label["target_id"], label["modality"]): label
        for label in sample["labels"] if label["kind"] == "sensor_measured"
    }
    if not measured:
        raise ValueError(f"{sample_id}: candidate has no sensor-measured labels")
    if len(bindings) != len(measured):
        raise ValueError(f"{sample_id}: bindings do not cover measured label set")
    label_rows = []
    used: set[tuple[str, str]] = set()
    for j, item in enumerate(bindings):
        if not isinstance(item, dict):
            raise TypeError(f"{sample_id}.labels[{j}] must be an object")
        key = (
            _string(item.get("target_id"), "target_id"),
            _string(item.get("modality"), "modality"),
        )
        if key in used or key not in measured:
            raise ValueError(f"{sample_id}: duplicate or unknown measured label binding {key}")
        used.add(key)
        label = measured[key]
        target_root = _dir(item.get("sensor_session"), base, "sensor_session")
        target = SessionReader(target_root)
        stream = _string(item.get("sensor_stream"), "sensor_stream")
        receipt_file = _file(item.get("clock_sync_receipt"), base, "clock_sync_receipt")
        clock_receipt = load_clock_sync_receipt(receipt_file)
        clock = validate_clock_sync_receipt(clock_receipt, reference, target)
        if clock_receipt.target.stream != stream:
            raise ValueError(f"{sample_id}: clock receipt binds a different sensor stream")
        if clock_receipt.reference.session_id != reference.manifest.session_id:
            raise ValueError(f"{sample_id}: clock reference session mismatch")
        if clock.residual_rms_ns > MAX_CLOCK_RMS_NS:
            raise ValueError(f"{sample_id}: sensor clock residual exceeds threshold")

        info = target.index.get("streams", {}).get(stream)
        if not isinstance(info, dict):
            raise TypeError(f"{sample_id}: sensor stream is missing")
        raw_path = _file(info.get("path"), target_root, "indexed sensor stream")
        if not raw_path.is_relative_to(target_root):
            raise ValueError(f"{sample_id}: sensor stream path escapes its session")
        indexed_source = _bound_hash(
            label["source"], index_root, name=sample_id + ".sensor_source"
        )
        if raw_path != indexed_source:
            raise ValueError(f"{sample_id}: teacher label is not the original sensor stream")

        events = list(target.iter_stream(stream))
        if len(events) < MIN_SENSOR_SAMPLES:
            raise ValueError(f"{sample_id}: insufficient measured sensor samples")
        if any(
            current.sequence <= previous.sequence
            or current.device_time_ns <= previous.device_time_ns
            for previous, current in pairwise(events)
        ):
            raise ValueError(f"{sample_id}: non-monotonic or duplicate sensor timestamps")

        start = video_alignment.reference_start_ns
        end = video_alignment.reference_end_ns
        mapped: list[int] = []
        for event in events:
            reference_ns = clock.map(event.device_time_ns)
            if label["time_axis"] == "reference_ns" and (
                event.session_time_ns is None
                or abs(event.session_time_ns - reference_ns) > MAX_CLOCK_RMS_NS
            ):
                raise ValueError(
                    f"{sample_id}: declared reference time is absent or inconsistent"
                )
            if start <= reference_ns <= end:
                mapped.append(reference_ns)

        if len(mapped) < MIN_SENSOR_SAMPLES:
            raise ValueError(f"{sample_id}: insufficient samples in video window")
        observed_ns = sum(
            b - a for a, b in pairwise(mapped)
            if 0 < b - a <= MAX_SENSOR_GAP_NS
        )
        fraction = observed_ns / (end - start)
        if observed_ns < MIN_OBSERVED_SECONDS * 1_000_000_000:
            raise ValueError(f"{sample_id}: measured overlap too short")
        if fraction < MIN_OBSERVED_FRACTION:
            raise ValueError(f"{sample_id}: measured overlap too sparse")
        label_rows.append({
            "target_id": key[0],
            "modality": key[1],
            "sensor_stream": stream,
            "sensor_session_id": target.manifest.session_id,
            "sensor_session_sha256": session_evidence_sha256(target),
            "raw_source_sha256": sha256_file(raw_path),
            "clock_sync_sha256": sha256_file(receipt_file),
            "clock_sync_rms_ms": clock.residual_rms_ns / 1e6,
            "samples_within_video": len(mapped),
            "observed_duration_seconds": round(observed_ns / 1e9, 6),
            "observed_window_fraction": round(fraction, 6),
            "timing_source_bound": True,
            "physiological_label_validated": False,
        })
    return {
        "sample_id": sample_id,
        "reference_session_id": reference.manifest.session_id,
        "reference_session_sha256": session_evidence_sha256(reference),
        "source_video_sha256": sha256_file(video),
        "video_alignment_sha256": sha256_file(video_alignment_file),
        "video_alignment_rms_ms": video_alignment.clock_model.residual_rms_ns / 1e6,
        "labels": sorted(label_rows, key=lambda x: (x["target_id"], x["modality"])),
    }


def _build(spec_path: Path, output_path: Path) -> dict[str, Any]:
    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("schema_version") != SPEC_VERSION:
        raise ValueError("unsupported teacher source qualification spec")
    index_path = _file(raw.get("candidate_index"), spec_path.parent, "candidate_index")
    verify_video_teacher_index(index_path)
    index = json.loads(index_path.read_text(encoding="utf-8"))
    indexed = {row["sample_id"]: row for row in index["samples"]}
    specs = raw.get("samples")
    if not isinstance(specs, list) or not specs:
        raise ValueError("qualification spec requires samples")

    used: set[str] = set()
    rows = []
    for item in specs:
        if not isinstance(item, dict):
            raise TypeError("qualification samples must be objects")
        sample_id = _string(item.get("sample_id"), "sample_id")
        if sample_id in used or sample_id not in indexed:
            raise ValueError("duplicate or unknown candidate sample_id")
        used.add(sample_id)
        rows.append(_binding(item, indexed[sample_id], spec_path.parent, index_path.parent))

    return {
        "schema_version": REPORT_VERSION,
        "candidate_index_sha256": sha256_file(index_path),
        "candidate_index": _portable(index_path, output_path.parent),
        "qualification_spec_sha256": sha256_file(spec_path),
        "qualification_spec": _portable(spec_path, output_path.parent),
        "sample_count": len(rows),
        "samples": sorted(rows, key=lambda x: x["sample_id"]),
        "source_binding_passed": True,
        "training_ready": False,
        "claim_boundary": (
            "Source hashes and replayed video/sensor clock models passed checks. "
            "No independent participant consent verification, sensor physical "
            "calibration, per-value label accuracy, or biomechanical model "
            "performance is established. Do not train on this report alone."
        ),
    }


def build_teacher_source_qualification(
    spec_path: str | Path, output_path: str | Path,
) -> dict[str, Any]:
    spec = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    if spec == output:
        raise ValueError("output must not overwrite qualification spec")
    result = _build(spec, output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result


def verify_teacher_source_qualification(report_path: str | Path) -> dict[str, object]:
    path = Path(report_path).resolve()
    existing = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(existing, dict) or existing.get("schema_version") != REPORT_VERSION:
        raise ValueError("unsupported teacher source qualification report")
    spec = _file(existing.get("qualification_spec"), path.parent, "qualification_spec")
    recomputed = _build(spec, path)
    if existing != recomputed:
        raise ValueError("teacher qualification report differs from original evidence")
    return {
        "schema_version": REPORT_VERSION,
        "passed": True,
        "training_ready": False,
        "sample_count": existing["sample_count"],
        "report_sha256": sha256_file(path),
    }
