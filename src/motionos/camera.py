from __future__ import annotations

import json
import math
from dataclasses import dataclass
from datetime import UTC, datetime
from itertools import pairwise
from pathlib import Path

from .provenance import sha256_file
from .qc import StreamQC, inspect_stream
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionReader, SessionWriter

CAMERA_FRAME_STREAM = "/camera/frame"
CAMERA_POSE_STREAM = "/camera/pose3d"
CAMERA_DROP_STREAM = "/camera/drop"
CAMERA_MOTION_STREAM = "/camera/pose_motion"

CAMERA_SCHEMA_VERSION = "motionos.camera.v1"
CAMERA_TIMESTAMP_BASIS = "avcapture_presentation_timestamp"


@dataclass(frozen=True)
class CameraEvidencePaths:
    directory: Path
    video: Path
    journal: Path
    metadata: Path


@dataclass(frozen=True)
class CameraCaptureReceipt:
    session_id: str
    capture_passed: bool
    pose_evidence_present: bool
    passed: bool
    min_duration_s: float
    frame_qc: StreamQC
    pose_qc: StreamQC
    drop_qc: StreamQC
    motion_qc: StreamQC
    invalid_frame_events: int
    invalid_pose_events: int
    broken_pose_frame_links: int
    metadata_mismatches: tuple[str, ...]
    source_evidence_sha256: dict[str, str]
    delivered_frames: int
    written_frames: int
    dropped_frames: int
    pose_detected_frames: int

    def to_dict(self) -> dict[str, object]:
        return {
            "protocol": "P5A-camera",
            "session_id": self.session_id,
            "capture_passed": self.capture_passed,
            "pose_evidence_present": self.pose_evidence_present,
            "passed": self.passed,
            "minimum_required_duration_s": self.min_duration_s,
            "frame_qc": self.frame_qc.to_dict(),
            "pose_qc": self.pose_qc.to_dict(),
            "drop_qc": self.drop_qc.to_dict(),
            "motion_qc": self.motion_qc.to_dict(),
            "invalid_frame_events": self.invalid_frame_events,
            "invalid_pose_events": self.invalid_pose_events,
            "broken_pose_frame_links": self.broken_pose_frame_links,
            "metadata_mismatches": list(self.metadata_mismatches),
            "counts": {
                "delivered_frames": self.delivered_frames,
                "written_frames": self.written_frames,
                "dropped_frames": self.dropped_frames,
                "pose_detected_frames": self.pose_detected_frames,
            },
            "source_evidence_sha256": dict(self.source_evidence_sha256),
            "clock_boundary": {
                "raw_time": "AVCaptureVideoDataOutput presentation timestamp",
                "mapped_time": "not applied during import",
                "sync_target_stream": CAMERA_MOTION_STREAM,
                "sync_target_key": "motion_m",
            },
            "claim_boundary": (
                "Vision 3D pose is teacher/validation evidence. "
                "Vision joint positions are root-relative and do not become "
                "world/body coordinates without separate spatial calibration."
            ),
        }


def camera_evidence_paths(path: str | Path) -> CameraEvidencePaths:
    source = Path(path)
    directory = source if source.is_dir() else source.parent
    return CameraEvidencePaths(
        directory=directory,
        video=directory / "camera.mov",
        journal=directory / "camera-frames.jsonl",
        metadata=directory / "camera-metadata.json",
    )


