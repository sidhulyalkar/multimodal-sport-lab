from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.clock_sync import (
    clock_observations_from_json,
    derive_clock_sync,
    load_clock_sync_receipt,
    write_clock_sync,
)
from motionos.p1 import derive_impulse_clock_observations
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter


def _write_imu_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    stream: str,
    times_ns: list[int],
    impulse_indices: set[int],
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
                "fixture": f"{session_id}-source-hash",
            },
        },
    )

    with SessionWriter(root, manifest) as writer:
        for sequence, time_ns in enumerate(times_ns):
            impulse = 30.0 if sequence in impulse_indices else 1.0
            writer.append(
                SensorEvent(
                    session_id=session_id,
                    device_id=device_id,
                    stream=stream,
                    sequence=sequence,
                    device_time_ns=time_ns,
                    payload={
                        "ax": impulse,
                        "ay": 0.0,
                        "az": 0.0,
                    },
                )
            )
        writer.write_metadata(
            "fixture",
            {"session_id": session_id},
        )
    return root / session_id


def _fixture_sessions(tmp_path: Path) -> tuple[Path, Path, list[dict[str, int]]]:
    target_times = [index * 100_000_000 for index in range(41)]
    slope = 1.0 + 25e-6
    intercept = 40_000_000
    reference_times = [
        round(slope * time_ns + intercept)
        for time_ns in target_times
    ]
    impulses = {2, 20, 38}

    reference = _write_imu_session(
        tmp_path / "sessions",
        session_id="watch-reference",
        device_id="watch",
        stream="/body/watch/imu",
        times_ns=reference_times,
        impulse_indices=impulses,
    )
    target = _write_imu_session(
        tmp_path / "sessions",
        session_id="equipment-target",
        device_id="pod",
        stream="/equipment/imu/accel",
        times_ns=target_times,
        impulse_indices=impulses,
    )

    windows = []
    for index in sorted(impulses):
        target_center = target_times[index]
        reference_center = reference_times[index]
        windows.append(
            {
                "reference_start_ns": reference_center - 40_000_000,
                "reference_end_ns": reference_center + 40_000_000,
                "target_start_ns": target_center - 40_000_000,
                "target_end_ns": target_center + 40_000_000,
                "uncertainty_ns": 1_000_000,
            }
        )
    return reference, target, windows


def test_generic_clock_sync_recovers_known_drift_and_provenance(tmp_path):
    reference, target, windows = _fixture_sessions(tmp_path)

    receipt = derive_clock_sync(
        SessionReader(reference),
        SessionReader(target),
        windows,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )

    assert receipt.reference.session_id == "watch-reference"
    assert receipt.target.session_id == "equipment-target"
    assert len(receipt.reference.bundle_sha256) == 64
    assert len(receipt.target.bundle_sha256) == 64
    assert receipt.reference.source_evidence_sha256 == {
        "fixture": "watch-reference-source-hash",
    }
    assert receipt.coverage.passed is True
    assert receipt.coverage.observation_count == 3
    assert receipt.coverage.first_position_fraction == pytest.approx(0.05)
    assert receipt.coverage.last_position_fraction == pytest.approx(0.95)
    assert receipt.clock_model.drift_ppm == pytest.approx(25.0, abs=0.01)
    assert receipt.clock_model.residual_rms_ns < 1.0
    assert receipt.clock_model.observations_used == 3


def test_clock_sync_round_trip_receipt_and_observation_reader(tmp_path):
    reference, target, windows = _fixture_sessions(tmp_path)
    windows_path = tmp_path / "windows.json"
    output = tmp_path / "clock-sync.json"
    windows_path.write_text(json.dumps(windows), encoding="utf-8")

    original = write_clock_sync(
        reference,
        target,
        windows_path,
        output,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )
    loaded = load_clock_sync_receipt(output)

    assert loaded.reference == original.reference
    assert loaded.target == original.target
    assert loaded.coverage == original.coverage
    assert loaded.clock_model.drift_ppm == pytest.approx(
        original.clock_model.drift_ppm
    )
    raw = json.loads(output.read_text(encoding="utf-8"))
    assert raw["schema_version"] == "motionos.clock-sync.v1"
    assert len(raw["observations"]) == 3
    parsed = clock_observations_from_json(output)
    assert len(parsed) == 3
    assert parsed[0].device_time_ns == original.observations[0].device_time_ns


