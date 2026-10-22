"""Synthetic source bundles: verify hashes and clocks, not physiological accuracy."""
from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.cli import main
from motionos.clock_sync import derive_clock_sync
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter
from motionos.teacher_source_qualification import (
    build_teacher_source_qualification,
    verify_teacher_source_qualification,
)
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
)
from motionos.video_teacher_dataset import build_video_teacher_index


def _session(root: Path, name: str, stream: str, times: list[int]) -> Path:
    desc = DeviceDescriptor(
        device_id=name,
        kind="test",
        placement="test",
        streams=(stream,),
    )
    manifest = SessionManifest(
        session_id=name,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="indo_board",
        mode="calibration",
        athlete_id="synthetic",
        devices=(desc,),
    )
    with SessionWriter(root, manifest) as writer:
        for i, value in enumerate(times):
            writer.append(SensorEvent(
                session_id=name,
                device_id=name,
                stream=stream,
                sequence=i,
                device_time_ns=value,
                payload={
                    "ax": 30.0 if i in {2, 20, 38} else 1.0,
                    "ay": 0.0,
                    "az": 0.0,
                    "synthetic_load": 0.5,
                },
            ))
    return root / name


def _fixture(tmp_path: Path):
    sensor_times = [i * 100_000_000 for i in range(41)]
    ref_times = [t + 40_000_000 for t in sensor_times]
    reference = _session(tmp_path / "sessions", "watch-ref", "/watch/imu", ref_times)
    target = _session(
        tmp_path / "sessions",
        "pressure-synthetic",
        "/insoles/bilateral/pressure",
        sensor_times,
    )
    windows = [
        {
            "reference_start_ns": ref_times[i] - 40_000_000,
            "reference_end_ns": ref_times[i] + 40_000_000,
            "target_start_ns": sensor_times[i] - 40_000_000,
            "target_end_ns": sensor_times[i] + 40_000_000,
            "uncertainty_ns": 1_000_000,
        }
        for i in (2, 20, 38)
    ]
    sync = derive_clock_sync(
        SessionReader(reference),
        SessionReader(target),
        windows,
        reference_stream="/watch/imu",
        target_stream="/insoles/bilateral/pressure",
    )
    assert sync.coverage.passed
    (tmp_path / "sensor-sync.json").write_text(
        json.dumps(sync.to_dict()), encoding="utf-8"
    )
    video = tmp_path / "original.mov"
    video.write_bytes(b"synthetic-video-only-no-real-frames")
    anchors = [
        VideoAlignmentAnchor(
            label=label,
            video_pts_ns=t,
            reference_time_ns=t + 40_000_000,
            uncertainty_ns=1_000_000,
        )
        for label, t in (("start", 200_000_000),
                         ("middle", 2_000_000_000),
                         ("end", 3_800_000_000))
    ]
    receipt = build_video_alignment(
        video,
        run_id="run-a",
        video_duration_ns=4_000_000_000,
        reference_start_ns=40_000_000,
        reference_end_ns=4_040_000_000,
        anchors=anchors,
        source_metadata={"reference_session_id": "watch-ref"},
    )
    assert receipt.coverage.passed
    (tmp_path / "video-sync.json").write_text(
        json.dumps(receipt.to_dict()), encoding="utf-8"
    )
    registry = json.loads(
        (Path(__file__).resolve().parents[1]
         / "examples" / "longboard-observability.example.json").read_text()
    )
    registry["sport"] = "indo_board"
    (tmp_path / "observability.json").write_text(json.dumps(registry))

    sensor_data = target / "streams" / "insoles__bilateral__pressure.jsonl"
    assert sensor_data.is_file()
    candidate = {
        "schema_version": "motionos.video-teacher-spec.v1",
        "dataset_id": "synthetic-test-only",
        "observability_registry": "observability.json",
        "captures": [{
            "sample_id": "synthetic-001",
            "subject_id": "p-a1b2c3d4",
            "run_id": "run-a",
            "day_id": "day-a",
            "remount_id": "remount-a",
            "camera_view": "front",
            "sport": "indo_board",
            "task_id": "free-balance",
            "protocol_version": "test-v1",
            "video": "original.mov",
            "consent": {
                "training_and_evaluation": True,
                "consent_reference": "fixture-only-not-real-consent",
            },
            "labels": [{
                "target_id": "left_load_fraction",
                "kind": "sensor_measured",
                "modality": "bilateral_pressure",
                "time_axis": "native_ns",
                "path": str(sensor_data.relative_to(tmp_path)),
                "alignment_receipt": "sensor-sync.json",
            }],
        }],
    }
    (tmp_path / "candidate-spec.json").write_text(json.dumps(candidate))
    build_video_teacher_index(
        tmp_path / "candidate-spec.json", tmp_path / "candidate-index.json"
    )
    source_spec = {
        "schema_version": "motionos.teacher-source-qualification-spec.v1",
        "candidate_index": "candidate-index.json",
        "samples": [{
            "sample_id": "synthetic-001",
            "reference_session": str(reference.relative_to(tmp_path)),
            "video_alignment_receipt": "video-sync.json",
            "labels": [{
                "target_id": "left_load_fraction",
                "modality": "bilateral_pressure",
                "sensor_session": str(target.relative_to(tmp_path)),
                "sensor_stream": "/insoles/bilateral/pressure",
                "clock_sync_receipt": "sensor-sync.json",
            }],
        }],
    }
    spec_path = tmp_path / "qualify.json"
    spec_path.write_text(json.dumps(source_spec))
    return spec_path, tmp_path / "qualified.json"