def _load_metadata(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("camera metadata must contain a JSON object")
    return dict(raw)


def _load_camera_events(path: Path) -> list[SensorEvent]:
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


def _finite_matrix(value: object, rows: int, columns: int) -> bool:
    if not isinstance(value, list) or len(value) != rows:
        return False
    for row in value:
        if not isinstance(row, list) or len(row) != columns:
            return False
        try:
            values = [float(item) for item in row]
        except (TypeError, ValueError):
            return False
        if not all(math.isfinite(item) for item in values):
            return False
    return True


def _valid_frame(event: SensorEvent) -> bool:
    payload = event.payload
    if event.stream != CAMERA_FRAME_STREAM:
        return False
    if payload.get("timestamp_basis") != CAMERA_TIMESTAMP_BASIS:
        return False
    if payload.get("source") != "avcapture_video_data_output":
        return False
    if payload.get("pose_status") not in {
        "not_scheduled",
        "detected",
        "no_pose",
        "vision_error",
    }:
        return False
    try:
        frame_index = int(payload["frame_index"])
        width = int(payload["width_px"])
        height = int(payload["height_px"])
        float(payload["pts_seconds"])
    except (KeyError, TypeError, ValueError):
        return False
    if frame_index != event.sequence or width <= 0 or height <= 0:
        return False
    if not isinstance(payload.get("video_written"), bool):
        return False

    intrinsic = payload.get("camera_intrinsic_matrix")
    return intrinsic is None or _finite_matrix(intrinsic, 3, 3)


def _pose_joints(payload: dict[str, object]) -> dict[str, list[float]] | None:
    raw = payload.get("joints_root_relative_m")
    if not isinstance(raw, dict) or not raw:
        return None
    joints: dict[str, list[float]] = {}
    for name, value in raw.items():
        if not isinstance(value, list) or len(value) != 3:
            return None
        try:
            point = [float(item) for item in value]
        except (TypeError, ValueError):
            return None
        if not all(math.isfinite(item) for item in point):
            return None
        joints[str(name)] = point
    return joints


def _valid_pose(event: SensorEvent) -> bool:
    payload = event.payload
    if event.stream != CAMERA_POSE_STREAM:
        return False
    if payload.get("timestamp_basis") != CAMERA_TIMESTAMP_BASIS:
        return False
    if payload.get("source") != "vision_3d_pose_from_camera_frame":
        return False
    if (
        payload.get("joint_coordinate_frame")
        != "vision_root_joint_relative_meters"
    ):
        return False
    if _pose_joints(payload) is None:
        return False
    if not _finite_matrix(payload.get("camera_origin_matrix"), 4, 4):
        return False
    try:
        int(payload["source_frame_sequence"])
        int(payload["source_frame_pts_ns"])
        if int(payload["joint_count"]) <= 0:
            return False
        body_height = float(payload["body_height_m"])
    except (KeyError, TypeError, ValueError):
        return False
    return math.isfinite(body_height) and body_height > 0


def _camera_translation(event: SensorEvent) -> tuple[float, float, float]:
    matrix = event.payload["camera_origin_matrix"]
    assert isinstance(matrix, list)
    return (
        float(matrix[0][3]),
        float(matrix[1][3]),
        float(matrix[2][3]),
    )


def derive_camera_motion(
    pose_events: list[SensorEvent],
    *,
    session_id: str,
    device_id: str,
) -> list[SensorEvent]:
    valid = [event for event in pose_events if _valid_pose(event)]
    valid.sort(key=lambda event: event.device_time_ns)
    motion: list[SensorEvent] = []

    for previous, current in pairwise(valid):
        dt_ns = current.device_time_ns - previous.device_time_ns
        if dt_ns <= 0:
            continue
        previous_t = _camera_translation(previous)
        current_t = _camera_translation(current)
        delta = tuple(
            current_value - previous_value
            for previous_value, current_value in zip(previous_t, current_t)
        )
        motion_m = math.sqrt(sum(value * value for value in delta))
        dt_s = dt_ns / 1e9

        motion.append(
            SensorEvent(
                session_id=session_id,
                device_id=device_id,
                stream=CAMERA_MOTION_STREAM,
                sequence=len(motion),
                device_time_ns=current.device_time_ns,
                payload={
                    "motion_m": motion_m,
                    "speed_m_s": motion_m / dt_s,
                    "delta_time_s": dt_s,
                    "source_pose_sequence_previous": previous.sequence,
                    "source_pose_sequence_current": current.sequence,
                    "timestamp_basis": CAMERA_TIMESTAMP_BASIS,
                    "source": "derived_from_vision_camera_origin_translation",
                    "derived": True,
                },
            )
        )
    return motion


def import_camera_evidence(
    path: str | Path,
    out_root: str | Path,
    *,
    athlete_id: str = "local-athlete",
    sport: str = "camera-calibration",
) -> Path:
    paths = camera_evidence_paths(path)
    for required in (paths.video, paths.journal, paths.metadata):
        if not required.is_file():
            raise FileNotFoundError(f"camera evidence file is missing: {required}")

    metadata = _load_metadata(paths.metadata)
    events = _load_camera_events(paths.journal)

    session_ids = {event.session_id for event in events}
    if len(session_ids) != 1:
        raise ValueError(
            f"camera journal contains multiple session IDs: {sorted(session_ids)}"
        )
    session_id = next(iter(session_ids))
    if str(metadata.get("session_id")) != session_id:
        raise ValueError("camera metadata session_id does not match journal")

    device_ids = {event.device_id for event in events}
    if len(device_ids) != 1:
        raise ValueError(
            "camera journal must contain exactly one camera device ID"
        )
    device_id = next(iter(device_ids))

    frames = [event for event in events if event.stream == CAMERA_FRAME_STREAM]
    poses = [event for event in events if event.stream == CAMERA_POSE_STREAM]
    drops = [event for event in events if event.stream == CAMERA_DROP_STREAM]
    unknown = [
        event
        for event in events
        if event.stream
        not in {CAMERA_FRAME_STREAM, CAMERA_POSE_STREAM, CAMERA_DROP_STREAM}
    ]
    if unknown:
        raise ValueError(
            "camera journal contains unsupported streams: "
            + ", ".join(sorted({event.stream for event in unknown}))
        )

    motion = derive_camera_motion(
        poses,
        session_id=session_id,
        device_id=device_id,
    )

    camera_raw = metadata.get("camera")
    camera = camera_raw if isinstance(camera_raw, dict) else {}
    host_raw = metadata.get("host")
    host = host_raw if isinstance(host_raw, dict) else {}

    hashes = {
        "camera_mov": sha256_file(paths.video),
        "camera_frames_jsonl": sha256_file(paths.journal),
        "camera_metadata_json": sha256_file(paths.metadata),
    }

    manifest = SessionManifest(
        session_id=session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport=sport,
        mode="calibration",
        athlete_id=athlete_id,
        devices=(
            DeviceDescriptor(
                device_id=device_id,
                kind="iphone_camera",
                placement="external_calibration_view",
                streams=(
                    CAMERA_FRAME_STREAM,
                    CAMERA_POSE_STREAM,
                    CAMERA_DROP_STREAM,
                    CAMERA_MOTION_STREAM,
                ),
                model=(
                    str(host["model"])
                    if host.get("model") is not None
                    else None
                ),
                firmware=(
                    str(host["os_version"])
                    if host.get("os_version") is not None
                    else None
                ),
            ),
        ),
        metadata={
            "qualification_protocol": "P5A-camera",
            "source_format": CAMERA_SCHEMA_VERSION,
            "source_evidence_sha256": hashes,
            "camera_evidence_directory": paths.directory.name,
            "camera_metadata": metadata,
            "camera_device": camera,
            "video_filename": paths.video.name,
            "timestamp_authority": CAMERA_TIMESTAMP_BASIS,
            "pose_coordinate_frame":
                "vision_root_joint_relative_meters",
            "pose_interpolation": "none",
            "derived_motion_stream": CAMERA_MOTION_STREAM,
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            [*events, *motion],
            key=lambda item: (
                item.canonical_time_ns,
                item.stream,
                item.sequence,
            ),
        ):
            writer.append(event)

        writer.write_metadata(
            "camera_import",
            {
                "source_directory": str(paths.directory),
                "source_evidence_sha256": hashes,
                "frame_events": len(frames),
                "pose_events": len(poses),
                "drop_events": len(drops),
                "derived_motion_events": len(motion),
            },
        )

    return Path(out_root) / session_id


def _metadata_count(
    metadata: dict[str, object],
    key: str,
) -> int | None:
    raw = metadata.get("counts")
    counts = raw if isinstance(raw, dict) else {}
    value = counts.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _metadata_pts(
    metadata: dict[str, object],
    key: str,
) -> int | None:
    raw = metadata.get("pts_ns")
    values = raw if isinstance(raw, dict) else {}
    value = values.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def build_camera_capture_receipt(
    reader: SessionReader,
    *,
    min_duration_s: float = 60.0,
) -> CameraCaptureReceipt:
    if min_duration_s <= 0:
        raise ValueError("min_duration_s must be positive")

    frames = list(reader.iter_stream(CAMERA_FRAME_STREAM))
    poses = list(reader.iter_stream(CAMERA_POSE_STREAM))
    drops = list(reader.iter_stream(CAMERA_DROP_STREAM))
    motion = list(reader.iter_stream(CAMERA_MOTION_STREAM))

    frame_qc = inspect_stream(CAMERA_FRAME_STREAM, frames)
    pose_qc = inspect_stream(CAMERA_POSE_STREAM, poses)
    drop_qc = inspect_stream(CAMERA_DROP_STREAM, drops)
    motion_qc = inspect_stream(CAMERA_MOTION_STREAM, motion)

    invalid_frames = sum(not _valid_frame(event) for event in frames)
    invalid_poses = sum(not _valid_pose(event) for event in poses)

    frame_by_sequence = {event.sequence: event for event in frames}
    broken_links = 0
    for pose in poses:
        try:
            sequence = int(pose.payload["source_frame_sequence"])
            source_pts = int(pose.payload["source_frame_pts_ns"])
        except (KeyError, TypeError, ValueError):
            broken_links += 1
            continue
        frame = frame_by_sequence.get(sequence)
        if (
            frame is None
            or frame.device_time_ns != pose.device_time_ns
            or frame.device_time_ns != source_pts
            or frame.payload.get("pose_status") != "detected"
        ):
            broken_links += 1

    metadata_raw = reader.manifest.metadata.get("camera_metadata")
    metadata = metadata_raw if isinstance(metadata_raw, dict) else {}
    provenance_raw = metadata.get("provenance")
    provenance = provenance_raw if isinstance(provenance_raw, dict) else {}
    source_hashes_raw = reader.manifest.metadata.get(
        "source_evidence_sha256"
    )
    source_hashes = (
        {str(key): str(value) for key, value in source_hashes_raw.items()}
        if isinstance(source_hashes_raw, dict)
        else {}
    )

    written_frames = sum(
        bool(event.payload.get("video_written"))
        for event in frames
    )
    mismatches: set[str] = set()

    expected_values = {
        "schema_version": CAMERA_SCHEMA_VERSION,
        "session_id": reader.manifest.session_id,
        "counts.delivered_frames": len(frames),
        "counts.written_frames": written_frames,
        "counts.avcapture_dropped_frames": len(drops),
        "counts.pose_detected_frames": len(poses),
        "pts_ns.first": (
            frames[0].device_time_ns if frames else None
        ),
        "pts_ns.last": (
            frames[-1].device_time_ns if frames else None
        ),
        "provenance.camera_mov_sha256":
            source_hashes.get("camera_mov"),
        "provenance.camera_frames_jsonl_sha256":
            source_hashes.get("camera_frames_jsonl"),
    }
    actual_values = {
        "schema_version": metadata.get("schema_version"),
        "session_id": metadata.get("session_id"),
        "counts.delivered_frames":
            _metadata_count(metadata, "delivered_frames"),
        "counts.written_frames":
            _metadata_count(metadata, "written_frames"),
        "counts.avcapture_dropped_frames":
            _metadata_count(metadata, "avcapture_dropped_frames"),
        "counts.pose_detected_frames":
            _metadata_count(metadata, "pose_detected_frames"),
        "pts_ns.first": _metadata_pts(metadata, "first"),
        "pts_ns.last": _metadata_pts(metadata, "last"),
        "provenance.camera_mov_sha256":
            provenance.get("camera_mov_sha256"),
        "provenance.camera_frames_jsonl_sha256":
            provenance.get("camera_frames_jsonl_sha256"),
    }
    for key, expected in expected_values.items():
        if expected is None or actual_values.get(key) != expected:
            mismatches.add(key)

    pose_evidence_present = (
        len(poses) >= 2
        and len(motion) >= 1
        and invalid_poses == 0
        and broken_links == 0
    )
    capture_passed = (
        len(frames) >= 2
        and frame_qc.duration_s >= min_duration_s
        and frame_qc.non_monotonic_timestamps == 0
        and frame_qc.missing_sequences == 0
        and invalid_frames == 0
        and written_frames == len(frames)
        and not mismatches
        and "camera_mov" in source_hashes
        and "camera_frames_jsonl" in source_hashes
        and "camera_metadata_json" in source_hashes
    )

    return CameraCaptureReceipt(
        session_id=reader.manifest.session_id,
        capture_passed=capture_passed,
        pose_evidence_present=pose_evidence_present,
        passed=capture_passed and pose_evidence_present,
        min_duration_s=min_duration_s,
        frame_qc=frame_qc,
        pose_qc=pose_qc,
        drop_qc=drop_qc,
        motion_qc=motion_qc,
        invalid_frame_events=invalid_frames,
        invalid_pose_events=invalid_poses,
        broken_pose_frame_links=broken_links,
        metadata_mismatches=tuple(sorted(mismatches)),
        source_evidence_sha256=source_hashes,
        delivered_frames=len(frames),
        written_frames=written_frames,
        dropped_frames=len(drops),
        pose_detected_frames=len(poses),
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
