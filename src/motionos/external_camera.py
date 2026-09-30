from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

from .provenance import sha256_file
from .schema import DeviceDescriptor, SensorEvent, SessionManifest
from .session import SessionWriter


def import_external_camera_evidence(
    journal_path: str | Path,
    video_path: str | Path,
    metadata_path: str | Path,
    out_root: str | Path,
    *,
    source_id: str = "dji-action4",
    session_id: str | None = None,
    athlete_id: str = "local-athlete",
    sport: str = "indo-board-calibration",
    model: str = "DJI Osmo Action 4",
) -> Path:
    journal = Path(journal_path).resolve()
    video = Path(video_path).resolve()
    metadata = Path(metadata_path).resolve()
    for required in (journal, video, metadata):
        if not required.is_file():
            raise FileNotFoundError(required)

    events = _load_events(journal)
    source_session_ids = {event.session_id for event in events}
    if len(source_session_ids) != 1:
        raise ValueError(
            "external camera journal must contain exactly one source session"
        )
    source_session_id = next(iter(source_session_ids))

    device_ids = {event.device_id for event in events}
    if device_ids != {source_id}:
        raise ValueError(
            f"external camera journal device IDs must equal {source_id!r}"
        )

    allowed = {"/camera/frame", "/camera/pose2d"}
    unknown = sorted(
        {event.stream for event in events if event.stream not in allowed}
    )
    if unknown:
        raise ValueError(
            "external camera journal contains unsupported streams: "
            + ", ".join(unknown)
        )

    frame_events = [
        event for event in events if event.stream == "/camera/frame"
    ]
    pose_events = [
        event for event in events if event.stream == "/camera/pose2d"
    ]
    if len(frame_events) < 2:
        raise ValueError(
            "external camera journal requires at least two frame events"
        )
    if not pose_events:
        raise ValueError(
            "external camera journal requires at least one 2D pose event"
        )
    if any(
        event.payload.get("timestamp_basis") != "container_video_pts"
        for event in events
    ):
        raise ValueError(
            "external camera events must retain container_video_pts timing"
        )

    metadata_raw = json.loads(metadata.read_text(encoding="utf-8"))
    if not isinstance(metadata_raw, dict):
        raise TypeError("external camera metadata must be a JSON object")
    if str(metadata_raw.get("session_id", "")) != source_session_id:
        raise ValueError(
            "external camera metadata session_id does not match journal"
        )
    if str(metadata_raw.get("source_id", "")) != source_id:
        raise ValueError(
            "external camera metadata source_id does not match journal"
        )

    normalized_session_id = (
        session_id
        if session_id is not None
        else f"{source_session_id}-{source_id}"
    )
    if not normalized_session_id.strip():
        raise ValueError("session_id must not be empty")

    hashes = {
        "source_video": sha256_file(video),
        "source_journal": sha256_file(journal),
        "source_metadata": sha256_file(metadata),
    }

    manifest = SessionManifest(
        session_id=normalized_session_id,
        created_at_utc=datetime.now(UTC).isoformat(),
        sport=sport,
        mode="calibration",
        athlete_id=athlete_id,
        devices=(
            DeviceDescriptor(
                device_id=source_id,
                kind="external_camera",
                placement="fixed_calibration_view",
                streams=("/camera/frame", "/camera/pose2d"),
                model=model,
                firmware=None,
            ),
        ),
        metadata={
            "qualification_protocol": "M0-Vision-external-camera",
            "source_session_id": source_session_id,
            "source_format": str(
                metadata_raw.get(
                    "schema_version",
                    "motionos.external-video-pose2d.v1",
                )
            ),
            "source_evidence_sha256": hashes,
            "source_video_filename": video.name,
            "timestamp_authority": "container_video_pts",
            "pose_coordinate_frame": "vision_normalized_lower_left",
            "pose_interpolation": "none",
            "external_camera_metadata": metadata_raw,
        },
    )

    with SessionWriter(out_root, manifest) as writer:
        for event in sorted(
            events,
            key=lambda item: (
                item.device_time_ns,
                item.stream,
                item.sequence,
            ),
        ):
            writer.append(
                SensorEvent(
                    session_id=normalized_session_id,
                    device_id=event.device_id,
                    stream=event.stream,
                    sequence=event.sequence,
                    device_time_ns=event.device_time_ns,
                    payload=dict(event.payload),
                    session_time_ns=None,
                    sync_quality=None,
                    schema_version=event.schema_version,
                )
            )
        writer.write_metadata(
            "external_camera_import",
            {
                "source_session_id": source_session_id,
                "source_id": source_id,
                "source_evidence_sha256": hashes,
                "frame_events": len(frame_events),
                "pose2d_events": len(pose_events),
            },
        )

    return Path(out_root) / normalized_session_id


def _load_events(path: Path) -> list[SensorEvent]:
    events: list[SensorEvent] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                events.append(SensorEvent.from_json(line))
            except Exception as exc:
                raise ValueError(
                    f"invalid external camera event at line {line_number}"
                ) from exc
    if not events:
        raise ValueError("external camera journal contains no events")
    return events
