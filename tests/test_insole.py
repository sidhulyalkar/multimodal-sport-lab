from __future__ import annotations

from pathlib import Path

import pytest

from motionos.insole import (
    ACCELERATION_MPS2_PER_G,
    LEFT_IMU_STREAM,
    LEFT_PRESSURE_STREAM,
    PRESSURE_SENSOR_COUNT,
    RADIANS_PER_DEGREE,
    RIGHT_IMU_STREAM,
    RIGHT_PRESSURE_STREAM,
    build_p2_capture_receipt,
    import_opengo_text_export,
    parse_opengo_text_export,
)
from motionos.replay import replay_frames
from motionos.session import SessionReader


def _channels() -> list[str]:
    columns = ["time"]
    for side in ("left", "right"):
        columns.extend(
            f"{side} pressure {index}[N/cm²]"
            for index in range(1, PRESSURE_SENSOR_COUNT + 1)
        )
        columns.extend(
            f"{side} acceleration {axis}[g]"
            for axis in ("X", "Y", "Z")
        )
        columns.extend(
            f"{side} angular {axis}[dps]"
            for axis in ("X", "Y", "Z")
        )
        columns.append(f"{side} total force[N]")
        columns.append(
            f"{side} center of pressure X[-0.5...+0.5]"
        )
        columns.append(
            f"{side} center of pressure Y[-0.5...+0.5]"
        )
    return columns


def _side_values(
    *,
    pressure: float,
    accel: tuple[float, float, float],
    gyro: tuple[float, float, float],
    force: float,
    cop: tuple[float, float],
) -> list[str]:
    values = [f"{pressure + index * 0.01:.4f}" for index in range(16)]
    values.extend(f"{value:.6f}" for value in accel)
    values.extend(f"{value:.6f}" for value in gyro)
    values.append(f"{force:.3f}")
    values.extend(f"{value:.6f}" for value in cop)
    return values


def _blank_side() -> list[str]:
    return [""] * (16 + 3 + 3 + 1 + 2)


