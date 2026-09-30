import json
from pathlib import Path

from motionos.p0 import import_watch_journal
from motionos.schema import SensorEvent
from motionos.session import SessionReader
from motionos.watch_smoke import build_watch_smoke_report


def _write_smoke_journal(
    path: Path,
    *,
    imu_hz: float = 50.0,
    duration_s: float = 4.0,
    include_hr: bool = True,
    drop_sequence: int | None = None,
) -> None:
    session_id = "smoke-watch-fixture"
    sample_count = int(imu_hz * duration_s)
    dt_ns = int(1_000_000_000 / imu_hz)

    with path.open("w", encoding="utf-8") as handle:
        metadata = SensorEvent(
            session_id=session_id,
            device_id="apple-watch",
            stream="/meta/watch",
            sequence=0,
            device_time_ns=1,
            payload={
                "model": "Apple Watch",
                "system_version": "26.0",
                "requested_imu_hz": 50.0,
            },
        )
        handle.write(metadata.to_json() + "\n")

        for sequence in range(sample_count):
            if sequence == drop_sequence:
                continue
            event = SensorEvent(
                session_id=session_id,
                device_id="apple-watch",
                stream="/body/watch/imu",
                sequence=sequence,
                device_time_ns=sequence * dt_ns,
                payload={
                    "ax": 0.0,
                    "ay": 0.0,
                    "az": 9.80665,
                    "gx": 0.0,
                    "gy": 0.0,
                    "gz": 0.0,
                },
            )
            handle.write(event.to_json() + "\n")

        if include_hr:
            for sequence in range(3):
                event = SensorEvent(
                    session_id=session_id,
                    device_id="apple-watch",
                    stream="/body/watch/hr",
                    sequence=sequence,
                    device_time_ns=sequence * 1_000_000_000,
                    payload={"bpm": 100 + sequence},
                )
                handle.write(event.to_json() + "\n")


def _report(
    tmp_path: Path,
    **journal_kwargs,
):
    journal = tmp_path / "watch.jsonl"
    _write_smoke_journal(journal, **journal_kwargs)
    session = import_watch_journal(journal, tmp_path / "sessions")
    return build_watch_smoke_report(
        SessionReader(session),
        min_duration_s=2.0,
    )


def test_watch_smoke_passes_without_iphone_metadata(tmp_path):
    report = _report(tmp_path)

    assert report.smoke_ok is True
    assert report.imu_rate_ok is True
    assert 49.0 <= report.imu_effective_hz <= 51.0
    assert report.imu_missing_sequences == 0
    assert report.heart_rate_observed is True
    assert report.missing_core_streams == ()
    assert len(report.bundle_sha256) == 64


def test_watch_smoke_hr_is_optional_by_default(tmp_path):
    report = _report(tmp_path, include_hr=False)

    assert report.smoke_ok is True
    assert report.heart_rate_observed is False


def test_watch_smoke_can_require_heart_rate(tmp_path):
    journal = tmp_path / "watch.jsonl"
    _write_smoke_journal(journal, include_hr=False)
    session = import_watch_journal(journal, tmp_path / "sessions")

    report = build_watch_smoke_report(
        SessionReader(session),
        min_duration_s=2.0,
        require_hr=True,
    )

    assert report.smoke_ok is False
    assert report.heart_rate_observed is False


def test_watch_smoke_fails_sequence_gap(tmp_path):
    report = _report(tmp_path, drop_sequence=50)

    assert report.smoke_ok is False
    assert report.imu_missing_sequences == 1


def test_watch_smoke_fails_large_rate_error(tmp_path):
    report = _report(tmp_path, imu_hz=25.0)

    assert report.smoke_ok is False
    assert report.imu_rate_ok is False


def test_watch_smoke_report_is_explicitly_non_qualifying(tmp_path):
    report = _report(tmp_path)
    payload = report.to_dict()

    assert payload["protocol"] == "watch-smoke-v1"
    assert "non-qualifying" in payload["claim_boundary"]
    assert "not a P0 qualification" in payload["claim_boundary"]

    serialized = json.dumps(payload)
    assert "physiological accuracy" in serialized
