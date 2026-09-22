from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from typing import Any

SCHEMA_VERSION = "motionos.m0.v1"


@dataclass(frozen=True)
class DeviceDescriptor:
    device_id: str
    kind: str
    placement: str
    streams: tuple[str, ...]
    model: str | None = None
    firmware: str | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["streams"] = list(self.streams)
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> DeviceDescriptor:
        return cls(
            device_id=str(data["device_id"]),
            kind=str(data["kind"]),
            placement=str(data["placement"]),
            streams=tuple(str(x) for x in data.get("streams", [])),
            model=data.get("model"),
            firmware=data.get("firmware"),
        )


@dataclass(frozen=True)
class SessionManifest:
    session_id: str
    created_at_utc: str
    sport: str
    mode: str
    athlete_id: str
    devices: tuple[DeviceDescriptor, ...]
    body_model: str | None = None
    notes: str | None = None
    schema_version: str = SCHEMA_VERSION
    metadata: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.mode not in {"calibration", "field"}:
            raise ValueError("mode must be 'calibration' or 'field'")
        if not self.session_id:
            raise ValueError("session_id is required")

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["devices"] = [device.to_dict() for device in self.devices]
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionManifest:
        return cls(
            session_id=str(data["session_id"]),
            created_at_utc=str(data["created_at_utc"]),
            sport=str(data["sport"]),
            mode=str(data["mode"]),
            athlete_id=str(data["athlete_id"]),
            devices=tuple(DeviceDescriptor.from_dict(x) for x in data.get("devices", [])),
            body_model=data.get("body_model"),
            notes=data.get("notes"),
            schema_version=str(data.get("schema_version", SCHEMA_VERSION)),
            metadata=dict(data.get("metadata", {})),
        )


@dataclass(frozen=True)
class SensorEvent:
    session_id: str
    device_id: str
    stream: str
    sequence: int
    device_time_ns: int
    payload: dict[str, Any]
    session_time_ns: int | None = None
    sync_quality: float | None = None
    schema_version: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.sequence < 0:
            raise ValueError("sequence must be non-negative")
        if self.device_time_ns < 0:
            raise ValueError("device_time_ns must be non-negative")
        if self.session_time_ns is not None and self.session_time_ns < 0:
            raise ValueError("session_time_ns must be non-negative")
        if self.sync_quality is not None and not 0.0 <= self.sync_quality <= 1.0:
            raise ValueError("sync_quality must be between 0 and 1")
        if not self.stream.startswith("/"):
            raise ValueError("stream must be an absolute topic beginning with '/'")

    @property
    def canonical_time_ns(self) -> int:
        return self.session_time_ns if self.session_time_ns is not None else self.device_time_ns

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), separators=(",", ":"), sort_keys=True)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SensorEvent:
        return cls(
            session_id=str(data["session_id"]),
            device_id=str(data["device_id"]),
            stream=str(data["stream"]),
            sequence=int(data["sequence"]),
            device_time_ns=int(data["device_time_ns"]),
            session_time_ns=(
                int(data["session_time_ns"]) if data.get("session_time_ns") is not None else None
            ),
            sync_quality=(
                float(data["sync_quality"]) if data.get("sync_quality") is not None else None
            ),
            payload=dict(data.get("payload", {})),
            schema_version=str(data.get("schema_version", SCHEMA_VERSION)),
        )

    @classmethod
    def from_json(cls, raw: str) -> SensorEvent:
        return cls.from_dict(json.loads(raw))