def test_original_source_video_and_sensor_clock_are_bound(tmp_path):
    spec, out = _fixture(tmp_path)
    result = build_teacher_source_qualification(spec, out)
    assert result["source_binding_passed"] is True
    assert result["training_ready"] is False
    assert result["sample_count"] == 1
    assert result["samples"][0]["labels"][0]["samples_within_video"] == 41
    assert result["samples"][0]["labels"][0]["observed_window_fraction"] == 1.0
    assert result["samples"][0]["labels"][0]["physiological_label_validated"] is False
    assert verify_teacher_source_qualification(out)["passed"] is True


def test_cli_build_and_verify(tmp_path, capsys):
    spec, output = _fixture(tmp_path)
    assert main(["qualify-teacher-sources", str(spec), str(output)]) == 0
    assert main(["verify-teacher-sources", str(output)]) == 0


def test_modified_video_is_not_still_qualified(tmp_path):
    spec, out = _fixture(tmp_path)
    build_teacher_source_qualification(spec, out)
    (tmp_path / "original.mov").write_bytes(b"changed-evidence")
    with pytest.raises(ValueError, match="differs|hash mismatch"):
        verify_teacher_source_qualification(out)


def test_video_reference_session_mismatch_is_rejected(tmp_path):
    spec, out = _fixture(tmp_path)
    path = tmp_path / "video-sync.json"
    receipt = json.loads(path.read_text())
    receipt["source_video"]["metadata"]["reference_session_id"] = "other-session"
    path.write_text(json.dumps(receipt))
    with pytest.raises(ValueError, match="reference session identity"):
        build_teacher_source_qualification(spec, out)


def test_video_alignment_must_recompute(tmp_path):
    spec, out = _fixture(tmp_path)
    path = tmp_path / "video-sync.json"
    receipt = json.loads(path.read_text())
    receipt["coverage"]["passed"] = False
    path.write_text(json.dumps(receipt))
    with pytest.raises(ValueError, match="coverage does not recompute"):
        build_teacher_source_qualification(spec, out)


def test_clock_receipt_must_recompute_and_match_source_session(tmp_path):
    spec, out = _fixture(tmp_path)
    path = tmp_path / "sensor-sync.json"
    receipt = json.loads(path.read_text())
    receipt["target"]["bundle_sha256"] = "0" * 64
    path.write_text(json.dumps(receipt))
    with pytest.raises(ValueError, match="bundle hash mismatch"):
        build_teacher_source_qualification(spec, out)


def test_arbitrary_label_file_cannot_masquerade_as_raw_sensor_stream(tmp_path):
    spec, out = _fixture(tmp_path)
    candidate_path = tmp_path / "candidate-spec.json"
    raw = json.loads(candidate_path.read_text())
    (tmp_path / "imposter.jsonl").write_text('{"faked":true}\n')
    raw["captures"][0]["labels"][0]["path"] = "imposter.jsonl"
    candidate_path.write_text(json.dumps(raw))
    build_video_teacher_index(candidate_path, tmp_path / "candidate-index.json")
    with pytest.raises(ValueError, match="not the original sensor stream"):
        build_teacher_source_qualification(spec, out)


def test_missing_sensor_coverage_fails_closed(tmp_path):
    spec, out = _fixture(tmp_path)
    source = json.loads(spec.read_text())
    source["samples"][0]["labels"][0]["sensor_stream"] = "/missing/stream"
    spec.write_text(json.dumps(source))
    with pytest.raises(ValueError, match="different sensor stream"):
        build_teacher_source_qualification(spec, out)


def test_report_edit_is_detected(tmp_path):
    spec, out = _fixture(tmp_path)
    build_teacher_source_qualification(spec, out)
    report = json.loads(out.read_text())
    report["samples"][0]["labels"][0]["observed_window_fraction"] = 0.0
    out.write_text(json.dumps(report))
    with pytest.raises(ValueError, match="report differs"):
        verify_teacher_source_qualification(out)
