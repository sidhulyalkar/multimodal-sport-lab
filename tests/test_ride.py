from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.calibration import build_calibration_bundle
from motionos.clock_sync import write_clock_sync
from motionos.ride import (
    REQUIRED_MOVEMENT_STAGES,
    build_first_ride_report,
)
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionWriter


SLOPE = 1.0 + 20e-6
INTERCEPT_NS = 50_000_000
IMPULSE_INDICES = {2, 20, 38}


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    stream: str,
    reference: bool = False,
    camera: bool = False,
    gap: bool = False,
) -> Path:
    base_times = [index * 100_000_000 for index in range(41)]
    if gap:
        base_times = [
            value
            for index, value in enumerate(base_times)
            if index not in {25, 26, 27, 28}
        ]

    times = (
        [
            round(SLOPE * value + INTERCEPT_NS)
            for value in base_times
        ]
        if reference
        else base_times
    )

    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport="longboard",
        mode="calibration",
        athlete_id="fixture",
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="fixture",
                placement="fixture",
                streams=(stream,),
            ),
        ),
        metadata={
            "source_evidence_sha256": {
                "fixture": f"{session_id}-source",
            },
        },
    )

    with SessionWriter(root, manifest) as writer:
        for sequence, time_ns in enumerate(times):
            if reference:
                target_time = round(
                    (time_ns - INTERCEPT_NS) / SLOPE
                )
            else:
                target_time = time_ns
            original_index = round(target_time / 100_000_000)
            impulse = (
                30.0 if original_index in IMPULSE_INDICES else 1.0
            )

            payload = (
                {
                    "motion_m": impulse,
                    "derived": True,
                }
                if camera
                else {
                    "ax": impulse,
                    "ay": 0.0,
                    "az": 0.0,
                }
            )
            writer.append(
                SensorEvent(
                    session_id=session_id,
                    device_id=device_id,
                    stream=stream,
                    sequence=sequence,
                    device_time_ns=time_ns,
                    payload=payload,
                )
            )
        writer.write_metadata(
            "fixture",
            {"session_id": session_id},
        )

    return root / session_id


def _windows() -> list[dict[str, int]]:
    windows = []
    for index in sorted(IMPULSE_INDICES):
        target = index * 100_000_000
        reference = round(SLOPE * target + INTERCEPT_NS)
        windows.append(
            {
                "reference_start_ns": reference - 40_000_000,
                "reference_end_ns": reference + 40_000_000,
                "target_start_ns": target - 40_000_000,
                "target_end_ns": target + 40_000_000,
                "uncertainty_ns": 1_000_000,
            }
        )
    return windows


def _write_receipt(
    path: Path,
    *,
    protocol: str,
    session_id: str,
    pass_field: str,
    passed: bool,
) -> None:
    path.write_text(
        json.dumps(
            {
                "protocol": protocol,
                "session_id": session_id,
                pass_field: passed,
            }
        ),
        encoding="utf-8",
    )


def _write_body_model(path: Path, *, model_id: str = "body-fixture") -> None:
    path.write_text(
        json.dumps(
            {
                "model_id": model_id,
                "height_m": 1.75,
                "segments_m": {
                    "torso": 0.50,
                    "left_thigh": 0.42,
                    "right_thigh": 0.42,
                    "left_shank": 0.43,
                    "right_shank": 0.43,
                },
                "joint_limits_deg": {},
                "metadata": {
                    "source": "fixture",
                },
            }
        ),
        encoding="utf-8",
    )


def _write_movement_log(
    path: Path,
    *,
    missing_stage: str | None = None,
) -> None:
    stages = [
        {
            "id": stage,
            "completed": True,
            "notes": "",
        }
        for stage in REQUIRED_MOVEMENT_STAGES
        if stage != missing_stage
    ]
    path.write_text(
        json.dumps(
            {
                "schema_version": "motionos.first-ride-log.v1",
                "ride_id": "ride-fixture",
                "stages": stages,
            }
        ),
        encoding="utf-8",
    )