def test_legacy_p1_pod_window_names_remain_compatible(tmp_path):
    reference, target, windows = _fixture_sessions(tmp_path)
    legacy = [
        {
            "reference_start_ns": item["reference_start_ns"],
            "reference_end_ns": item["reference_end_ns"],
            "pod_start_ns": item["target_start_ns"],
            "pod_end_ns": item["target_end_ns"],
            "uncertainty_ns": item["uncertainty_ns"],
        }
        for item in windows
    ]

    observations = derive_impulse_clock_observations(
        SessionReader(reference),
        SessionReader(target),
        legacy,
    )

    assert len(observations) == 3
    assert observations[0].device_time_ns == 200_000_000


def test_generic_sync_rejects_clustered_landmarks_structurally(tmp_path):
    reference, target, _ = _fixture_sessions(tmp_path)
    target_times = [200_000_000, 500_000_000, 800_000_000]
    slope = 1.0 + 25e-6
    intercept = 40_000_000
    windows = [
        {
            "reference_start_ns": round(slope * time_ns + intercept) - 40_000_000,
            "reference_end_ns": round(slope * time_ns + intercept) + 40_000_000,
            "target_start_ns": time_ns - 40_000_000,
            "target_end_ns": time_ns + 40_000_000,
        }
        for time_ns in target_times
    ]

    receipt = derive_clock_sync(
        SessionReader(reference),
        SessionReader(target),
        windows,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )

    assert receipt.clock_model.residual_rms_ns < 1.0
    assert receipt.coverage.passed is False


def test_sync_never_searches_outside_declared_windows(tmp_path):
    reference, target, windows = _fixture_sessions(tmp_path)
    windows[1]["target_start_ns"] = 2_900_000_000
    windows[1]["target_end_ns"] = 3_000_000_000

    receipt = derive_clock_sync(
        SessionReader(reference),
        SessionReader(target),
        windows,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )

    assert receipt.landmarks[1].target_device_time_ns >= 2_900_000_000
    assert receipt.landmarks[1].target_device_time_ns <= 3_000_000_000



def test_deliberate_sync_fit_keeps_all_five_landmarks(tmp_path):
    target_times = [index * 100_000_000 for index in range(41)]
    slope = 1.0 + 18e-6
    intercept = 25_000_000
    reference_times = [
        round(slope * time_ns + intercept)
        for time_ns in target_times
    ]
    impulses = {2, 10, 20, 30, 38}

    reference = _write_imu_session(
        tmp_path / "sessions",
        session_id="watch-five",
        device_id="watch",
        stream="/body/watch/imu",
        times_ns=reference_times,
        impulse_indices=impulses,
    )
    target = _write_imu_session(
        tmp_path / "sessions",
        session_id="target-five",
        device_id="pod",
        stream="/equipment/imu/accel",
        times_ns=target_times,
        impulse_indices=impulses,
    )

    windows = []
    for index in sorted(impulses):
        target_center = target_times[index]
        reference_center = reference_times[index]
        windows.append(
            {
                "reference_start_ns": reference_center - 40_000_000,
                "reference_end_ns": reference_center + 40_000_000,
                "target_start_ns": target_center - 40_000_000,
                "target_end_ns": target_center + 40_000_000,
            }
        )

    receipt = derive_clock_sync(
        SessionReader(reference),
        SessionReader(target),
        windows,
        reference_stream="/body/watch/imu",
        target_stream="/equipment/imu/accel",
    )

    assert len(receipt.landmarks) == 5
    assert receipt.clock_model.observations_used == 5
    assert receipt.coverage.passed is True
    assert receipt.clock_model.drift_ppm == pytest.approx(18.0, abs=0.01)
