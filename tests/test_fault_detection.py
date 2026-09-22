from motionos.faults import (
    add_time_gap,
    degrade_sync_quality,
    drop_sequences,
    duplicate_sequence,
    reverse_timestamp_pair,
)
from motionos.qc import inspect_stream
from motionos.schema import SensorEvent


def _events(count=20):
    return [
        SensorEvent(
            session_id="s",
            device_id="pod",
            stream="/equipment/imu",
            sequence=i,
            device_time_ns=i * 10_000_000,
            session_time_ns=i * 10_000_000,
            sync_quality=1.0,
            payload={"ax": 0.0, "ay": 0.0, "az": 9.81},
        )
        for i in range(count)
    ]


def test_qc_detects_missing_sequence():
    report = inspect_stream("/equipment/imu", drop_sequences(_events(), {4, 5}))
    assert report.missing_sequences == 2


def test_qc_detects_duplicate_as_non_monotonic_time():
    report = inspect_stream("/equipment/imu", duplicate_sequence(_events(), 7))
    assert report.non_monotonic_timestamps >= 1


def test_qc_detects_timestamp_reversal():
    report = inspect_stream("/equipment/imu", reverse_timestamp_pair(_events(), 8))
    assert report.non_monotonic_timestamps >= 1


def test_qc_surfaces_transport_gap():
    report = inspect_stream(
        "/equipment/imu",
        add_time_gap(_events(), from_sequence=10, gap_ns=250_000_000),
    )
    assert report.max_gap_ms is not None
    assert report.max_gap_ms >= 250


def test_sync_quality_degradation_is_visible():
    report = inspect_stream(
        "/equipment/imu",
        degrade_sync_quality(_events(), factor=0.2),
    )
    assert report.mean_sync_quality is not None
    assert abs(report.mean_sync_quality - 0.2) < 1e-9
