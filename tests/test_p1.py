import json
from pathlib import Path

import pytest

from motionos.clock import ClockObservation
from motionos.p1 import (
    build_p1_receipt,
    derive_impulse_clock_observations,
    import_pod_journal,
)
from motionos.schema import (
    DeviceDescriptor,
    SensorEvent,
    SessionManifest,
)
from motionos.session import SessionReader, SessionWriter


def _write_pod_bundle(
    directory: Path,
    *,
    hz: float = 100.0,
    duration_s: float = 3.0,
    accel_gap_after: int | None = None,
) -> Path:
    session_id = "p1-fixture"
    journal = directory / "pod.jsonl"
    period_ns = round(1e9 / hz)
    count = int(duration_s * hz) + 1

    with journal.open("w", encoding="utf-8") as handle:
        accel_time = 0
        gyro_time = 0

        for sequence in range(count):
            if sequence > 0:
                accel_time += period_ns
                gyro_time += period_ns
            if accel_gap_after is not None and sequence == accel_gap_after:
                accel_time += 4 * period_ns

            accel = SensorEvent(
                session_id=session_id,
                device_id="metamotion-s",
                stream="/equipment/imu/accel",
                sequence=sequence,
                device_time_ns=accel_time,
                payload={
                    "sensor": "accelerometer",
                    "ax": 0.1,
                    "ay": 0.2,
                    "az": 9.8,
                    "timestamp_basis": "device_tick_ms",
                    "units": "m/s^2",
                    "source": "metamotion_s_bmi270_flash",
                },
            )
            gyro = SensorEvent(
                session_id=session_id,
                device_id="metamotion-s",
                stream="/equipment/imu/gyro",
                sequence=sequence,
                device_time_ns=gyro_time,
                payload={
                    "sensor": "gyroscope",
                    "gx": 0.01,
                    "gy": 0.02,
                    "gz": 0.03,
                    "timestamp_basis": "device_tick_ms",
                    "units": "rad/s",
                    "source": "metamotion_s_bmi270_flash",
                },
            )
            handle.write(accel.to_json() + "\n")
            handle.write(gyro.to_json() + "\n")

    (directory / "pod-metadata.json").write_text(
        json.dumps(
            {
                "schema_version": "motionos.p1.pod.v1",
                "session_id": session_id,
                "device": {
                    "identifier": "00000000-0000-0000-0000-000000000001",
                    "model": "MetaMotion S",
                    "model_number": "8",
                    "serial_number": "fixture",
                    "firmware_revision": "1.7.2",
                    "hardware_revision": "r0.1",
                    "metawear_sdk_revision": (
                        "7dd2a5dbddafb2f8d583cb8d018be476d8ee9a71"
                    ),
                },
                "requested_capture": {
                    "accelerometer_hz": hz,
                    "accelerometer_range_g": 16.0,
                    "gyroscope_hz": hz,
                    "gyroscope_range_dps": 2000.0,
                },
                "recovered_samples": {
                    "accelerometer": count,
                    "gyroscope": count,
                },
                "timestamp_authority": "device_tick_ms",
                "live_preview_timestamp_authority": (
                    "ble_host_arrival_only"
                ),
                "streams": [
                    "/equipment/imu/accel",
                    "/equipment/imu/gyro",
                ],
                "flash_cleared_only_after_successful_dual_download": True,
            }
        ),
        encoding="utf-8",
    )
    return journal


def _sync_observations():
    # 25 ppm board drift plus a fixed 40 ms session-clock offset.
    slope = 1.000025
    intercept_ns = 40_000_000
    device_times = [0, 1_000_000_000, 1_500_000_000, 3_000_000_000]
    return [
        {
            "device_time_ns": t,
            "session_time_ns": round(slope * t + intercept_ns),
            "round_trip_ns": 1_000_000 + index * 100_000,
        }
        for index, t in enumerate(device_times)
    ]