def _build_fixture(
    tmp_path: Path,
    *,
    failed_equipment_receipt: bool = False,
    missing_stage: str | None = None,
    equipment_gap: bool = False,
) -> dict[str, Path]:
    sessions = tmp_path / "sessions"
    artifacts = tmp_path / "artifacts"
    profiles = tmp_path / "profiles"
    output = tmp_path / "calibration"
    for directory in (artifacts, profiles, output):
        directory.mkdir(parents=True, exist_ok=True)

    watch = _write_session(
        sessions,
        session_id="watch-session",
        device_id="watch",
        stream="/body/watch/imu",
        reference=True,
    )
    equipment = _write_session(
        sessions,
        session_id="equipment-session",
        device_id="pod",
        stream="/equipment/imu/accel",
        gap=equipment_gap,
    )
    insoles = _write_session(
        sessions,
        session_id="insole-session",
        device_id="insoles",
        stream="/body/left_foot/imu",
    )
    camera = _write_session(
        sessions,
        session_id="camera-session",
        device_id="camera",
        stream="/camera/pose_motion",
        camera=True,
    )

    windows_path = artifacts / "windows.json"
    windows_path.write_text(
        json.dumps(_windows()),
        encoding="utf-8",
    )

    sync_paths: dict[str, Path] = {}
    for role, target, stream, keys in (
        (
            "equipment",
            equipment,
            "/equipment/imu/accel",
            ("ax", "ay", "az"),
        ),
        (
            "insoles",
            insoles,
            "/body/left_foot/imu",
            ("ax", "ay", "az"),
        ),
        (
            "camera",
            camera,
            "/camera/pose_motion",
            ("motion_m",),
        ),
    ):
        sync = artifacts / f"{role}-sync.json"
        write_clock_sync(
            watch,
            target,
            windows_path,
            sync,
            reference_stream="/body/watch/imu",
            target_stream=stream,
            target_peak_keys=keys,
        )
        sync_paths[role] = sync

    receipts = {
        "watch": artifacts / "p0.json",
        "equipment": artifacts / "p1.json",
        "insoles": artifacts / "p2.json",
        "camera": artifacts / "camera.json",
    }
    _write_receipt(
        receipts["watch"],
        protocol="P0",
        session_id="watch-session",
        pass_field="passed",
        passed=True,
    )
    _write_receipt(
        receipts["equipment"],
        protocol="P1",
        session_id="equipment-session",
        pass_field="passed",
        passed=not failed_equipment_receipt,
    )
    _write_receipt(
        receipts["insoles"],
        protocol="P2-capture",
        session_id="insole-session",
        pass_field="capture_passed",
        passed=True,
    )
    _write_receipt(
        receipts["camera"],
        protocol="P5A-camera",
        session_id="camera-session",
        pass_field="passed",
        passed=True,
    )

    profile_paths = {
        "equipment_mount": profiles / "equipment.json",
        "left_insole_geometry": profiles / "left.json",
        "right_insole_geometry": profiles / "right.json",
        "body_model": profiles / "body.json",
    }
    profile_paths["equipment_mount"].write_text(
        json.dumps({"schema_version": "fixture.equipment.v1"}),
        encoding="utf-8",
    )
    profile_paths["left_insole_geometry"].write_text(
        json.dumps({"schema_version": "fixture.insole.v1", "side": "left"}),
        encoding="utf-8",
    )
    profile_paths["right_insole_geometry"].write_text(
        json.dumps({"schema_version": "fixture.insole.v1", "side": "right"}),
        encoding="utf-8",
    )
    _write_body_model(profile_paths["body_model"])

    calibration_spec = tmp_path / "calibration-spec.json"
    calibration_spec.write_text(
        json.dumps(
            {
                "reference": {
                    "role": "watch",
                    "session": str(watch),
                },
                "sources": [
                    {
                        "role": "watch",
                        "session": str(watch),
                        "receipt": str(receipts["watch"]),
                    },
                    {
                        "role": "equipment",
                        "session": str(equipment),
                        "receipt": str(receipts["equipment"]),
                        "clock_sync": str(sync_paths["equipment"]),
                    },
                    {
                        "role": "insoles",
                        "session": str(insoles),
                        "receipt": str(receipts["insoles"]),
                        "clock_sync": str(sync_paths["insoles"]),
                    },
                    {
                        "role": "camera",
                        "session": str(camera),
                        "receipt": str(receipts["camera"]),
                        "clock_sync": str(sync_paths["camera"]),
                    },
                ],
                "profiles": [
                    {
                        "kind": kind,
                        "path": str(path),
                    }
                    for kind, path in profile_paths.items()
                ],
            }
        ),
        encoding="utf-8",
    )
    calibration_bundle = output / "calibration.json"
    build_calibration_bundle(
        calibration_spec,
        calibration_bundle,
    )

    movement_log = tmp_path / "movement-log.json"
    _write_movement_log(
        movement_log,
        missing_stage=missing_stage,
    )

    ride_spec = tmp_path / "first-ride-spec.json"
    ride_spec.write_text(
        json.dumps(
            {
                "calibration_bundle": str(calibration_bundle),
                "body_model": str(profile_paths["body_model"]),
                "movement_log": str(movement_log),
            }
        ),
        encoding="utf-8",
    )

    return {
        "ride_spec": ride_spec,
        "calibration_bundle": calibration_bundle,
        "body_model": profile_paths["body_model"],
        "movement_log": movement_log,
        **{
            f"{role}_receipt": path
            for role, path in receipts.items()
        },
    }


