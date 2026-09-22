from __future__ import annotations

import json
from pathlib import Path

import pytest

from motionos.camera import (
    FRAME_STREAM,
    MOTION_STREAM,
    POSE_STREAM,
    build_camera_capture_receipt,
    derive_pose_motion_energy,
    import_camera_evidence,
)
from motionos.clock_sync import derive_clock_sync
from motionos.replay import replay_frames
from motionos.schema import DeviceDescriptor, SensorEvent, SessionManifest
from motionos.session import SessionReader, SessionWriter


def _metadata(session_id: str = "camera-fixture") -> dict[str, object]:
    return {
        "schema_version": "motionos.camera.v1",
        "session_id": session_id,
        "started_at_utc": "2026-09-22T12:00:00Z",
        "ended_at_utc": "2026-09-22T12:00:01Z",
        "frame_event_count": 11,
        "pose_event_count": 6,
        "athlete_id": "fixture-athlete",
        "placement": "tripod_side_view",
        "orientation": "landscape_right",
        "video_filename": "camera.mov",
        "timestamp_authority": "cmsamplebuffer_presentation_time",
        "device": {
            "model": "iPhone",
            "system_version": "26.0",
        },
        "camera": {
            "localized_name": "Back Camera",
            "position": "back",
            "width_px": 1280,
            "height_px": 720,
            "requested_fps": 30.0,
        },
        "pose": {
            "requested_hz": 10.0,
        },
    }


def _frame_event(
    *,
    sequence: int,
    pts_ns: int,
    attempted: bool,
    detected: bool,
    session_id: str = "camera-fixture",
) -> SensorEvent:
    return SensorEvent(
        session_id=session_id,
        device_id="iphone-camera",
        stream=FRAME_STREAM,
        sequence=sequence,
        device_time_ns=pts_ns,
        payload={
            "video_pts_ns": pts_ns,
            "host_callback_monotonic_ns": 9_000_000_000 + pts_ns,
            "width_px": 1280,
            "height_px": 720,
            "pixel_format": "420f",
            "pose_attempted": attempted,
            "pose_detected": detected,
            "timestamp_basis": "cmsamplebuffer_presentation_time",
            "source": "iphone_avcapture_video_data",
        },
    )


def _pose_event(
    *,
    sequence: int,
    pts_ns: int,
    x_m: float,
    session_id: str = "camera-fixture",
) -> SensorEvent:
    return SensorEvent(
        session_id=session_id,
        device_id="iphone-camera",
        stream=POSE_STREAM,
        sequence=sequence,
        device_time_ns=pts_ns,
        payload={
            "video_pts_ns": pts_ns,
            "joints_m": {
                "leftWrist": [x_m, 0.2, -0.3],
                "rightWrist": [x_m + 0.1, -0.2, -0.3],
            },
            "joint_count": 2,
            "body_height_m": 1.65,
            "camera_origin_matrix": [
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            ],
            "coordinate_basis": "vision_root_relative_meters",
            "timestamp_basis": "cmsamplebuffer_presentation_time",
            "source": "apple_vision_3d_body_pose",
        },
    )


def _write_camera_files(
    directory: Path,
    *,
    unmatched_pose: bool = False,
    missing_pose_event: bool = False,
    malformed_joint: bool = False,
    metadata_session_id: str = "camera-fixture",
) -> tuple[Path, Path, Path]:
    directory.mkdir(parents=True, exist_ok=True)
    journal = directory / "camera.jsonl"
    video = directory / "camera.mov"
    metadata = directory / "camera-metadata.json"

    frame_times = [index * 100_000_000 for index in range(11)]
    pose_times = [0, 200_000_000, 400_000_000, 600_000_000, 800_000_000, 1_000_000_000]
    if unmatched_pose:
        pose_times[-1] = 1_050_000_000

    events: list[SensorEvent] = []
    pose_time_set = set(pose_times)
    for sequence, pts_ns in enumerate(frame_times):
        attempted = sequence % 2 == 0
        detected = pts_ns in pose_time_set
        if missing_pose_event and pts_ns == 600_000_000:
            detected = True
        events.append(
            _frame_event(
                sequence=sequence,
                pts_ns=pts_ns,
                attempted=attempted,
                detected=detected,
            )
        )

    for sequence, pts_ns in enumerate(pose_times):
        if missing_pose_event and pts_ns == 600_000_000:
            continue
        event = _pose_event(
            sequence=sequence,
            pts_ns=pts_ns,
            x_m=0.1 * sequence,
        )
        if malformed_joint and sequence == 2:
            event = SensorEvent(
                session_id=event.session_id,
                device_id=event.device_id,
                stream=event.stream,
                sequence=event.sequence,
                device_time_ns=event.device_time_ns,
                payload={
                    **event.payload,
                    "joints_m": {
                        "leftWrist": [0.1, 0.2],
                        "rightWrist": [0.2, 0.3, 0.4],
                    },
                },
            )
        events.append(event)

    journal.write_text(
        "".join(event.to_json() + "\n" for event in events),
        encoding="utf-8",
    )
    video.write_bytes(b"motionos-camera-video-fixture")
    metadata.write_text(
        json.dumps(_metadata(metadata_session_id)),
        encoding="utf-8",
    )
    return journal, video, metadata