def test_p1_capture_can_pass_without_promoting_timing_claims(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    session_dir = import_pod_journal(journal, tmp_path / "sessions")

    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is True
    assert receipt.timing_gate_frozen is False
    assert receipt.sync_gate_frozen is False
    assert receipt.passed is False
    assert receipt.accel_qc.effective_hz == pytest.approx(100.0)
    assert receipt.gyro_qc.effective_hz == pytest.approx(100.0)
    assert receipt.accel_tick_gaps.estimated_missing_samples == 0
    assert receipt.gyro_tick_gaps.estimated_missing_samples == 0
    assert receipt.metadata_mismatches == ()
    assert receipt.invalid_accel_payloads == 0
    assert receipt.invalid_gyro_payloads == 0
    assert len(receipt.source_evidence_sha256["pod_journal"]) == 64
    assert len(receipt.source_evidence_sha256["pod_metadata"]) == 64


def test_p1_full_receipt_passes_only_with_frozen_timing_and_sync_gates(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    session_dir = import_pod_journal(journal, tmp_path / "sessions")

    observations = _sync_observations()
    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
        rate_tolerance_fraction=0.02,
        max_gap_multiple=1.5,
        sync_observations=[
            ClockObservation(
                device_time_ns=item["device_time_ns"],
                session_time_ns=item["session_time_ns"],
                round_trip_ns=item["round_trip_ns"],
            )
            for item in observations
        ],
        max_sync_residual_ms=1.0,
    )

    assert receipt.capture_passed is True
    assert receipt.timing_gate_frozen is True
    assert receipt.timing_passed is True
    assert receipt.sync_gate_frozen is True
    assert receipt.sync_passed is True
    assert receipt.passed is True
    assert receipt.clock_model is not None
    assert receipt.clock_model.drift_ppm == pytest.approx(25.0, abs=0.01)
    assert receipt.clock_model.residual_rms_ns < 1.0
    assert receipt.sync_landmark_coverage_passed is True
    assert receipt.sync_observation_count == 4
    assert receipt.sync_observation_span_fraction == pytest.approx(1.0)


def test_p1_tick_gap_blocks_timing_gate(tmp_path):
    journal = _write_pod_bundle(
        tmp_path,
        accel_gap_after=120,
    )
    session_dir = import_pod_journal(journal, tmp_path / "sessions")

    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
        rate_tolerance_fraction=0.05,
        max_gap_multiple=1.5,
        sync_observations=[
            ClockObservation(
                device_time_ns=item["device_time_ns"],
                session_time_ns=item["session_time_ns"],
                round_trip_ns=item["round_trip_ns"],
            )
            for item in _sync_observations()
        ],
        max_sync_residual_ms=1.0,
    )

    assert receipt.capture_passed is True
    assert receipt.accel_tick_gaps.gaps_over_1_5x == 1
    assert receipt.accel_tick_gaps.estimated_missing_samples >= 4
    assert receipt.timing_passed is False
    assert receipt.passed is False


def test_p1_missing_metadata_blocks_capture_qualification(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    (tmp_path / "pod-metadata.json").unlink()

    session_dir = import_pod_journal(journal, tmp_path / "sessions")
    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is False
    assert "device.model" in receipt.missing_metadata_fields
    assert "timestamp_authority" in receipt.missing_metadata_fields



def _write_impulse_session(
    root: Path,
    *,
    session_id: str,
    stream: str,
    times_ns: list[int],
    peak_indices: set[int],
):
    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc="2026-09-22T00:00:00+00:00",
        sport="sync-fixture",
        mode="field",
        athlete_id="local-athlete",
        devices=(
            DeviceDescriptor(
                device_id="fixture-device",
                kind="fixture",
                placement="fixture",
                streams=(stream,),
            ),
        ),
    )
    with SessionWriter(root, manifest) as writer:
        for sequence, time_ns in enumerate(times_ns):
            magnitude = 30.0 if sequence in peak_indices else 9.81
            writer.append(
                SensorEvent(
                    session_id=session_id,
                    device_id="fixture-device",
                    stream=stream,
                    sequence=sequence,
                    device_time_ns=time_ns,
                    payload={
                        "ax": magnitude,
                        "ay": 0.0,
                        "az": 0.0,
                    },
                )
            )
    return root / session_id


