from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from .provenance import sha256_file
from .qc import StreamQC, inspect_stream
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionReader, SessionWriter

FRAME_STREAM = "/camera/frame"
POSE_STREAM = "/camera/pose3d"
MOTION_STREAM = "/camera/motion_energy"

CAMERA_SCHEMA_VERSION = "motionos.camera.v1"
FRAME_SOURCE = "iphone_avcapture_video_data"
POSE_SOURCE = "apple_vision_3d_body_pose"
MOTION_SOURCE = "motionos_derived_pose_motion_v1"
PTS_BASIS = "cmsamplebuffer_presentation_time"
POSE_COORDINATE_BASIS = "vision_root_relative_meters"


@dataclass(frozen=True)
class CameraCaptureReceipt:
    session_id: str
    capture_passed: bool
    min_duration_s: float
    missing_streams: tuple[str, ...]
    missing_metadata_fields: tuple[str, ...]
    metadata_mismatches: tuple[str, ...]
    invalid_frame_payloads: int
    invalid_pose_payloads: int
    unmatched_pose_timestamps: int
    frame_qc: StreamQC
    pose_qc: StreamQC
    motion_qc: StreamQC
    pose_attempt_count: int
    pose_detected_frame_count: int
    pose_detection_fraction: float | None
    video_bytes: int
    source_evidence_sha256: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "B5A-camera",
            "session_id": self.session_id,
            "capture_passed": self.capture_passed,
            "minimum_required_duration_s": self.min_duration_s,
            "missing_streams": list(self.missing_streams),
            "missing_metadata_fields": list(self.missing_metadata_fields),
            "metadata_mismatches": list(self.metadata_mismatches),
            "invalid_payloads": {
                FRAME_STREAM: self.invalid_frame_payloads,
                POSE_STREAM: self.invalid_pose_payloads,
            },
            "unmatched_pose_timestamps": self.unmatched_pose_timestamps,
            "streams": {
                FRAME_STREAM: self.frame_qc.to_dict(),
                POSE_STREAM: self.pose_qc.to_dict(),
                MOTION_STREAM: self.motion_qc.to_dict(),
            },
            "pose_attempt_count": self.pose_attempt_count,
            "pose_detected_frame_count": self.pose_detected_frame_count,
            "pose_detection_fraction": self.pose_detection_fraction,
            "video_bytes": self.video_bytes,
            "timing_authority": {
                "raw_camera_clock": PTS_BASIS,
                "host_callback_monotonic_ns": "diagnostic_arrival_only",
                "sequence_authority": "journal_order_only",
            },
            "pose_coordinate_basis": POSE_COORDINATE_BASIS,
            "source_evidence_sha256": dict(self.source_evidence_sha256),
            "claim_boundary": (
                "capture_passed validates durable camera/video/pose evidence "
                "structure and provenance only. It does not establish Vision "
                "pose accuracy, camera extrinsics, body-scan registration, "
                "or cross-device synchronization."
            ),
        }


def _numeric_triplet(value: object) -> tuple[float, float, float] | None:
    if not isinstance(value, list) or len(value) != 3:
        return None
    try:
        result = tuple(float(item) for item in value)
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(item) for item in result):
        return None
    return result  # type: ignore[return-value]


def _numeric_matrix16(value: object) -> tuple[float, ...] | None:
    if not isinstance(value, list) or len(value) != 16:
        return None
    try:
        result = tuple(float(item) for item in value)
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(item) for item in result):
        return None
    return result


def _pose_joints(
    event: SensorEvent,
) -> dict[str, tuple[float, float, float]] | None:
    raw = event.payload.get("joints_m")
    if not isinstance(raw, dict) or not raw:
        return None

    joints: dict[str, tuple[float, float, float]] = {}
    for name, value in raw.items():
        triplet = _numeric_triplet(value)
        if triplet is None:
            return None
        joints[str(name)] = triplet
    return joints