def test_pose_motion_energy_has_known_physical_scale():
    events = [
        _pose_event(sequence=0, pts_ns=0, x_m=0.0),
        _pose_event(sequence=1, pts_ns=200_000_000, x_m=0.1),
    ]

    derived = derive_pose_motion_energy(events)

    assert len(derived) == 1
    assert derived[0].stream == MOTION_STREAM
    assert derived[0].device_time_ns == 200_000_000
    assert derived[0].payload["shared_joint_count"] == 2
    assert derived[0].payload["rms_joint_displacement_m"] == pytest.approx(0.1)
    assert derived[0].payload["motion_energy_mps"] == pytest.approx(0.5)
    assert derived[0].payload["source"] == "motionos_derived_pose_motion_v1"


def test_camera_import_and_capture_receipt_pass(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")

    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
        sport="longboard",
    )
    reader = SessionReader(session_dir)
    receipt = build_camera_capture_receipt(
        reader,
        min_duration_s=1.0,
    )

    assert receipt.capture_passed is True
    assert receipt.frame_qc.count == 11
    assert receipt.frame_qc.duration_s == pytest.approx(1.0)
    assert receipt.pose_qc.count == 6
    assert receipt.motion_qc.count == 5
    assert receipt.pose_attempt_count == 6
    assert receipt.pose_detected_frame_count == 6
    assert receipt.pose_detection_fraction == pytest.approx(1.0)
    assert receipt.unmatched_pose_timestamps == 0
    assert receipt.invalid_frame_payloads == 0
    assert receipt.invalid_pose_payloads == 0
    assert receipt.video_bytes > 0
    assert len(receipt.source_evidence_sha256["camera_video"]) == 64
    assert len(receipt.source_evidence_sha256["camera_journal"]) == 64
    assert len(receipt.source_evidence_sha256["camera_metadata"]) == 64

    pose = next(reader.iter_stream(POSE_STREAM))
    assert pose.payload["coordinate_basis"] == "vision_root_relative_meters"
    assert pose.payload["joints_m"]["leftWrist"] == [0.0, 0.2, -0.3]


def test_camera_replay_surfaces_raw_and_derived_streams(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")
    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )

    frames = list(
        replay_frames(
            SessionReader(session_dir),
            frame_hz=10.0,
        )
    )
    observed = set().union(*(frame.latest.keys() for frame in frames))
    assert {FRAME_STREAM, POSE_STREAM, MOTION_STREAM} <= observed


def test_receipt_rejects_pose_timestamp_without_captured_frame(tmp_path):
    journal, video, metadata = _write_camera_files(
        tmp_path / "source",
        unmatched_pose=True,
    )
    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=1.0,
    )

    assert receipt.unmatched_pose_timestamps == 1
    assert receipt.capture_passed is False


def test_receipt_rejects_pose_detected_flag_without_pose_event(tmp_path):
    journal, video, metadata = _write_camera_files(
        tmp_path / "source",
        missing_pose_event=True,
    )
    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=1.0,
    )

    assert receipt.pose_detected_frame_count == 6
    assert receipt.pose_qc.count == 5
    assert receipt.capture_passed is False


