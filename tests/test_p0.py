import json
from pathlib import Path

from motionos.p0 import build_p0_receipt, import_watch_journal
from motionos.schema import SensorEvent
from motionos.session import SessionReader


def _write_watch_journal(
    path: Path,
    *,
    drop_imu_sequence: int | None = None,
    include_host_metadata: bool = True,
) -> None:
    session_id = "p0-fixture"
    with path.open("w", encoding="utf-8") as handle:
        metadata = SensorEvent(
            session_id=session_id,
            device_id="apple-watch",
            stream="/meta/watch",
            sequence=0,
            device_time_ns=1,
            payload={
                "device_name": "Apple Watch",
                "model": "Apple Watch",
                "localized_model": "Apple Watch",
                "system_name": "watchOS",
                "system_version": "26.0",
                "requested_imu_hz": 50.0,
                "app_version": "0.1",
                "app_build": "1",
                "wrist_location": "left",
                "crown_orientation": "right",
            },
        )
        handle.write(metadata.to_json() + "\n")

        for sequence in range(150):
            if sequence == drop_imu_sequence:
                continue
            event = SensorEvent(
                session_id=session_id,
                device_id="apple-watch",
                stream="/body/watch/imu",
                sequence=sequence,
                device_time_ns=sequence * 20_000_000,
                payload={
                    "user_ax": 0.1,
                    "user_ay": 0.0,
                    "user_az": 0.0,
                    "gx": 0.0,
                    "gy": 0.0,
                    "gz": 0.0,
                },
            )
            handle.write(event.to_json() + "\n")

        for sequence in range(3):
            event = SensorEvent(
                session_id=session_id,
                device_id="apple-watch",
                stream="/body/watch/hr",
                sequence=sequence,
                device_time_ns=sequence * 1_000_000_000,
                payload={"bpm": 120 + sequence},
            )
            handle.write(event.to_json() + "\n")

    if include_host_metadata:
        path.with_name("iphone-host.json").write_text(
            json.dumps(
                {
                    "session_id": session_id,
                    "iphone_model": "iPhone",
                    "iphone_localized_model": "iPhone",
                    "iphone_system_name": "iOS",
                    "iphone_system_version": "26.0",
                    "app_version": "0.1",
                    "app_build": "1",
                }
            ),
            encoding="utf-8",
        )


def test_p0_import_and_receipt_pass(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_watch_journal(journal)

    session_dir = import_watch_journal(journal, tmp_path / "sessions")
    reader = SessionReader(session_dir)
    receipt = build_p0_receipt(reader, min_duration_s=2.0)

    assert receipt.passed is True
    assert receipt.imu_count == 150
    assert 49.0 <= receipt.imu_effective_hz <= 51.0
    assert receipt.imu_missing_sequences == 0
    assert receipt.imu_median_dt_ms == 20.0
    assert receipt.imu_max_gap_ms == 20.0
    assert receipt.hr_count == 3
    assert receipt.raw_device_time_samples == 153
    assert receipt.mapped_session_time_samples == 0
    assert receipt.watch_model == "Apple Watch"
    assert receipt.watch_system_version == "26.0"
    assert receipt.requested_imu_hz == 50.0
    assert receipt.iphone_system_version == "26.0"
    assert receipt.missing_environment_fields == ()
    assert reader.manifest.devices[0].model == "Apple Watch"
    assert reader.manifest.devices[0].firmware == "26.0"
    hashes = reader.manifest.metadata["source_evidence_sha256"]
    assert len(hashes["watch_journal"]) == 64
    assert len(hashes["iphone_host_metadata"]) == 64


def test_p0_receipt_fails_dropped_watch_sample(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_watch_journal(journal, drop_imu_sequence=40)

    session_dir = import_watch_journal(journal, tmp_path / "sessions")
    receipt = build_p0_receipt(SessionReader(session_dir), min_duration_s=2.0)

    assert receipt.passed is False
    assert receipt.imu_missing_sequences == 1


def test_p0_receipt_fails_without_iphone_environment(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_watch_journal(journal, include_host_metadata=False)

    session_dir = import_watch_journal(journal, tmp_path / "sessions")
    receipt = build_p0_receipt(SessionReader(session_dir), min_duration_s=2.0)

    assert receipt.passed is False
    assert receipt.missing_environment_fields == ("iphone_system_version",)
