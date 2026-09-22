# ruff: noqa: I001
from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.calibration import (
    build_calibration_bundle,
    calibration_gap_regions,
    load_calibration_bundle,
    replay_calibration_frames,
)
from motionos.clock_sync import write_clock_sync
from motionos.schema import (
    DeviceDescriptor,
    SensorEvent,
    SessionManifest,
)
from motionos.session import SessionReader, SessionWriter


REFERENCE_STREAM = "/body/watch/imu"
TARGET_STREAM = "/equipment/imu/accel"


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    stream: str,
    times_ns: list[int],
    impulse_times: set[int],
) -> Path:
    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="calibration",
        mode="calibration",
        athlete_id="fixture",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="imu",
                placement="fixture",
                streams=(stream,),
            ),
        ),
        metadata={
            "source_evidence_sha256": {
                "source": f"{session_id}-raw-source",
            },
        },
    )
    with SessionWriter(root, manifest) as writer:
        for sequence, time_ns in enumerate(times_ns):
            writer.append(
                SensorEvent(
                    session_id=session_id,
                    device_id=device_id,
                    stream=stream,
                    sequence=sequence,
                    device_time_ns=time_ns,
                    payload={
                        "ax": 25.0 if time_ns in impulse_times else 1.0,
                        "ay": 0.0,
                        "az": 0.0,
                    },
                )
            )
        writer.write_metadata("fixture", {"session_id": session_id})
    return root / session_id


def _build_fixture(tmp_path: Path) -> dict[str, Path]:
    slope = 1.0 + 30e-6
    intercept = 60_000_000

    target_times = [
        index * 100_000_000
        for index in range(41)
        if index not in {25, 26, 27, 28}
    ]
    reference_times = [
        round(slope * index * 100_000_000 + intercept)
        for index in range(41)
    ]
    target_impulses = {
        200_000_000,
        2_000_000_000,
        3_800_000_000,
    }
    reference_impulses = {
        round(slope * value + intercept)
        for value in target_impulses
    }

    sessions_root = tmp_path / "sessions"
    reference = _write_session(
        sessions_root,
        session_id="watch-ref",
        device_id="watch",
        stream=REFERENCE_STREAM,
        times_ns=reference_times,
        impulse_times=reference_impulses,
    )
    target = _write_session(
        sessions_root,
        session_id="pod-target",
        device_id="pod",
        stream=TARGET_STREAM,
        times_ns=target_times,
        impulse_times=target_impulses,
    )

    windows = []
    for target_time in sorted(target_impulses):
        reference_time = round(slope * target_time + intercept)
        windows.append(
            {
                "reference_start_ns": reference_time - 40_000_000,
                "reference_end_ns": reference_time + 40_000_000,
                "target_start_ns": target_time - 40_000_000,
                "target_end_ns": target_time + 40_000_000,
                "uncertainty_ns": 1_000_000,
            }
        )

    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()
    windows_path = artifacts / "windows.json"
    windows_path.write_text(json.dumps(windows), encoding="utf-8")

    sync_path = artifacts / "equipment-sync.json"
    write_clock_sync(
        reference,
        target,
        windows_path,
        sync_path,
        reference_stream=REFERENCE_STREAM,
        target_stream=TARGET_STREAM,
    )

    p0 = artifacts / "p0.json"
    p0.write_text(
        json.dumps({"protocol": "P0", "passed": True}),
        encoding="utf-8",
    )
    p1 = artifacts / "p1.json"
    p1.write_text(
        json.dumps({"protocol": "P1", "passed": True}),
        encoding="utf-8",
    )
    mount = artifacts / "mount.json"
    mount.write_text(
        json.dumps({"schema_version": "fixture.mount.v1"}),
        encoding="utf-8",
    )

    return {
        "reference": reference,
        "target": target,
        "sync": sync_path,
        "p0": p0,
        "p1": p1,
        "mount": mount,
    }


def _write_spec(
    tmp_path: Path,
    fixture: dict[str, Path],
    *,
    target_session: Path | None = None,
    sync_path: Path | None = None,
) -> tuple[Path, Path]:
    spec = {
        "reference": {
            "role": "watch",
            "session": str(fixture["reference"]),
        },
        "sources": [
            {
                "role": "watch",
                "session": str(fixture["reference"]),
                "receipt": str(fixture["p0"]),
            },
            {
                "role": "equipment",
                "session": str(target_session or fixture["target"]),
                "receipt": str(fixture["p1"]),
                "clock_sync": str(sync_path or fixture["sync"]),
            },
        ],
        "profiles": [
            {
                "kind": "equipment_mount",
                "path": str(fixture["mount"]),
            }
        ],
    }
    spec_path = tmp_path / "calibration-spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")
    output = tmp_path / "bundle" / "calibration.json"
    return spec_path, output


def test_build_bundle_verifies_source_and_clock_provenance(tmp_path):
    fixture = _build_fixture(tmp_path)
    spec, output = _write_spec(tmp_path, fixture)

    bundle = build_calibration_bundle(spec, output)

    assert bundle.reference_role == "watch"
    assert bundle.reference_session_id == "watch-ref"
    assert [source.role for source in bundle.sources] == [
        "watch",
        "equipment",
    ]
    watch, equipment = bundle.sources
    assert watch.clock_model is None
    assert watch.mapping_quality == 1.0
    assert equipment.clock_model is not None
    assert equipment.clock_model.drift_ppm == pytest.approx(30.0, abs=0.01)
    assert equipment.mapping_quality == pytest.approx(
        equipment.clock_model.quality
    )
    assert len(watch.bundle_sha256) == 64
    assert len(equipment.bundle_sha256) == 64
    assert watch.receipt is not None
    assert equipment.clock_sync is not None
    assert bundle.profiles[0].kind == "equipment_mount"

    loaded = load_calibration_bundle(output)
    assert loaded == bundle