def _write_export(
    path: Path,
    *,
    blank_right_middle: bool = False,
    partial_left_pressure_middle: bool = False,
    omit_last_left_pressure_header: bool = False,
    right_serial: str = "SN9171",
) -> None:
    columns = _channels()
    if omit_last_left_pressure_header:
        columns.remove("left pressure 16[N/cm²]")

    left0 = _side_values(
        pressure=1.0,
        accel=(1.0, 0.0, -1.0),
        gyro=(180.0, 0.0, -90.0),
        force=500.0,
        cop=(-0.25, 0.15),
    )
    right0 = _side_values(
        pressure=2.0,
        accel=(-1.0, 0.5, 0.25),
        gyro=(0.0, 45.0, 90.0),
        force=450.0,
        cop=(0.20, -0.10),
    )

    left1 = _side_values(
        pressure=1.2,
        accel=(0.9, 0.1, -0.9),
        gyro=(170.0, 1.0, -80.0),
        force=510.0,
        cop=(-0.20, 0.10),
    )
    if partial_left_pressure_middle:
        left1[7] = ""

    right1 = (
        _blank_side()
        if blank_right_middle
        else _side_values(
            pressure=2.2,
            accel=(-0.9, 0.4, 0.2),
            gyro=(1.0, 44.0, 89.0),
            force=455.0,
            cop=(0.18, -0.09),
        )
    )

    left2 = _side_values(
        pressure=1.4,
        accel=(0.8, 0.2, -0.8),
        gyro=(160.0, 2.0, -70.0),
        force=520.0,
        cop=(-0.15, 0.05),
    )
    right2 = _side_values(
        pressure=2.4,
        accel=(-0.8, 0.3, 0.15),
        gyro=(2.0, 43.0, 88.0),
        force=460.0,
        cop=(0.16, -0.08),
    )

    if omit_last_left_pressure_header:
        # Keep row width aligned with the shortened header.
        for values in (left0, left1, left2):
            del values[15]

    lines = [
        "# Start time: 27.09.2023 10:21:14.922",
        "# Duration: 00:00.020",
        f"# Sensor insoles: Left SN5968, Right {right_serial}",
        "# Size: 7",
        "# Recording type: normal",
        "# Name: fixture",
        "# Notes: MotionOS test",
        "# Tag: fixture",
        "# " + "\t".join(columns),
        "\t".join(["0.00", *left0, *right0]),
        "\t".join(["0.01", *left1, *right1]),
        "\t".join(["0.02", *left2, *right2]),
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_parse_opengo_preserves_side_identity_units_and_gaps(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source, blank_right_middle=True)

    parsed = parse_opengo_text_export(
        source,
        session_id="p2-fixture",
    )

    assert parsed.metadata.serial_numbers == {
        "left": "SN5968",
        "right": "SN9171",
    }
    assert parsed.metadata.sensor_insole_size == 7
    assert len(parsed.source_sha256) == 64

    streams: dict[str, list] = {}
    for event in parsed.events:
        streams.setdefault(event.stream, []).append(event)

    assert len(streams[LEFT_IMU_STREAM]) == 3
    assert len(streams[LEFT_PRESSURE_STREAM]) == 3
    assert len(streams[RIGHT_IMU_STREAM]) == 2
    assert len(streams[RIGHT_PRESSURE_STREAM]) == 2

    left_imu = streams[LEFT_IMU_STREAM][0]
    assert left_imu.device_id == "SN5968"
    assert left_imu.device_time_ns == 0
    assert left_imu.payload["ax"] == pytest.approx(
        ACCELERATION_MPS2_PER_G
    )
    assert left_imu.payload["gx"] == pytest.approx(
        180.0 * RADIANS_PER_DEGREE
    )
    assert left_imu.payload["acceleration_g"] == [1.0, 0.0, -1.0]
    assert left_imu.payload["angular_rate_dps"] == [180.0, 0.0, -90.0]
    assert (
        left_imu.payload["timestamp_basis"]
        == "opengo_export_relative_time"
    )

    left_pressure = streams[LEFT_PRESSURE_STREAM][0]
    assert left_pressure.device_id == "SN5968"
    assert len(left_pressure.payload["pressure_kpa"]) == 16
    assert left_pressure.payload["pressure_n_per_cm2"][0] == 1.0
    assert left_pressure.payload["pressure_kpa"][0] == 10.0
    assert left_pressure.payload["normal_force_n"] == 500.0
    assert left_pressure.payload["cop_x_normalized"] == -0.25
    assert left_pressure.payload["cop_y_normalized"] == 0.15
    assert "cop_x_m" not in left_pressure.payload
    assert "cop_y_m" not in left_pressure.payload

    right_times = [
        event.device_time_ns
        for event in streams[RIGHT_PRESSURE_STREAM]
    ]
    assert right_times == [0, 20_000_000]


def test_import_and_p2_capture_receipt_preserve_bilateral_missing_row(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source, blank_right_middle=True)

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-fixture",
    )
    reader = SessionReader(session_dir)
    receipt = build_p2_capture_receipt(
        reader,
        min_duration_s=0.02,
    )

    assert receipt.capture_passed is True
    assert receipt.invalid_left_imu_samples == 0
    assert receipt.invalid_right_imu_samples == 0
    assert receipt.invalid_left_pressure_samples == 0
    assert receipt.invalid_right_pressure_samples == 0
    assert receipt.identity_errors == ()
    assert receipt.imu_bilateral_overlap.left_count == 3
    assert receipt.imu_bilateral_overlap.right_count == 2
    assert receipt.imu_bilateral_overlap.shared_timestamps == 2
    assert receipt.imu_bilateral_overlap.union_timestamps == 3
    assert receipt.imu_bilateral_overlap.overlap_fraction == pytest.approx(
        2 / 3
    )
    assert receipt.pressure_bilateral_overlap.overlap_fraction == pytest.approx(
        2 / 3
    )
    assert len(
        receipt.source_evidence_sha256["opengo_text_export"]
    ) == 64

    assert reader.manifest.devices[0].device_id == "SN5968"
    assert reader.manifest.devices[0].placement == "left_foot"
    assert reader.manifest.devices[1].device_id == "SN9171"
    assert reader.manifest.devices[1].placement == "right_foot"


