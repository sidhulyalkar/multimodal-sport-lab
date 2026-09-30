from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

VISION_SESSION_SCHEMA_VERSION = "motionos.vision-session.v1"


@dataclass(frozen=True)
class CameraSource:
    source_id: str
    display_name: str
    kind: str
    clock_domain: str
    timestamp_basis: str
    supports_live_frames: bool
    supports_remote_control: bool
    capabilities: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.kind not in {
            "built_in",
            "external_recorded",
            "external_live_stream",
        }:
            raise ValueError("unsupported camera source kind")
        if not self.source_id.strip():
            raise ValueError("camera source_id is required")
        if not self.clock_domain.strip():
            raise ValueError("camera clock_domain is required")
        if not self.timestamp_basis.strip():
            raise ValueError("camera timestamp_basis is required")

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["capabilities"] = list(self.capabilities)
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "CameraSource":
        return cls(
            source_id=str(data["source_id"]),
            display_name=str(data["display_name"]),
            kind=str(data["kind"]),
            clock_domain=str(data["clock_domain"]),
            timestamp_basis=str(data["timestamp_basis"]),
            supports_live_frames=bool(data["supports_live_frames"]),
            supports_remote_control=bool(data["supports_remote_control"]),
            capabilities=tuple(str(x) for x in data.get("capabilities", [])),
        )


@dataclass(frozen=True)
class VideoFrameTimestamp:
    source_id: str
    sequence: int
    source_time_ns: int
    host_monotonic_time_ns: int | None = None
    session_time_ns: int | None = None
    timing_uncertainty_ns: int | None = None

    def __post_init__(self) -> None:
        for label, value in (
            ("sequence", self.sequence),
            ("source_time_ns", self.source_time_ns),
            ("host_monotonic_time_ns", self.host_monotonic_time_ns),
            ("session_time_ns", self.session_time_ns),
            ("timing_uncertainty_ns", self.timing_uncertainty_ns),
        ):
            if value is not None and value < 0:
                raise ValueError(f"{label} must be non-negative")


@dataclass(frozen=True)
class CameraCalibration:
    calibration_id: str
    camera_source_id: str
    image_width_px: int
    image_height_px: int
    intrinsics_row_major: tuple[float, ...]
    distortion_model: str
    distortion_coefficients: tuple[float, ...]
    world_from_camera_row_major: tuple[float, ...]
    reprojection_rms_px: float
    source_artifact_sha256: str | None = None

    def __post_init__(self) -> None:
        if self.image_width_px <= 0 or self.image_height_px <= 0:
            raise ValueError("camera image dimensions must be positive")
        if len(self.intrinsics_row_major) != 9:
            raise ValueError("camera intrinsics must contain 9 row-major values")
        if len(self.world_from_camera_row_major) != 16:
            raise ValueError("world_from_camera must contain 16 row-major values")
        if self.reprojection_rms_px < 0:
            raise ValueError("reprojection RMS must be non-negative")


@dataclass(frozen=True)
class VisionJointObservation:
    x: float
    y: float
    confidence: float
    z: float | None = None

    def __post_init__(self) -> None:
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError("joint confidence must be between 0 and 1")


@dataclass(frozen=True)
class VisionObservation:
    source_id: str
    frame_sequence: int
    frame_source_time_ns: int
    coordinate_frame: str
    model_identifier: str
    joints: dict[str, VisionJointObservation]
    mapped_session_time_ns: int | None = None
    timing_uncertainty_ns: int | None = None


@dataclass(frozen=True)
class SyncLandmark:
    landmark_id: str
    session_id: str
    kind: str
    host_monotonic_time_ns: int
    created_at_unix_ms: int
    note: str | None = None


@dataclass(frozen=True)
class VisionSessionManifest:
    session_id: str
    sport: str
    capture_mode: str
    created_at_utc: str
    camera_sources: tuple[CameraSource, ...]
    sync_landmarks: tuple[SyncLandmark, ...] = ()
    coaching_condition: str = "feedback_disabled"
    schema_version: str = VISION_SESSION_SCHEMA_VERSION
    claim_boundary: str = (
        "Camera and wearable streams retain native timing until explicit "
        "calibration; derived biomechanics carry uncertainty."
    )

    def __post_init__(self) -> None:
        if self.coaching_condition not in {
            "feedback_disabled",
            "feedback_enabled",
        }:
            raise ValueError("unsupported coaching condition")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "session_id": self.session_id,
            "sport": self.sport,
            "capture_mode": self.capture_mode,
            "created_at_utc": self.created_at_utc,
            "camera_sources": [
                source.to_dict() for source in self.camera_sources
            ],
            "sync_landmarks": [
                asdict(landmark) for landmark in self.sync_landmarks
            ],
            "coaching_condition": self.coaching_condition,
            "claim_boundary": self.claim_boundary,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "VisionSessionManifest":
        return cls(
            session_id=str(data["session_id"]),
            sport=str(data["sport"]),
            capture_mode=str(data["capture_mode"]),
            created_at_utc=str(data["created_at_utc"]),
            camera_sources=tuple(
                CameraSource.from_dict(item)
                for item in data.get("camera_sources", [])
            ),
            sync_landmarks=tuple(
                SyncLandmark(**item)
                for item in data.get("sync_landmarks", [])
            ),
            coaching_condition=str(
                data.get("coaching_condition", "feedback_disabled")
            ),
            schema_version=str(
                data.get("schema_version", VISION_SESSION_SCHEMA_VERSION)
            ),
            claim_boundary=str(data.get("claim_boundary", "")),
        )
