from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path

import pytest

from motionos.calibration import (
    ArtifactReference,
    CalibrationBundle,
    CalibrationSource,
)
from motionos.calibration_run import (
    build_calibration_report,
    build_calibration_run,
    build_replay_lab_payload,
    load_calibration_run,
)
from motionos.clock import ClockModel
from motionos.provenance import (
    session_evidence_sha256,
    sha256_file,
)
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter


def _write_session(
    root: Path,
    *,
    session_id: str,
    device_id: str,
    streams: dict[str, list[tuple[int, dict[str, object]]]],
) -> Path:
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
                streams=tuple(streams),
            ),
        ),
        metadata={
            "source_evidence_sha256": {
                "fixture": session_id + "-source",
            },
        },
    )

    with SessionWriter(root, manifest) as writer:
        for stream, samples in streams.items():
            for sequence, (time_ns, payload) in enumerate(samples):
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


def _relative(path: Path, base: Path) -> str:
    return os.path.relpath(path.resolve(), base.resolve())


def _artifact(path: Path, base: Path, kind: str) -> ArtifactReference:
    return ArtifactReference(
        path=_relative(path, base),
        sha256=sha256_file(path),
        kind=kind,
    )


def _build_four_role_fixture(tmp_path: Path) -> tuple[Path, Path]:
    sessions = tmp_path / "sessions"
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()

    watch = _write_session(
        sessions,
        session_id="watch-session",
        device_id="watch",
        streams={
            "/body/watch/imu": [
                (
                    0,
                    {
                        "ax": 0.0,
                        "ay": 0.0,
                        "az": 9.80665,
                        "gx": 0.1,
                        "gy": 0.2,
                        "gz": 0.3,
                    },
                ),
                (
                    1_000_000_000,
                    {
                        "ax": 1.0,
                        "ay": 0.0,
                        "az": 9.8,
                        "gx": 0.2,
                        "gy": 0.1,
                        "gz": 0.4,
                    },
                ),
            ],
            "/body/watch/hr": [
                (100_000_000, {"bpm": 132.0}),
                (1_100_000_000, {"bpm": 138.0}),
            ],
        },
    )
    equipment = _write_session(
        sessions,
        session_id="equipment-session",
        device_id="pod",
        streams={
            "/equipment/imu/accel": [
                (100_000_000, {"ax": 3.0, "ay": 4.0, "az": 0.0}),
                (200_000_000, {"ax": 0.0, "ay": 0.0, "az": 9.8}),
                (600_000_000, {"ax": 1.0, "ay": 2.0, "az": 3.0}),
            ],
            "/equipment/imu/gyro": [
                (100_000_000, {"gx": 0.0, "gy": 0.0, "gz": 2.0}),
                (200_000_000, {"gx": 0.0, "gy": 1.0, "gz": 0.0}),
                (600_000_000, {"gx": 1.0, "gy": 0.0, "gz": 0.0}),
            ],
        },
    )
    insoles = _write_session(
        sessions,
        session_id="insole-session",
        device_id="insoles",
        streams={
            "/body/left_foot/pressure": [
                (
                    100_000_000,
                    {
                        "pressure_kpa": [10.0] * 16,
                        "normal_force_n": 400.0,
                        "cop_x_normalized": -0.1,
                        "cop_y_normalized": 0.2,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
                (
                    200_000_000,
                    {
                        "pressure_kpa": [11.0] * 16,
                        "normal_force_n": 420.0,
                        "cop_x_normalized": -0.08,
                        "cop_y_normalized": 0.18,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
                (
                    600_000_000,
                    {
                        "pressure_kpa": [12.0] * 16,
                        "normal_force_n": 430.0,
                        "cop_x_normalized": -0.05,
                        "cop_y_normalized": 0.15,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
            ],
            "/body/right_foot/pressure": [
                (
                    100_000_000,
                    {
                        "pressure_kpa": [20.0] * 16,
                        "normal_force_n": 600.0,
                        "cop_x_normalized": 0.1,
                        "cop_y_normalized": 0.2,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
                (
                    200_000_000,
                    {
                        "pressure_kpa": [21.0] * 16,
                        "normal_force_n": 580.0,
                        "cop_x_normalized": 0.08,
                        "cop_y_normalized": 0.18,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
                (
                    600_000_000,
                    {
                        "pressure_kpa": [22.0] * 16,
                        "normal_force_n": 570.0,
                        "cop_x_normalized": 0.05,
                        "cop_y_normalized": 0.15,
                        "cop_coordinate_basis":
                            "normalized_insole_-0.5_to_0.5",
                    },
                ),
            ],
            "/body/left_foot/imu": [
                (
                    100_000_000,
                    {
                        "ax": 0.0,
                        "ay": 0.0,
                        "az": 9.8,
                        "gx": 0.0,
                        "gy": 0.1,
                        "gz": 0.0,
                    },
                ),
            ],
            "/body/right_foot/imu": [
                (
                    100_000_000,
                    {
                        "ax": 0.0,
                        "ay": 0.0,
                        "az": 9.8,
                        "gx": 0.0,
                        "gy": -0.1,
                        "gz": 0.0,
                    },
                ),
            ],
        },
    )
    camera = _write_session(
        sessions,
        session_id="camera-session",
        device_id="camera",
        streams={
            "/camera/frame": [
                (
                    100_000_000,
                    {
                        "pose_status": "detected",
                        "video_written": True,
                    },
                ),
            ],
            "/camera/pose3d": [
                (
                    100_000_000,
                    {
                        "joints_root_relative_m": {
                            "root": [0.0, 0.0, 0.0],
                            "head": [0.0, 1.7, 0.0],
                            "leftHand": [-0.5, 1.0, 0.1],
                            "rightHand": [0.5, 1.0, -0.1],
                        },
                        "joint_parents": {
                            "root": None,
                            "head": "root",
                            "leftHand": "root",
                            "rightHand": "root",
                        },
                        "body_height_m": 1.8,
                        "joint_coordinate_frame":
                            "vision_root_joint_relative_meters",
                        "camera_origin_matrix": [
                            [1.0, 0.0, 0.0, 0.1],
                            [0.0, 1.0, 0.0, 0.0],
                            [0.0, 0.0, 1.0, 2.0],
                            [0.0, 0.0, 0.0, 1.0],
                        ],
                    },
                ),
            ],
        },
    )

    receipt_paths: dict[str, Path] = {}
    sync_paths: dict[str, Path] = {}
    for role in ("watch", "equipment", "insoles", "camera"):
        receipt = artifacts / f"{role}-receipt.json"
        receipt_payload: dict[str, object] = {
            "protocol": role + "-fixture",
            "passed": True,
        }
        if role == "insoles":
            receipt_payload["bilateral_overlap"] = {
                "pressure": {
                    "shared_timestamps": 3,
                    "union_timestamps": 3,
                    "overlap_fraction": 1.0,
                }
            }
        if role == "camera":
            receipt_payload["counts"] = {
                "delivered_frames": 3,
                "dropped_frames": 1,
                "pose_detected_frames": 1,
            }
            receipt_payload["pose_evidence_present"] = True

        receipt.write_text(
            json.dumps(receipt_payload),
            encoding="utf-8",
        )
        receipt_paths[role] = receipt
        if role != "watch":
            sync = artifacts / f"{role}-sync.json"
            sync.write_text(
                json.dumps(
                    {
                        "schema_version": "fixture.sync.v1",
                        "role": role,
                    }
                ),
                encoding="utf-8",
            )
            sync_paths[role] = sync

    bundle_dir = tmp_path / "bundle"
    bundle_dir.mkdir()
    bundle_path = bundle_dir / "calibration.json"

    source_paths = {
        "watch": watch,
        "equipment": equipment,
        "insoles": insoles,
        "camera": camera,
    }
    sources = []
    for role in ("watch", "equipment", "insoles", "camera"):
        reader = SessionReader(source_paths[role])
        model = (
            None
            if role == "watch"
            else ClockModel(
                slope=1.0,
                intercept_ns=0.0,
                residual_rms_ns=2_000_000.0,
                observations_used=3,
            )
        )
        sources.append(
            CalibrationSource(
                role=role,
                session_path=_relative(source_paths[role], bundle_dir),
                session_id=reader.manifest.session_id,
                bundle_sha256=session_evidence_sha256(reader),
                source_evidence_sha256={
                    "fixture": reader.manifest.session_id + "-source",
                },
                streams=tuple(reader.list_streams()),
                receipt=_artifact(
                    receipt_paths[role],
                    bundle_dir,
                    role + "_receipt",
                ),
                clock_sync=(
                    None
                    if role == "watch"
                    else _artifact(
                        sync_paths[role],
                        bundle_dir,
                        role + "_clock_sync",
                    )
                ),
                clock_model=model,
                mapping_quality=(1.0 if model is None else model.quality),
            )
        )

    bundle = CalibrationBundle(
        reference_role="watch",
        reference_session_id="watch-session",
        sources=tuple(sources),
        profiles=(),
    )
    bundle_path.write_text(
        json.dumps(bundle.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    operator_journal = artifacts / "operator-events.jsonl"
    operator_journal.write_text(
        "{\"schema_version\":\"motionos.operator-events.v1\"}\n",
        encoding="utf-8",
    )
    operator_metadata = artifacts / "operator-metadata.json"
    operator_metadata.write_text(
        json.dumps(
            {
                "schema_version": "motionos.operator-metadata.v1",
                "source": "synthetic-test-only",
            }
        ),
        encoding="utf-8",
    )

    body_model = artifacts / "body-model.json"
    body_model.write_text(
        json.dumps(
            {
                "schema_version": "motionos.body-model.fixture.v1",
                "source": "synthetic-test-only",
            }
        ),
        encoding="utf-8",
    )

    spec = tmp_path / "run-spec.json"
    spec.write_text(
        json.dumps(
            {
                "run_id": "longboard-calibration-001",
                "sport": "longboard",
                "protocol_version": "motionos.longboard-calibration.v1",
                "calibration_bundle": str(bundle_path),
                "profiles": [
                    {
                        "kind": "body_model",
                        "path": str(body_model),
                    }
                ],
                "artifacts": [
                    {
                        "kind": "operator_events",
                        "path": str(operator_journal),
                    },
                    {
                        "kind": "operator_metadata",
                        "path": str(operator_metadata),
                    }
                ],
                "movement_blocks": [
                    {
                        "id": "quiet-stance",
                        "label": "30 s quiet stance",
                    },
                    {
                        "id": "carves",
                        "label": "left/right carves",
                    },
                ],
                "sync_landmarks": [
                    {"label": "start"},
                    {"label": "middle"},
                    {"label": "end"},
                ],
                "notes": ["synthetic fixture"],
                "failure_modes": [],
            }
        ),
        encoding="utf-8",
    )

    run_path = tmp_path / "run" / "run.json"
    return spec, run_path


def test_run_manifest_report_and_replay_are_hash_verified(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)

    run = build_calibration_run(spec, run_path)
    loaded = load_calibration_run(run_path)

    assert loaded == run
    assert run.run_id == "longboard-calibration-001"
    assert run.source_roles == (
        "watch",
        "equipment",
        "insoles",
        "camera",
    )
    assert run.profiles[0].kind == "body_model"
    assert len(run.profiles[0].sha256) == 64
    assert [artifact.kind for artifact in run.artifacts] == [
        "operator_events",
        "operator_metadata",
    ]
    assert all(len(artifact.sha256) == 64 for artifact in run.artifacts)

    report = build_calibration_report(run_path)
    assert report["unresolved_blockers"] == []
    assert [artifact["kind"] for artifact in report["artifacts"]] == [
        "operator_events",
        "operator_metadata",
    ]
    assert [source["role"] for source in report["sources"]] == [
        "watch",
        "equipment",
        "insoles",
        "camera",
    ]
    equipment_report = next(
        source
        for source in report["sources"]
        if source["role"] == "equipment"
    )
    assert equipment_report["clock"]["residual_rms_ms"] == pytest.approx(2.0)
    assert equipment_report["clock"]["drift_ppm"] == pytest.approx(0.0)

    insole_report = next(
        source
        for source in report["sources"]
        if source["role"] == "insoles"
    )
    assert (
        insole_report["qualification"]["receipt"]
        ["bilateral_overlap"]["pressure"]["overlap_fraction"]
        == pytest.approx(1.0)
    )

    camera_report = next(
        source
        for source in report["sources"]
        if source["role"] == "camera"
    )
    assert (
        camera_report["qualification"]["receipt"]["counts"]
        ["dropped_frames"]
        == 1
    )

    payload = build_replay_lab_payload(run_path, frame_hz=10.0)
    assert payload["schema_version"] == "motionos.replay-lab.v1"
    assert payload["run"]["run_id"] == "longboard-calibration-001"
    assert len(payload["devices"]) == 4
    assert payload["frames"]

    frame = next(
        item
        for item in payload["frames"]
        if item["time_ns"] == 100_000_000
    )
    assert frame["watch"]["heart_rate_bpm"] == pytest.approx(132.0)
    assert frame["equipment"]["accel_magnitude_m_s2"] == pytest.approx(5.0)
    assert frame["equipment"]["gyro_magnitude_rad_s"] == pytest.approx(2.0)
    assert (
        frame["left_foot"]["pressure"]["normal_force_n"]
        == pytest.approx(400.0)
    )
    assert (
        frame["right_foot"]["pressure"]["normal_force_n"]
        == pytest.approx(600.0)
    )
    assert frame["derived"]["left_load_fraction"] == pytest.approx(0.4)
    assert frame["derived"]["load_asymmetry"] == pytest.approx(0.2)
    assert (
        frame["camera"]["pose3d"]["coordinate_frame"]
        == "vision_root_joint_relative_meters"
    )
    assert (
        frame["camera"]["pose3d"]["raw_device_time_ns"]
        == 100_000_000
    )
    assert (
        frame["camera"]["pose3d"]["mapped_reference_time_ns"]
        == 100_000_000
    )


def test_replay_does_not_carry_forward_missing_values(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    build_calibration_run(spec, run_path)

    payload = build_replay_lab_payload(run_path, frame_hz=10.0)
    empty_frame = next(
        item
        for item in payload["frames"]
        if item["time_ns"] == 300_000_000
    )

    assert empty_frame["watch"]["heart_rate_bpm"] is None
    assert empty_frame["equipment"]["accel_event"] is None
    assert empty_frame["left_foot"]["pressure"] is None
    assert empty_frame["right_foot"]["pressure"] is None
    assert empty_frame["camera"]["pose3d"] is None
    assert empty_frame["derived"]["left_load_fraction"] is None


def test_replay_exposes_mapped_time_gap_regions(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    build_calibration_run(spec, run_path)

    payload = build_replay_lab_payload(run_path, frame_hz=10.0)
    gap_frames = [
        frame
        for frame in payload["frames"]
        if frame["active_gap_streams"]
    ]

    assert gap_frames
    assert any(
        "insoles:/body/left_foot/pressure"
        in frame["active_gap_streams"]
        for frame in gap_frames
    )
    assert payload["gaps"]


def test_run_manifest_detects_calibration_bundle_tampering(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    run = build_calibration_run(spec, run_path)

    bundle_path = (run_path.parent / run.calibration_bundle.path).resolve()
    bundle_path.write_text(
        bundle_path.read_text(encoding="utf-8") + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="calibration bundle hash changed"):
        load_calibration_run(run_path)


def test_run_manifest_detects_body_model_tampering(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    run = build_calibration_run(spec, run_path)

    profile = run.profiles[0]
    profile_path = (run_path.parent / profile.path).resolve()
    profile_path.write_text(
        json.dumps({"tampered": True}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="run profile hash changed"):
        load_calibration_run(run_path)


def test_run_manifest_detects_operator_artifact_tampering(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    run = build_calibration_run(spec, run_path)

    artifact = next(
        item for item in run.artifacts
        if item.kind == "operator_events"
    )
    artifact_path = (run_path.parent / artifact.path).resolve()
    artifact_path.write_text(
        artifact_path.read_text(encoding="utf-8") + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="run artifact hash changed"):
        load_calibration_run(run_path)


def test_report_keeps_recorded_failure_modes_as_blockers(tmp_path):
    spec, run_path = _build_four_role_fixture(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["failure_modes"] = ["camera mount moved after middle landmark"]
    spec.write_text(json.dumps(raw), encoding="utf-8")

    build_calibration_run(spec, run_path)
    report = build_calibration_report(run_path)

    assert report["unresolved_blockers"] == [
        "recorded failure: camera mount moved after middle landmark"
    ]
