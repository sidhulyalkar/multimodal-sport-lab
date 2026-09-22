from pathlib import Path

from motionos.p0 import build_p0_receipt, import_watch_journal
from motionos.schema import SensorEvent
from motionos.session import SessionReader


def _write_watch_journal(path: Path, *, drop_imu_sequence: int | None = None) -> None:
    session_id = "p0-fixture"
    with path.open("w", encoding="utf-8") as handle:
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


def test_p0_import_and_receipt_pass(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_watch_journal(journal)

    session_dir = import_watch_journal(journal, tmp_path / "sessions")
    receipt = build_p0_receipt(SessionReader(session_dir), min_duration_s=2.0)

    assert receipt.passed is True
    assert receipt.imu_count == 150
    assert 49.0 <= receipt.imu_effective_hz <= 51.0
    assert receipt.imu_missing_sequences == 0
    assert receipt.hr_count == 3
    assert receipt.raw_device_time_samples == 153
    assert receipt.mapped_session_time_samples == 0


def test_p0_receipt_fails_dropped_watch_sample(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_watch_journal(journal, drop_imu_sequence=40)

    session_dir = import_watch_journal(journal, tmp_path / "sessions")
    receipt = build_p0_receipt(SessionReader(session_dir), min_duration_s=2.0)

    assert receipt.passed is False
    assert receipt.imu_missing_sequences == 1
