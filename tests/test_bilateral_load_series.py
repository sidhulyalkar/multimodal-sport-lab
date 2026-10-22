"""Source-level synthetic tests; no physical pressure or participant evidence."""
from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.bilateral_load_series import (
    build_bilateral_load_series,
    verify_bilateral_load_series,
)
from motionos.cli import main
from motionos.clock_sync import derive_clock_sync
from motionos.insole import LEFT_PRESSURE_STREAM, RIGHT_PRESSURE_STREAM
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter
from motionos.teacher_source_qualification import build_teacher_source_qualification
from motionos.video_alignment import VideoAlignmentAnchor, build_video_alignment
from motionos.video_teacher_dataset import build_video_teacher_index


def _session(tmp_path, name, *, sensor=False, incomplete=False, bad_right_clock=False):
    root = tmp_path / "sessions"
    left_times = [i * 100_000_000 for i in range(41)]
    times = left_times if sensor else [t + 40_000_000 for t in left_times]
    streams = ((LEFT_PRESSURE_STREAM, RIGHT_PRESSURE_STREAM) if sensor else ("/watch/imu",))
    manifest = SessionManifest(
        session_id=name,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="indo_board",
        mode="calibration",
        athlete_id="synthetic-only",
        devices=(
            DeviceDescriptor(name, "synthetic", "fixture", streams),
        ),
    )
    with SessionWriter(root, manifest) as writer:
        for i, t in enumerate(times):
            if not sensor:
                writer.append(SensorEvent(
                    session_id=name, device_id=name, stream="/watch/imu",
                    sequence=i, device_time_ns=t,
                    payload={"ax": 30.0 if i in (2, 20, 38) else 1.0,
                             "ay": 0.0, "az": 0.0},
                ))
                continue
            for side, stream in (("left", LEFT_PRESSURE_STREAM),
                                 ("right", RIGHT_PRESSURE_STREAM)):
                if incomplete and side == "right" and i == 20:
                    continue
                force = 40.0 if side == "left" else 60.0
                if incomplete and i == 21:
                    force = 0.0
                if incomplete and side == "right" and i == 22:
                    force = -2.0
                payload = {
                    "source": "moticon_opengo_text_export",
                    "timestamp_basis": (
                        "unverified_right_clock"
                        if bad_right_clock and side == "right"
                        else "opengo_export_relative_time"
                    ),
                    "pressure_units": {"raw": "N/cm^2", "canonical": "kPa"},
                    "pressure_kpa": [10.0] * 16,
                    "normal_force_n": force,
                    "ax": 30.0 if i in (2, 20, 38) else 1.0,
                    "ay": 0.0,
                    "az": 0.0,
                }
                seq = i if side == "left" else (i - 1 if incomplete and i > 20 else i)
                writer.append(SensorEvent(
                    session_id=name, device_id=name, stream=stream,
                    sequence=seq, device_time_ns=t, payload=payload,
                ))
    return root / name


def _fixture(tmp_path: Path, *, incomplete=False, bad_right_clock=False):
    reference = _session(tmp_path, "watch-reference")
    pressure = _session(
        tmp_path, "opengo-reference",
        sensor=True, incomplete=incomplete, bad_right_clock=bad_right_clock,
    )
    watch = SessionReader(reference)
    insoles = SessionReader(pressure)

    windows = [
        {"reference_start_ns": i * 100_000_000,
         "reference_end_ns": i * 100_000_000 + 80_000_000,
         "target_start_ns": i * 100_000_000 - 40_000_000,
         "target_end_ns": i * 100_000_000 + 40_000_000}
        for i in (2, 20, 38)
    ]
    receipt = derive_clock_sync(
        watch, insoles, windows,
        reference_stream="/watch/imu",
        target_stream=LEFT_PRESSURE_STREAM,
    )
    assert receipt.coverage.passed
    (tmp_path / "pressure-clock.json").write_text(json.dumps(receipt.to_dict()))
    video = tmp_path / "original.mov"
    video.write_bytes(b"illustrative-video-bytes-only")
    anchors = [
        VideoAlignmentAnchor(
            label=label,
            video_pts_ns=i * 100_000_000,
            reference_time_ns=i * 100_000_000 + 40_000_000,
        )
        for label, i in (("start", 2), ("middle", 20), ("end", 38))
    ]
    video_receipt = build_video_alignment(
        video, run_id="run-a", video_duration_ns=4_000_000_000,
        reference_start_ns=40_000_000, reference_end_ns=4_040_000_000,
        anchors=anchors, source_metadata={"reference_session_id": "watch-reference"},
    )
    assert video_receipt.coverage.passed
    (tmp_path / "video-clock.json").write_text(json.dumps(video_receipt.to_dict()))

    registry = json.loads(
        (Path(__file__).resolve().parents[1] / "examples"
         / "longboard-observability.example.json").read_text(encoding="utf-8")
    )
    registry["sport"] = "indo_board"
    (tmp_path / "registry.json").write_text(json.dumps(registry))
    pressure_source = pressure / "streams" / "body__left_foot__pressure.jsonl"
    assert pressure_source.is_file()
    candidate_spec = {
        "schema_version": "motionos.video-teacher-spec.v1",
        "dataset_id": "synthetic-load-only",
        "observability_registry": "registry.json",
        "captures": [{
            "sample_id": "s-001",
            "subject_id": "p-abc12345",
            "run_id": "run-a", "day_id": "day-a",
            "remount_id": "mount-a", "camera_view": "front",
            "sport": "indo_board", "task_id": "free-balance",
            "protocol_version": "synthetic-test",
            "video": "original.mov",
            "consent": {
                "training_and_evaluation": True,
                "consent_reference": "synthetic-only-not-real-consent",
            },
            "labels": [{
                "target_id": "left_load_fraction",
                "kind": "sensor_measured",
                "modality": "bilateral_pressure",
                "time_axis": "native_ns",
                "path": str(pressure_source.relative_to(tmp_path)),
                "alignment_receipt": "pressure-clock.json",
            }],
        }],
    }
    (tmp_path / "candidate-spec.json").write_text(json.dumps(candidate_spec))
    build_video_teacher_index(
        tmp_path / "candidate-spec.json", tmp_path / "candidate-index.json"
    )
    source_spec = {
        "schema_version": "motionos.teacher-source-qualification-spec.v1",
        "candidate_index": "candidate-index.json",
        "samples": [{
            "sample_id": "s-001",
            "reference_session": str(reference.relative_to(tmp_path)),
            "video_alignment_receipt": "video-clock.json",
            "labels": [{
                "target_id": "left_load_fraction",
                "modality": "bilateral_pressure",
                "sensor_session": str(pressure.relative_to(tmp_path)),
                "sensor_stream": LEFT_PRESSURE_STREAM,
                "clock_sync_receipt": "pressure-clock.json",
            }],
        }],
    }
    (tmp_path / "qualify.json").write_text(json.dumps(source_spec))
    build_teacher_source_qualification(
        tmp_path / "qualify.json", tmp_path / "source-qualified.json"
    )
    (tmp_path / "load-spec.json").write_text(json.dumps({
        "schema_version": "motionos.bilateral-load-series-spec.v1",
        "source_qualification": "source-qualified.json",
        "samples": [{"sample_id": "s-001"}],
    }))
    return tmp_path / "load-spec.json", tmp_path / "derived-series.json"