def test_p1_impulse_windows_pair_two_clock_domains(tmp_path):
    pod_times = [index * 100_000_000 for index in range(41)]
    watch_times = [
        round(1.000025 * value + 40_000_000)
        for value in pod_times
    ]
    peaks = {10, 20, 30}

    watch_dir = _write_impulse_session(
        tmp_path / "watch",
        session_id="watch-sync",
        stream="/body/watch/imu",
        times_ns=watch_times,
        peak_indices=peaks,
    )
    pod_dir = _write_impulse_session(
        tmp_path / "pod",
        session_id="pod-sync",
        stream="/equipment/imu/accel",
        times_ns=pod_times,
        peak_indices=peaks,
    )

    windows = []
    for peak in sorted(peaks):
        windows.append(
            {
                "reference_start_ns": watch_times[peak] - 60_000_000,
                "reference_end_ns": watch_times[peak] + 60_000_000,
                "pod_start_ns": pod_times[peak] - 60_000_000,
                "pod_end_ns": pod_times[peak] + 60_000_000,
                "uncertainty_ns": 2_000_000,
            }
        )

    observations = derive_impulse_clock_observations(
        SessionReader(watch_dir),
        SessionReader(pod_dir),
        windows,
    )

    assert len(observations) == 3
    for observation, peak in zip(observations, sorted(peaks)):
        assert observation.device_time_ns == pod_times[peak]
        assert observation.session_time_ns == watch_times[peak]
        assert observation.round_trip_ns == 2_000_000



def test_p1_clustered_sync_landmarks_do_not_qualify(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    session_dir = import_pod_journal(journal, tmp_path / "sessions")

    clustered = [
        ClockObservation(
            device_time_ns=device_time_ns,
            session_time_ns=device_time_ns + 40_000_000,
            round_trip_ns=1_000_000,
        )
        for device_time_ns in (
            1_000_000_000,
            1_200_000_000,
            1_500_000_000,
        )
    ]

    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
        rate_tolerance_fraction=0.02,
        max_gap_multiple=1.5,
        sync_observations=clustered,
        max_sync_residual_ms=1.0,
    )

    assert receipt.capture_passed is True
    assert receipt.timing_passed is True
    assert receipt.clock_model is not None
    assert receipt.clock_model.residual_rms_ns < 1.0
    assert receipt.sync_landmark_coverage_passed is False
    assert receipt.sync_passed is False
    assert receipt.passed is False


def test_p1_tampered_device_metadata_blocks_capture_qualification(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    metadata_path = tmp_path / "pod-metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["device"]["model"] = "MetaMotion R / RL"
    metadata["device"]["model_number"] = "5"
    metadata["recovered_samples"]["accelerometer"] += 1
    metadata_path.write_text(
        json.dumps(metadata),
        encoding="utf-8",
    )

    session_dir = import_pod_journal(journal, tmp_path / "sessions")
    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is False
    assert "device.model" in receipt.metadata_mismatches
    assert "device.model_number" in receipt.metadata_mismatches
    assert (
        "recovered_samples.accelerometer"
        in receipt.metadata_mismatches
    )


def test_p1_invalid_flash_payload_contract_blocks_capture(tmp_path):
    journal = _write_pod_bundle(tmp_path)
    lines = journal.read_text(encoding="utf-8").splitlines()
    first = json.loads(lines[0])
    first["payload"]["source"] = "ble_live_preview"
    lines[0] = json.dumps(first)
    journal.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )

    session_dir = import_pod_journal(journal, tmp_path / "sessions")
    receipt = build_p1_receipt(
        SessionReader(session_dir),
        min_duration_s=2.0,
    )

    assert receipt.capture_passed is False
    assert receipt.invalid_accel_payloads == 1