def test_receipt_rejects_malformed_joint_payload(tmp_path):
    journal, video, metadata = _write_camera_files(
        tmp_path / "source",
        malformed_joint=True,
    )
    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=1.0,
    )

    assert receipt.invalid_pose_payloads == 1
    assert receipt.capture_passed is False


def test_import_rejects_metadata_session_mismatch(tmp_path):
    journal, video, metadata = _write_camera_files(
        tmp_path / "source",
        metadata_session_id="other-session",
    )

    with pytest.raises(ValueError, match="session_id does not match"):
        import_camera_evidence(
            journal,
            video,
            tmp_path / "sessions",
            metadata_path=metadata,
        )


def test_import_rejects_multiple_camera_session_ids(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")
    with journal.open("a", encoding="utf-8") as handle:
        handle.write(
            _frame_event(
                sequence=99,
                pts_ns=1_100_000_000,
                attempted=False,
                detected=False,
                session_id="second-session",
            ).to_json()
            + "\n"
        )

    with pytest.raises(ValueError, match="multiple session IDs"):
        import_camera_evidence(
            journal,
            video,
            tmp_path / "sessions",
            metadata_path=metadata,
        )



def test_receipt_rejects_sidecar_event_count_mismatch(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")
    raw = json.loads(metadata.read_text(encoding="utf-8"))
    raw["frame_event_count"] = 999
    metadata.write_text(json.dumps(raw), encoding="utf-8")

    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=1.0,
    )

    assert "frame_event_count" in receipt.metadata_mismatches
    assert receipt.capture_passed is False


def test_receipt_rejects_sidecar_video_filename_mismatch(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")
    raw = json.loads(metadata.read_text(encoding="utf-8"))
    raw["video_filename"] = "different.mov"
    metadata.write_text(json.dumps(raw), encoding="utf-8")

    session_dir = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=1.0,
    )

    assert "video_filename" in receipt.metadata_mismatches
    assert receipt.capture_passed is False



def test_camera_motion_energy_drives_generic_watch_sync(tmp_path):
    journal, video, metadata = _write_camera_files(tmp_path / "source")
    camera_session = import_camera_evidence(
        journal,
        video,
        tmp_path / "sessions",
        metadata_path=metadata,
    )

    reference_manifest = SessionManifest(
        session_id="watch-sync-reference",
        created_at_utc="2026-09-22T12:00:00Z",
        sport="calibration",
        mode="calibration",
        athlete_id="fixture-athlete",
        devices=(
            DeviceDescriptor(
                device_id="watch",
                kind="apple_watch",
                placement="wrist",
                streams=("/body/watch/imu",),
            ),
        ),
    )
    reference_root = tmp_path / "watch"
    target_landmarks = [200_000_000, 600_000_000, 1_000_000_000]
    with SessionWriter(reference_root, reference_manifest) as writer:
        for sequence, target_time in enumerate(target_landmarks):
            reference_time = target_time + 50_000_000
            writer.append(
                SensorEvent(
                    session_id="watch-sync-reference",
                    device_id="watch",
                    stream="/body/watch/imu",
                    sequence=sequence,
                    device_time_ns=reference_time,
                    payload={
                        "ax": 25.0,
                        "ay": 0.0,
                        "az": 0.0,
                    },
                )
            )

    windows = [
        {
            "reference_start_ns": target_time + 40_000_000,
            "reference_end_ns": target_time + 60_000_000,
            "target_start_ns": target_time - 20_000_000,
            "target_end_ns": target_time + 20_000_000,
        }
        for target_time in target_landmarks
    ]

    receipt = derive_clock_sync(
        SessionReader(reference_root / "watch-sync-reference"),
        SessionReader(camera_session),
        windows,
        reference_stream="/body/watch/imu",
        target_stream=MOTION_STREAM,
        target_peak_keys=("motion_energy_mps",),
        target_coverage_stream=FRAME_STREAM,
    )

    assert receipt.coverage.passed is True
    assert receipt.target_coverage_stream == FRAME_STREAM
    assert receipt.clock_model.slope == pytest.approx(1.0)
    assert receipt.clock_model.intercept_ns == pytest.approx(50_000_000)
    assert receipt.clock_model.residual_rms_ns < 1.0