def test_replay_preserves_raw_time_and_exposes_mapped_time(tmp_path):
    fixture = _build_fixture(tmp_path)
    spec, output = _write_spec(tmp_path, fixture)
    bundle = build_calibration_bundle(spec, output)

    frames = list(replay_calibration_frames(output, frame_hz=20.0))
    assert frames

    target_events = [
        event
        for frame in frames
        for event in frame.events
        if event.role == "equipment"
    ]
    assert target_events

    event = next(
        item
        for item in target_events
        if item.raw_device_time_ns == 1_000_000_000
    )
    equipment = next(
        source
        for source in bundle.sources
        if source.role == "equipment"
    )
    assert equipment.clock_model is not None
    assert event.raw_device_time_ns == 1_000_000_000
    assert event.source_session_time_ns is None
    assert event.mapped_reference_time_ns == equipment.clock_model.map(
        1_000_000_000
    )
    assert event.mapping_quality == pytest.approx(
        equipment.clock_model.quality
    )


def test_replay_reports_injected_timestamp_gap_without_interpolation(tmp_path):
    fixture = _build_fixture(tmp_path)
    spec, output = _write_spec(tmp_path, fixture)
    build_calibration_bundle(spec, output)

    gaps = calibration_gap_regions(output)
    equipment_gaps = [
        gap
        for gap in gaps
        if gap.role == "equipment" and gap.stream == TARGET_STREAM
    ]

    assert equipment_gaps
    gap = max(equipment_gaps, key=lambda item: item.duration_ns)
    # Gap duration is reported on the mapped reference clock, so the
    # +30 ppm target→reference slope scales both cadence and gap duration.
    assert gap.duration_ns == 500_015_000
    assert gap.expected_interval_ns == pytest.approx(100_003_000.0)
    assert gap.gap_multiple == pytest.approx(5.0)

    frames = list(replay_calibration_frames(output, frame_hz=20.0))
    assert any(
        f"equipment:{TARGET_STREAM}" in frame.active_gap_streams
        for frame in frames
    )


def test_bundle_detects_source_session_tampering(tmp_path):
    fixture = _build_fixture(tmp_path)
    spec, output = _write_spec(tmp_path, fixture)
    build_calibration_bundle(spec, output)

    reader = SessionReader(fixture["target"])
    stream_path = fixture["target"] / reader.index["streams"][TARGET_STREAM]["path"]
    with stream_path.open("a", encoding="utf-8") as handle:
        handle.write("\n")

    with pytest.raises(ValueError, match="session evidence hash changed"):
        load_calibration_bundle(output)


def test_bundle_detects_profile_tampering(tmp_path):
    fixture = _build_fixture(tmp_path)
    spec, output = _write_spec(tmp_path, fixture)
    build_calibration_bundle(spec, output)

    fixture["mount"].write_text(
        json.dumps({"schema_version": "tampered"}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="profile hash changed"):
        load_calibration_bundle(output)


def test_bundle_rejects_clock_sync_for_wrong_target_session(tmp_path):
    fixture = _build_fixture(tmp_path)

    wrong_target = _write_session(
        tmp_path / "sessions",
        session_id="other-target",
        device_id="other",
        stream=TARGET_STREAM,
        times_ns=[index * 100_000_000 for index in range(41)],
        impulse_times={
            200_000_000,
            2_000_000_000,
            3_800_000_000,
        },
    )
    spec, output = _write_spec(
        tmp_path,
        fixture,
        target_session=wrong_target,
    )

    with pytest.raises(ValueError, match="target session"):
        build_calibration_bundle(spec, output)



def test_bundle_rejects_preexisting_tampered_clock_model(tmp_path):
    fixture = _build_fixture(tmp_path)
    raw = json.loads(fixture["sync"].read_text(encoding="utf-8"))
    raw["clock_model"]["slope"] = 1.25
    fixture["sync"].write_text(
        json.dumps(raw),
        encoding="utf-8",
    )

    spec, output = _write_spec(tmp_path, fixture)

    with pytest.raises(ValueError, match="affine model does not recompute"):
        build_calibration_bundle(spec, output)



def test_calibration_spec_paths_are_relative_to_spec_file(tmp_path):
    _build_fixture(tmp_path)

    spec_dir = tmp_path / "config"
    spec_dir.mkdir()
    spec = {
        "reference": {
            "role": "watch",
            "session": "../sessions/watch-ref",
        },
        "sources": [
            {
                "role": "watch",
                "session": "../sessions/watch-ref",
                "receipt": "../artifacts/p0.json",
            },
            {
                "role": "equipment",
                "session": "../sessions/pod-target",
                "receipt": "../artifacts/p1.json",
                "clock_sync": "../artifacts/equipment-sync.json",
            },
        ],
        "profiles": [
            {
                "kind": "equipment_mount",
                "path": "../artifacts/mount.json",
            }
        ],
    }
    spec_path = spec_dir / "calibration-spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")

    output = tmp_path / "portable" / "calibration.json"
    bundle = build_calibration_bundle(spec_path, output)
    loaded = load_calibration_bundle(output)

    assert loaded == bundle
    assert bundle.reference_session_id == "watch-ref"
    assert {
        source.role: source.session_id
        for source in bundle.sources
    } == {
        "watch": "watch-ref",
        "equipment": "pod-target",
    }