def derive_pose_motion_energy(
    pose_events: list[SensorEvent],
) -> list[SensorEvent]:
    """Derive a deterministic scalar motion signal without mutating raw pose."""

    if len(pose_events) < 2:
        return []

    ordered = sorted(
        pose_events,
        key=lambda event: (
            event.device_time_ns,
            event.sequence,
        ),
    )
    derived: list[SensorEvent] = []

    previous = ordered[0]
    previous_joints = _pose_joints(previous)
    if previous_joints is None:
        return []

    sequence = 0
    for current in ordered[1:]:
        current_joints = _pose_joints(current)
        if current_joints is None:
            previous = current
            previous_joints = current_joints
            continue

        dt_ns = current.device_time_ns - previous.device_time_ns
        if previous_joints is not None and dt_ns > 0:
            shared = sorted(set(previous_joints) & set(current_joints))
            if shared:
                squared = []
                for name in shared:
                    a = previous_joints[name]
                    b = current_joints[name]
                    squared.append(
                        (b[0] - a[0]) ** 2
                        + (b[1] - a[1]) ** 2
                        + (b[2] - a[2]) ** 2
                    )
                rms_displacement_m = math.sqrt(sum(squared) / len(squared))
                dt_s = dt_ns / 1e9
                derived.append(
                    SensorEvent(
                        session_id=current.session_id,
                        device_id=current.device_id,
                        stream=MOTION_STREAM,
                        sequence=sequence,
                        device_time_ns=current.device_time_ns,
                        payload={
                            "motion_energy_mps": rms_displacement_m / dt_s,
                            "rms_joint_displacement_m": rms_displacement_m,
                            "dt_s": dt_s,
                            "shared_joint_count": len(shared),
                            "previous_pose_sequence": previous.sequence,
                            "current_pose_sequence": current.sequence,
                            "timestamp_basis": PTS_BASIS,
                            "source": MOTION_SOURCE,
                            "units": "m/s",
                        },
                    )
                )
                sequence += 1

        previous = current
        previous_joints = current_joints

    return derived


def _read_camera_journal(path: Path) -> list[SensorEvent]:
    events: list[SensorEvent] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                events.append(SensorEvent.from_json(line))
            except Exception as exc:
                raise ValueError(
                    f"invalid camera SensorEvent at {path}:{line_number}"
                ) from exc

    if not events:
        raise ValueError("camera journal contains no events")
    return events


def import_camera_evidence(
    journal_path: str | Path,
    video_path: str | Path,
    out_root: str | Path,
    *,
    metadata_path: str | Path | None = None,
    sport: str = "camera-qualification",
) -> Path:
    journal = Path(journal_path)
    video = Path(video_path)
    metadata_file = (
        Path(metadata_path)
        if metadata_path is not None
        else journal.with_name("camera-metadata.json")
    )

    if not video.is_file():
        raise FileNotFoundError(f"camera video does not exist: {video}")
    if video.stat().st_size <= 0:
        raise ValueError("camera video is empty")
    if not metadata_file.is_file():
        raise FileNotFoundError(
            f"camera metadata does not exist: {metadata_file}"
        )

    raw_metadata = json.loads(metadata_file.read_text(encoding="utf-8"))
    if not isinstance(raw_metadata, dict):
        raise TypeError("camera metadata must contain a JSON object")
    camera_metadata = dict(raw_metadata)

    events = _read_camera_journal(journal)
    allowed_streams = {FRAME_STREAM, POSE_STREAM}
    unexpected = sorted(
        {
            event.stream
            for event in events
            if event.stream not in allowed_streams
        }
    )
    if unexpected:
        raise ValueError(
            "camera journal contains unexpected streams: "
            + ", ".join(unexpected)
        )

    session_ids = {event.session_id for event in events}
    device_ids = {event.device_id for event in events}
    if len(session_ids) != 1:
        raise ValueError(
            f"camera journal contains multiple session IDs: {sorted(session_ids)}"
        )
    if len(device_ids) != 1:
        raise ValueError(
            f"camera journal contains multiple device IDs: {sorted(device_ids)}"
        )

    session_id = next(iter(session_ids))
    device_id = next(iter(device_ids))
    pose_events = [
        event for event in events if event.stream == POSE_STREAM
    ]
    motion_events = derive_pose_motion_energy(pose_events)
    all_events = events + motion_events

    capture_session_id = camera_metadata.get("session_id")
    if capture_session_id is not None and str(capture_session_id) != session_id:
        raise ValueError(
            "camera metadata session_id does not match journal session"
        )

    device_raw = camera_metadata.get("device")
    device = device_raw if isinstance(device_raw, dict) else {}
    camera_raw = camera_metadata.get("camera")
    camera = camera_raw if isinstance(camera_raw, dict) else {}

    streams = tuple(sorted({event.stream for event in all_events}))
    evidence_sha256 = {
        "camera_journal": sha256_file(journal),
        "camera_metadata": sha256_file(metadata_file),
        "camera_video": sha256_file(video),
    }

    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=str(
            camera_metadata.get(
                "created_at_utc",
                camera_metadata.get("started_at_utc", ""),
            )
        ),
        sport=sport,
        mode="calibration",
        athlete_id=str(camera_metadata.get("athlete_id", "local-athlete")),
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="iphone_camera",
                placement=str(
                    camera_metadata.get(
                        "placement",
                        "external_camera",
                    )
                ),
                streams=streams,
                model=(
                    str(device["model"])
                    if device.get("model") is not None
                    else None
                ),
                firmware=(
                    str(device["system_version"])
                    if device.get("system_version") is not None
                    else None
                ),
            ),
        ),
        metadata={
            "qualification_protocol": "B5A-camera",
            "camera_capture": camera_metadata,
            "video_filename": video.name,
            "video_bytes": video.stat().st_size,
            "timestamp_authority": PTS_BASIS,
            "host_callback_timestamp_authority": "diagnostic_arrival_only",
            "pose_coordinate_basis": POSE_COORDINATE_BASIS,
            "source_evidence_sha256": evidence_sha256,
            "camera_descriptor": camera,
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            all_events,
            key=lambda item: (
                item.device_time_ns,
                item.stream,
                item.sequence,
            ),
        ):
            writer.append(event)

        writer.write_metadata(
            "camera_import",
            {
                "journal_path": str(journal),
                "video_path": str(video),
                "metadata_path": str(metadata_file),
                "raw_event_count": len(events),
                "derived_motion_event_count": len(motion_events),
                "streams": list(streams),
                "source_evidence_sha256": evidence_sha256,
            },
        )

    return Path(out_root) / session_id