def test_materialize_derive_left_fraction_and_verification(tmp_path):
    spec, out = _fixture(tmp_path)
    result = build_bilateral_load_series(spec, out)
    series = result["series"][0]
    assert result["privacy_classification"] == "derived_restricted"
    assert result["training_ready"] is False
    assert series["sample_count"] == 41
    assert series["valid_pair_count"] == 41
    assert series["numeric_qc_passed"] is True
    assert series["calibration_verified"] is False
    assert series["rows"][0]["left_load_fraction"] == pytest.approx(0.4)
    assert series["rows"][0]["total_force_n"] == 100.0
    assert series["rows"][0]["video_pts_ns"] == 0
    assert verify_bilateral_load_series(out)["passed"] is True


def test_mask_missing_and_bad_values_without_interpolating(tmp_path):
    spec, out = _fixture(tmp_path, incomplete=True)
    series = build_bilateral_load_series(spec, out)["series"][0]
    assert series["sample_count"] == 41
    assert series["valid_pair_count"] == 38
    assert series["numeric_qc_passed"] is True
    rows = series["rows"]
    assert rows[20]["left_load_fraction"] is None
    assert rows[20]["invalid_reasons"] == ["right:missing_side"]
    assert rows[21]["invalid_reasons"] == ["zero_total_force"]
    assert rows[22]["invalid_reasons"] == ["right:negative_force"]
    assert rows[23]["left_load_fraction"] == pytest.approx(0.4)


def test_tampered_series_or_original_video_rejected(tmp_path):
    spec, out = _fixture(tmp_path)
    build_bilateral_load_series(spec, out)
    data = json.loads(out.read_text())
    data["series"][0]["rows"][0]["left_load_fraction"] = 0.95
    out.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="no longer matches"):
        verify_bilateral_load_series(out)
    build_bilateral_load_series(spec, out)
    (tmp_path / "original.mov").write_bytes(b"corrupted")
    with pytest.raises(ValueError, match="differs|hash mismatch"):
        verify_bilateral_load_series(out)


def test_refuses_to_overwrite_canonical_source_video(tmp_path):
    spec, _ = _fixture(tmp_path)
    video = tmp_path / "original.mov"
    before = video.read_bytes()
    with pytest.raises(FileExistsError, match="refusing to overwrite"):
        build_bilateral_load_series(spec, video)
    assert video.read_bytes() == before


def test_cli_build_verify(tmp_path, capsys):
    spec, out = _fixture(tmp_path)
    assert main(["build-bilateral-load-series", str(spec), str(out)]) == 0
    assert main(["verify-bilateral-load-series", str(out)]) == 0


def test_different_right_sensor_clock_fails_closed(tmp_path):
    spec, out = _fixture(tmp_path, bad_right_clock=True)
    with pytest.raises(ValueError, match="unqualified timebase"):
        build_bilateral_load_series(spec, out)


def test_calibration_receipt_is_hash_bound_but_not_physically_approved(tmp_path):
    spec, out = _fixture(tmp_path)
    calibration_path = tmp_path / "calibration.json"
    calibration_path.write_text(json.dumps({
        "kind": "synthetic-calibration-placeholder",
        "physically_verified": False,
    }))
    request = json.loads(spec.read_text())
    request["samples"][0]["calibration_receipt"] = "calibration.json"
    spec.write_text(json.dumps(request))
    result = build_bilateral_load_series(spec, out)["series"][0]
    assert result["calibration_reference"]["sha256"]
    assert result["calibration_verified"] is False
    assert verify_bilateral_load_series(out)["passed"] is True
    calibration_path.write_text(json.dumps({"kind": "modified"}))
    with pytest.raises(ValueError, match="no longer matches"):
        verify_bilateral_load_series(out)