def test_partial_pressure_sample_is_rejected_instead_of_filled(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source, partial_left_pressure_middle=True)

    with pytest.raises(ValueError, match="partially missing pressure"):
        parse_opengo_text_export(
            source,
            session_id="p2-fixture",
        )


def test_missing_one_of_sixteen_pressure_headers_is_rejected(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source, omit_last_left_pressure_header=True)

    with pytest.raises(
        ValueError,
        match="left pressure sensor 16",
    ):
        parse_opengo_text_export(
            source,
            session_id="p2-fixture",
        )


def test_capture_receipt_does_not_call_normal_force_full_3d_grf(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source)

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-fixture",
    )
    receipt = build_p2_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=0.02,
    )

    payload = receipt.to_dict()
    claim = str(payload["claim_boundary"]).lower()
    assert "not full 3d ground-reaction force" in claim



def _write_disjoint_export(path: Path) -> None:
    left_a = _side_values(
        pressure=1.0,
        accel=(1.0, 0.0, 0.0),
        gyro=(10.0, 0.0, 0.0),
        force=400.0,
        cop=(-0.2, 0.0),
    )
    left_b = _side_values(
        pressure=1.1,
        accel=(1.0, 0.0, 0.0),
        gyro=(10.0, 0.0, 0.0),
        force=410.0,
        cop=(-0.1, 0.0),
    )
    right_a = _side_values(
        pressure=2.0,
        accel=(-1.0, 0.0, 0.0),
        gyro=(-10.0, 0.0, 0.0),
        force=420.0,
        cop=(0.1, 0.0),
    )
    right_b = _side_values(
        pressure=2.1,
        accel=(-1.0, 0.0, 0.0),
        gyro=(-10.0, 0.0, 0.0),
        force=430.0,
        cop=(0.2, 0.0),
    )

    lines = [
        "# Start time: 27.09.2023 10:21:14.922",
        "# Duration: 00:00.030",
        "# Sensor insoles: Left SN5968, Right SN9171",
        "# Size: 7",
        "# Recording type: normal",
        "# " + "\t".join(_channels()),
        "\t".join(["0.00", *left_a, *_blank_side()]),
        "\t".join(["0.01", *left_b, *_blank_side()]),
        "\t".join(["0.02", *_blank_side(), *right_a]),
        "\t".join(["0.03", *_blank_side(), *right_b]),
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_capture_receipt_rejects_duplicate_left_right_serial_identity(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source, right_serial="SN5968")

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-duplicate-id",
    )
    receipt = build_p2_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=0.02,
    )

    assert receipt.capture_passed is False
    assert receipt.identity_errors == (
        "left/right serial identities are identical",
    )


def test_capture_receipt_rejects_bilateral_session_with_zero_overlap(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_disjoint_export(source)

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-disjoint",
    )
    receipt = build_p2_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=0.01,
    )

    assert receipt.imu_bilateral_overlap.shared_timestamps == 0
    assert receipt.pressure_bilateral_overlap.shared_timestamps == 0
    assert receipt.capture_passed is False


def test_receipt_declares_timestamp_not_sequence_as_gap_authority(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source)

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-authority",
    )
    receipt = build_p2_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=0.02,
    ).to_dict()

    authority = receipt["timing_authority"]
    assert authority["sequence_authority"] == "motionos_import_order_only"
    assert authority["gap_authority"] == "export_timestamp_spacing"



def test_replay_surfaces_all_bilateral_insole_streams(tmp_path):
    source = tmp_path / "opengo.txt"
    _write_export(source)

    session_dir = import_opengo_text_export(
        source,
        tmp_path / "sessions",
        session_id="p2-replay",
    )
    frames = list(
        replay_frames(
            SessionReader(session_dir),
            frame_hz=100.0,
        )
    )

    assert frames
    observed = set().union(*(frame.latest.keys() for frame in frames))
    assert {
        LEFT_IMU_STREAM,
        RIGHT_IMU_STREAM,
        LEFT_PRESSURE_STREAM,
        RIGHT_PRESSURE_STREAM,
    } <= observed