def _validate_frame_payload(event: SensorEvent) -> bool:
    payload = event.payload
    try:
        pts = int(payload["video_pts_ns"])
        host = int(payload["host_callback_monotonic_ns"])
        width = int(payload["width_px"])
        height = int(payload["height_px"])
    except (KeyError, TypeError, ValueError):
        return False

    return (
        pts == event.device_time_ns
        and pts >= 0
        and host >= 0
        and width > 0
        and height > 0
        and isinstance(payload.get("pose_attempted"), bool)
        and isinstance(payload.get("pose_detected"), bool)
        and payload.get("timestamp_basis") == PTS_BASIS
        and payload.get("source") == FRAME_SOURCE
    )


def _validate_pose_payload(event: SensorEvent) -> bool:
    payload = event.payload
    try:
        pts = int(payload["video_pts_ns"])
        joint_count = int(payload["joint_count"])
    except (KeyError, TypeError, ValueError):
        return False

    joints = _pose_joints(event)
    if joints is None or joint_count != len(joints):
        return False

    body_height = payload.get("body_height_m")
    if body_height is not None:
        try:
            height = float(body_height)
        except (TypeError, ValueError):
            return False
        if not math.isfinite(height) or height <= 0:
            return False

    camera_origin = payload.get("camera_origin_matrix")
    if camera_origin is not None and _numeric_matrix16(camera_origin) is None:
        return False

    return (
        pts == event.device_time_ns
        and pts >= 0
        and payload.get("timestamp_basis") == PTS_BASIS
        and payload.get("source") == POSE_SOURCE
        and payload.get("coordinate_basis") == POSE_COORDINATE_BASIS
    )