def _freeze_gates(spec_path: Path, *, residual_ms: float, gap: float) -> None:
    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    raw["timing_gates"] = {
        role: {"max_sync_residual_ms": residual_ms}
        for role in ("equipment", "insoles", "camera")
    }
    raw["max_gap_multiple"] = gap
    spec_path.write_text(json.dumps(raw), encoding="utf-8")


def test_first_ride_evidence_can_complete_before_thresholds_are_frozen(
    tmp_path,
):
    fixture = _build_fixture(tmp_path)
    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "first-ride-report.json",
    )

    assert report.evidence_complete is True
    assert report.timing_gates_frozen is False
    assert report.gap_gate_frozen is False
    assert report.qualified is False
    assert report.missing_roles == ()
    assert report.missing_profile_kinds == ()
    assert report.body_model.bound_to_calibration_bundle is True
    assert report.movement_protocol.completed is True
    assert {receipt.role for receipt in report.receipts} == {
        "watch",
        "equipment",
        "insoles",
        "camera",
    }
    assert all(receipt.passed for receipt in report.receipts)
    assert len(report.clocks) == 3
    assert all(clock.structural_coverage_passed for clock in report.clocks)
    assert all(clock.model_matches_bundle for clock in report.clocks)


def test_first_ride_qualifies_only_after_explicit_gates_pass(tmp_path):
    fixture = _build_fixture(tmp_path)
    _freeze_gates(
        fixture["ride_spec"],
        residual_ms=1.0,
        gap=2.0,
    )

    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "qualified.json",
    )

    assert report.evidence_complete is True
    assert report.timing_gates_frozen is True
    assert report.timing_passed is True
    assert report.gap_gate_frozen is True
    assert report.gap_passed is True
    assert report.qualified is True
    assert all(
        clock.threshold_passed is True
        for clock in report.clocks
    )


def test_failed_role_receipt_blocks_evidence_completion(tmp_path):
    fixture = _build_fixture(
        tmp_path,
        failed_equipment_receipt=True,
    )
    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "report.json",
    )

    equipment = next(
        receipt
        for receipt in report.receipts
        if receipt.role == "equipment"
    )
    assert equipment.passed is False
    assert "passed is not true" in equipment.errors
    assert report.evidence_complete is False
    assert report.qualified is False


def test_missing_movement_stage_blocks_evidence_completion(tmp_path):
    fixture = _build_fixture(
        tmp_path,
        missing_stage="braking",
    )
    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "report.json",
    )

    assert report.movement_protocol.completed is False
    assert report.movement_protocol.missing_stages == ("braking",)
    assert report.evidence_complete is False


def test_body_model_must_be_bound_to_calibration_bundle(tmp_path):
    fixture = _build_fixture(tmp_path)
    alternate = tmp_path / "alternate-body.json"
    _write_body_model(alternate, model_id="alternate")

    raw = json.loads(
        fixture["ride_spec"].read_text(encoding="utf-8")
    )
    raw["body_model"] = str(alternate)
    fixture["ride_spec"].write_text(
        json.dumps(raw),
        encoding="utf-8",
    )

    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "report.json",
    )

    assert report.body_model.bound_to_calibration_bundle is False
    assert report.evidence_complete is False


def test_tampered_stored_clock_model_fails_closed(tmp_path):
    fixture = _build_fixture(tmp_path)
    raw = json.loads(
        fixture["calibration_bundle"].read_text(encoding="utf-8")
    )
    equipment = next(
        source
        for source in raw["sources"]
        if source["role"] == "equipment"
    )
    equipment["clock_model"]["slope"] = 1.25
    fixture["calibration_bundle"].write_text(
        json.dumps(raw),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="stored calibration clock model changed",
    ):
        build_first_ride_report(
            fixture["ride_spec"],
            tmp_path / "report.json",
        )


def test_frozen_gap_gate_rejects_large_timestamp_hole(tmp_path):
    fixture = _build_fixture(
        tmp_path,
        equipment_gap=True,
    )
    _freeze_gates(
        fixture["ride_spec"],
        residual_ms=1.0,
        gap=2.0,
    )

    report = build_first_ride_report(
        fixture["ride_spec"],
        tmp_path / "report.json",
    )

    assert report.evidence_complete is True
    assert any(
        gap.role == "equipment"
        and gap.gap_multiple > 2.0
        for gap in report.gaps
    )
    assert report.gap_passed is False
    assert report.qualified is False