def _camera_metadata_contract(
    reader: SessionReader,
    *,
    frame_count: int,
    pose_count: int,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    raw = reader.manifest.metadata.get("camera_capture")
    capture = raw if isinstance(raw, dict) else {}
    device_raw = capture.get("device")
    device = device_raw if isinstance(device_raw, dict) else {}
    camera_raw = capture.get("camera")
    camera = camera_raw if isinstance(camera_raw, dict) else {}

    required = {
        "schema_version": capture.get("schema_version"),
        "session_id": capture.get("session_id"),
        "ended_at_utc": capture.get("ended_at_utc"),
        "frame_event_count": capture.get("frame_event_count"),
        "pose_event_count": capture.get("pose_event_count"),
        "device.model": device.get("model"),
        "device.system_version": device.get("system_version"),
        "camera.localized_name": camera.get("localized_name"),
        "camera.position": camera.get("position"),
        "camera.width_px": camera.get("width_px"),
        "camera.height_px": camera.get("height_px"),
        "camera.requested_fps": camera.get("requested_fps"),
        "pose.requested_hz": (
            capture.get("pose", {}).get("requested_hz")
            if isinstance(capture.get("pose"), dict)
            else None
        ),
        "orientation": capture.get("orientation"),
        "video_filename": capture.get("video_filename"),
        "timestamp_authority": capture.get("timestamp_authority"),
    }

    missing = tuple(
        sorted(key for key, value in required.items() if value is None)
    )

    mismatch: set[str] = set()
    if (
        capture.get("schema_version") is not None
        and capture.get("schema_version") != CAMERA_SCHEMA_VERSION
    ):
        mismatch.add("schema_version")
    if (
        capture.get("session_id") is not None
        and str(capture.get("session_id")) != reader.manifest.session_id
    ):
        mismatch.add("session_id")
    if (
        capture.get("timestamp_authority") is not None
        and capture.get("timestamp_authority") != PTS_BASIS
    ):
        mismatch.add("timestamp_authority")
    if (
        capture.get("video_filename") is not None
        and str(capture.get("video_filename"))
        != str(reader.manifest.metadata.get("video_filename"))
    ):
        mismatch.add("video_filename")

    for key, expected_count in (
        ("frame_event_count", frame_count),
        ("pose_event_count", pose_count),
    ):
        value = capture.get(key)
        if value is not None:
            try:
                if int(value) != expected_count:
                    mismatch.add(key)
            except (TypeError, ValueError):
                mismatch.add(key)

    for key in ("width_px", "height_px", "requested_fps"):
        value = camera.get(key)
        if value is not None:
            try:
                if float(value) <= 0:
                    mismatch.add(f"camera.{key}")
            except (TypeError, ValueError):
                mismatch.add(f"camera.{key}")

    pose_raw = capture.get("pose")
    pose = pose_raw if isinstance(pose_raw, dict) else {}
    pose_rate = pose.get("requested_hz")
    if pose_rate is not None:
        try:
            if float(pose_rate) <= 0:
                mismatch.add("pose.requested_hz")
        except (TypeError, ValueError):
            mismatch.add("pose.requested_hz")

    return missing, tuple(sorted(mismatch))


def build_camera_capture_receipt(
    reader: SessionReader,
    *,
    min_duration_s: float = 60.0,
) -> CameraCaptureReceipt:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")

    available = set(reader.list_streams())
    missing_streams = tuple(
        sorted({FRAME_STREAM, POSE_STREAM} - available)
    )
    frame_events = list(reader.iter_stream(FRAME_STREAM))
    pose_events = list(reader.iter_stream(POSE_STREAM))
    motion_events = list(reader.iter_stream(MOTION_STREAM))

    frame_qc = inspect_stream(FRAME_STREAM, frame_events)
    pose_qc = inspect_stream(POSE_STREAM, pose_events)
    motion_qc = inspect_stream(MOTION_STREAM, motion_events)

    invalid_frames = sum(
        not _validate_frame_payload(event) for event in frame_events
    )
    invalid_poses = sum(
        not _validate_pose_payload(event) for event in pose_events
    )

    frame_times = {event.device_time_ns for event in frame_events}
    unmatched_pose_timestamps = sum(
        event.device_time_ns not in frame_times for event in pose_events
    )

    attempts = sum(
        event.payload.get("pose_attempted") is True
        for event in frame_events
    )
    detected_frames = sum(
        event.payload.get("pose_detected") is True
        for event in frame_events
    )
    detection_fraction = (
        detected_frames / attempts if attempts > 0 else None
    )

    missing_metadata, metadata_mismatches = _camera_metadata_contract(
        reader,
        frame_count=len(frame_events),
        pose_count=len(pose_events),
    )

    hashes_raw = reader.manifest.metadata.get("source_evidence_sha256")
    hashes = (
        {str(key): str(value) for key, value in hashes_raw.items()}
        if isinstance(hashes_raw, dict)
        else {}
    )
    video_bytes_raw = reader.manifest.metadata.get("video_bytes", 0)
    try:
        video_bytes = int(video_bytes_raw)
    except (TypeError, ValueError):
        video_bytes = 0

    capture_passed = (
        not missing_streams
        and not missing_metadata
        and not metadata_mismatches
        and invalid_frames == 0
        and invalid_poses == 0
        and unmatched_pose_timestamps == 0
        and frame_qc.count >= 2
        and pose_qc.count >= 2
        and motion_qc.count >= 1
        and frame_qc.duration_s >= min_duration_s
        and pose_qc.duration_s > 0
        and frame_qc.missing_sequences == 0
        and pose_qc.missing_sequences == 0
        and frame_qc.non_monotonic_timestamps == 0
        and pose_qc.non_monotonic_timestamps == 0
        and attempts >= pose_qc.count
        and detected_frames == pose_qc.count
        and video_bytes > 0
        and {
            "camera_journal",
            "camera_metadata",
            "camera_video",
        } <= set(hashes)
    )

    return CameraCaptureReceipt(
        session_id=reader.manifest.session_id,
        capture_passed=capture_passed,
        min_duration_s=min_duration_s,
        missing_streams=missing_streams,
        missing_metadata_fields=missing_metadata,
        metadata_mismatches=metadata_mismatches,
        invalid_frame_payloads=invalid_frames,
        invalid_pose_payloads=invalid_poses,
        unmatched_pose_timestamps=unmatched_pose_timestamps,
        frame_qc=frame_qc,
        pose_qc=pose_qc,
        motion_qc=motion_qc,
        pose_attempt_count=attempts,
        pose_detected_frame_count=detected_frames,
        pose_detection_fraction=detection_fraction,
        video_bytes=video_bytes,
        source_evidence_sha256=hashes,
    )


def write_camera_capture_receipt(
    session_dir: str | Path,
    output_path: str | Path,
    *,
    min_duration_s: float = 60.0,
) -> CameraCaptureReceipt:
    receipt = build_camera_capture_receipt(
        SessionReader(session_dir),
        min_duration_s=min_duration_s,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt
