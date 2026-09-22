from __future__ import annotations

import json
import math
import os
import statistics
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from itertools import pairwise
from pathlib import Path

from .clock import ClockModel
from .clock_sync import (
    load_clock_sync_receipt,
    validate_clock_sync_receipt,
)
from .provenance import (
    session_evidence_sha256,
    sha256_file,
    source_evidence_hashes,
)
from .session import SessionReader

CALIBRATION_SCHEMA_VERSION = "motionos.calibration-bundle.v1"


@dataclass(frozen=True)
class ArtifactReference:
    path: str
    sha256: str
    kind: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class CalibrationSource:
    role: str
    session_path: str
    session_id: str
    bundle_sha256: str
    source_evidence_sha256: dict[str, str]
    streams: tuple[str, ...]
    receipt: ArtifactReference | None
    clock_sync: ArtifactReference | None
    clock_model: ClockModel | None
    mapping_quality: float

    def to_dict(self) -> dict[str, object]:
        return {
            "role": self.role,
            "session_path": self.session_path,
            "session_id": self.session_id,
            "bundle_sha256": self.bundle_sha256,
            "source_evidence_sha256": dict(self.source_evidence_sha256),
            "streams": list(self.streams),
            "receipt": (
                self.receipt.to_dict()
                if self.receipt is not None
                else None
            ),
            "clock_sync": (
                self.clock_sync.to_dict()
                if self.clock_sync is not None
                else None
            ),
            "clock_model": (
                {
                    "slope": self.clock_model.slope,
                    "intercept_ns": self.clock_model.intercept_ns,
                    "residual_rms_ns": self.clock_model.residual_rms_ns,
                    "residual_rms_ms": self.clock_model.residual_rms_ns / 1e6,
                    "drift_ppm": self.clock_model.drift_ppm,
                    "observations_used": self.clock_model.observations_used,
                    "quality": self.clock_model.quality,
                }
                if self.clock_model is not None
                else None
            ),
            "mapping_quality": self.mapping_quality,
        }


@dataclass(frozen=True)
class CalibrationBundle:
    reference_role: str
    reference_session_id: str
    sources: tuple[CalibrationSource, ...]
    profiles: tuple[ArtifactReference, ...]
    schema_version: str = CALIBRATION_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "reference_role": self.reference_role,
            "reference_session_id": self.reference_session_id,
            "sources": [source.to_dict() for source in self.sources],
            "profiles": [profile.to_dict() for profile in self.profiles],
            "claim_boundary": (
                "This bundle references immutable raw sessions and applies "
                "derived clock mappings during replay. It does not rewrite "
                "source evidence or establish physical sensor accuracy."
            ),
        }


@dataclass(frozen=True)
class MappedCalibrationEvent:
    role: str
    session_id: str
    stream: str
    sequence: int
    raw_device_time_ns: int
    source_session_time_ns: int | None
    mapped_reference_time_ns: int
    mapping_quality: float
    payload: dict[str, object]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class GapRegion:
    role: str
    stream: str
    start_ns: int
    end_ns: int
    duration_ns: int
    expected_interval_ns: float
    gap_multiple: float

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class CalibrationReplayFrame:
    time_ns: int
    end_time_ns: int
    events: tuple[MappedCalibrationEvent, ...]
    active_gap_streams: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "time_ns": self.time_ns,
            "end_time_ns": self.end_time_ns,
            "events": [event.to_dict() for event in self.events],
            "streams_present": sorted({event.stream for event in self.events}),
            "active_gap_streams": list(self.active_gap_streams),
        }


def _portable_path(path: Path, *, relative_to: Path) -> str:
    return os.path.relpath(path.resolve(), relative_to.resolve())


def _resolve_spec_path(raw: str, *, spec_dir: Path) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (spec_dir / path).resolve()


def _resolve_path(raw: str, *, manifest_dir: Path) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (manifest_dir / path).resolve()


def _artifact(
    raw_path: str | Path | None,
    *,
    output_dir: Path,
    kind: str,
) -> ArtifactReference | None:
    if raw_path is None:
        return None
    path = Path(raw_path)
    if not path.is_file():
        raise FileNotFoundError(f"{kind} file does not exist: {path}")
    return ArtifactReference(
        path=_portable_path(path, relative_to=output_dir),
        sha256=sha256_file(path),
        kind=kind,
    )


def _source_from_spec(
    item: dict[str, object],
    *,
    spec_dir: Path,
    output_dir: Path,
    reference_role: str,
    reference_reader: SessionReader,
    reference_hash: str,
) -> CalibrationSource:
    role = str(item["role"])
    session_path = _resolve_spec_path(
        str(item["session"]),
        spec_dir=spec_dir,
    )
    reader = SessionReader(session_path)
    bundle_hash = session_evidence_sha256(reader)

    receipt_raw = item.get("receipt")
    receipt = _artifact(
        (
            _resolve_spec_path(
                str(receipt_raw),
                spec_dir=spec_dir,
            )
            if receipt_raw is not None
            else None
        ),
        output_dir=output_dir,
        kind=f"{role}_qualification_receipt",
    )

    if role == reference_role:
        if reader.manifest.session_id != reference_reader.manifest.session_id:
            raise ValueError(
                "reference role session does not match reference session"
            )
        if bundle_hash != reference_hash:
            raise ValueError(
                "reference role bundle hash does not match reference session"
            )
        if item.get("clock_sync") is not None:
            raise ValueError("reference role must not declare a clock_sync")
        model = None
        clock_artifact = None
        mapping_quality = 1.0
    else:
        sync_raw = item.get("clock_sync")
        if sync_raw is None:
            raise ValueError(
                f"non-reference role {role!r} requires clock_sync"
            )
        sync_path = _resolve_spec_path(
            str(sync_raw),
            spec_dir=spec_dir,
        )
        sync_receipt = load_clock_sync_receipt(sync_path)

        try:
            model = validate_clock_sync_receipt(
                sync_receipt,
                reference_reader,
                reader,
            )
        except ValueError as exc:
            raise ValueError(
                f"invalid clock-sync receipt for role {role!r}: {exc}"
            ) from exc

        if sync_receipt.reference.bundle_sha256 != reference_hash:
            raise ValueError(
                f"clock-sync reference bundle hash mismatch for role {role!r}"
            )
        if sync_receipt.target.bundle_sha256 != bundle_hash:
            raise ValueError(
                f"clock-sync target bundle hash mismatch for role {role!r}"
            )
        clock_artifact = _artifact(
            sync_path,
            output_dir=output_dir,
            kind=f"{role}_clock_sync",
        )
        mapping_quality = model.quality

    return CalibrationSource(
        role=role,
        session_path=_portable_path(
            session_path,
            relative_to=output_dir,
        ),
        session_id=reader.manifest.session_id,
        bundle_sha256=bundle_hash,
        source_evidence_sha256=source_evidence_hashes(reader),
        streams=tuple(reader.list_streams()),
        receipt=receipt,
        clock_sync=clock_artifact,
        clock_model=model,
        mapping_quality=mapping_quality,
    )


def build_calibration_bundle(
    spec_path: str | Path,
    output_path: str | Path,
) -> CalibrationBundle:
    spec_file = Path(spec_path).resolve()
    spec_dir = spec_file.parent
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("calibration spec must contain a JSON object")

    reference_raw = raw.get("reference")
    if not isinstance(reference_raw, dict):
        raise TypeError("calibration spec reference must be an object")

    reference_role = str(reference_raw["role"])
    reference_session = _resolve_spec_path(
        str(reference_raw["session"]),
        spec_dir=spec_dir,
    )
    reference_reader = SessionReader(reference_session)
    reference_hash = session_evidence_sha256(reference_reader)

    sources_raw = raw.get("sources")
    if not isinstance(sources_raw, list) or not sources_raw:
        raise ValueError("calibration spec requires a non-empty sources list")

    source_items: list[dict[str, object]] = []
    for index, item in enumerate(sources_raw):
        if not isinstance(item, dict):
            raise TypeError(f"calibration source {index} must be an object")
        source_items.append(dict(item))

    roles = [str(item.get("role", "")) for item in source_items]
    if any(not role for role in roles):
        raise ValueError("every calibration source requires a role")
    if len(set(roles)) != len(roles):
        raise ValueError("calibration source roles must be unique")
    if roles.count(reference_role) != 1:
        raise ValueError(
            "sources must contain the reference role exactly once"
        )

    sources = tuple(
        _source_from_spec(
            item,
            spec_dir=spec_dir,
            output_dir=output.parent,
            reference_role=reference_role,
            reference_reader=reference_reader,
            reference_hash=reference_hash,
        )
        for item in source_items
    )

    profiles_raw = raw.get("profiles", [])
    if not isinstance(profiles_raw, list):
        raise TypeError("calibration profiles must be a list")
    profiles: list[ArtifactReference] = []
    for index, item in enumerate(profiles_raw):
        if not isinstance(item, dict):
            raise TypeError(f"calibration profile {index} must be an object")
        kind = str(item.get("kind", "profile"))
        path = item.get("path")
        if path is None:
            raise ValueError(f"calibration profile {index} requires path")
        artifact = _artifact(
            _resolve_spec_path(
                str(path),
                spec_dir=spec_dir,
            ),
            output_dir=output.parent,
            kind=kind,
        )
        assert artifact is not None
        profiles.append(artifact)

    bundle = CalibrationBundle(
        reference_role=reference_role,
        reference_session_id=reference_reader.manifest.session_id,
        sources=sources,
        profiles=tuple(profiles),
    )
    output.write_text(
        json.dumps(bundle.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return bundle


def load_calibration_bundle(
    path: str | Path,
    *,
    verify_hashes: bool = True,
) -> CalibrationBundle:
    manifest_path = Path(path)
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("calibration bundle must contain a JSON object")
    if raw.get("schema_version") != CALIBRATION_SCHEMA_VERSION:
        raise ValueError("unsupported calibration bundle schema")

    sources_raw = raw.get("sources")
    if not isinstance(sources_raw, list):
        raise TypeError("calibration bundle sources must be a list")

    sources: list[CalibrationSource] = []
    for index, item in enumerate(sources_raw):
        if not isinstance(item, dict):
            raise TypeError(f"calibration source {index} must be an object")

        receipt_raw = item.get("receipt")
        receipt = (
            ArtifactReference(
                path=str(receipt_raw["path"]),
                sha256=str(receipt_raw["sha256"]),
                kind=str(receipt_raw["kind"]),
            )
            if isinstance(receipt_raw, dict)
            else None
        )
        sync_raw = item.get("clock_sync")
        clock_sync = (
            ArtifactReference(
                path=str(sync_raw["path"]),
                sha256=str(sync_raw["sha256"]),
                kind=str(sync_raw["kind"]),
            )
            if isinstance(sync_raw, dict)
            else None
        )

        model_raw = item.get("clock_model")
        model = (
            ClockModel(
                slope=float(model_raw["slope"]),
                intercept_ns=float(model_raw["intercept_ns"]),
                residual_rms_ns=float(model_raw["residual_rms_ns"]),
                observations_used=int(model_raw["observations_used"]),
            )
            if isinstance(model_raw, dict)
            else None
        )

        source_hashes_raw = item.get("source_evidence_sha256")
        source_hashes = (
            {str(k): str(v) for k, v in source_hashes_raw.items()}
            if isinstance(source_hashes_raw, dict)
            else {}
        )

        source = CalibrationSource(
            role=str(item["role"]),
            session_path=str(item["session_path"]),
            session_id=str(item["session_id"]),
            bundle_sha256=str(item["bundle_sha256"]),
            source_evidence_sha256=source_hashes,
            streams=tuple(str(v) for v in item.get("streams", [])),
            receipt=receipt,
            clock_sync=clock_sync,
            clock_model=model,
            mapping_quality=float(item["mapping_quality"]),
        )
        sources.append(source)

    profiles_raw = raw.get("profiles", [])
    if not isinstance(profiles_raw, list):
        raise TypeError("calibration bundle profiles must be a list")
    profiles = tuple(
        ArtifactReference(
            path=str(item["path"]),
            sha256=str(item["sha256"]),
            kind=str(item["kind"]),
        )
        for item in profiles_raw
        if isinstance(item, dict)
    )
    if len(profiles) != len(profiles_raw):
        raise TypeError("calibration profile entry must be an object")

    bundle = CalibrationBundle(
        reference_role=str(raw["reference_role"]),
        reference_session_id=str(raw["reference_session_id"]),
        sources=tuple(sources),
        profiles=profiles,
        schema_version=str(raw["schema_version"]),
    )

    if verify_hashes:
        base = manifest_path.parent
        for source in bundle.sources:
            session_path = _resolve_path(
                source.session_path,
                manifest_dir=base,
            )
            reader = SessionReader(session_path)
            if reader.manifest.session_id != source.session_id:
                raise ValueError(
                    f"session ID changed for role {source.role!r}"
                )
            if session_evidence_sha256(reader) != source.bundle_sha256:
                raise ValueError(
                    f"session evidence hash changed for role {source.role!r}"
                )
            for artifact in (source.receipt, source.clock_sync):
                if artifact is None:
                    continue
                artifact_path = _resolve_path(
                    artifact.path,
                    manifest_dir=base,
                )
                if sha256_file(artifact_path) != artifact.sha256:
                    raise ValueError(
                        f"artifact hash changed: {artifact.kind}"
                    )

        for profile in bundle.profiles:
            profile_path = _resolve_path(
                profile.path,
                manifest_dir=base,
            )
            if sha256_file(profile_path) != profile.sha256:
                raise ValueError(
                    f"profile hash changed: {profile.kind}"
                )

    return bundle


def _mapped_events(
    bundle: CalibrationBundle,
    *,
    manifest_path: Path,
) -> list[MappedCalibrationEvent]:
    events: list[MappedCalibrationEvent] = []
    for source in bundle.sources:
        session_path = _resolve_path(
            source.session_path,
            manifest_dir=manifest_path.parent,
        )
        reader = SessionReader(session_path)

        for event in reader.iter_events():
            if source.role == bundle.reference_role:
                mapped_time = event.canonical_time_ns
                mapping_quality = 1.0
            else:
                if source.clock_model is None:
                    raise ValueError(
                        f"role {source.role!r} lacks a clock model"
                    )
                mapped_time = source.clock_model.map(event.device_time_ns)
                mapping_quality = source.mapping_quality

            events.append(
                MappedCalibrationEvent(
                    role=source.role,
                    session_id=source.session_id,
                    stream=event.stream,
                    sequence=event.sequence,
                    raw_device_time_ns=event.device_time_ns,
                    source_session_time_ns=event.session_time_ns,
                    mapped_reference_time_ns=mapped_time,
                    mapping_quality=mapping_quality,
                    payload=dict(event.payload),
                )
            )

    events.sort(
        key=lambda event: (
            event.mapped_reference_time_ns,
            event.role,
            event.stream,
            event.sequence,
        )
    )
    return events


def _gap_regions(
    events: list[MappedCalibrationEvent],
) -> tuple[GapRegion, ...]:
    grouped: dict[tuple[str, str], list[int]] = {}
    for event in events:
        grouped.setdefault(
            (event.role, event.stream),
            [],
        ).append(event.mapped_reference_time_ns)

    regions: list[GapRegion] = []
    for (role, stream), times in grouped.items():
        ordered = sorted(set(times))
        if len(ordered) < 3:
            continue
        diffs = [
            current - previous
            for previous, current in pairwise(ordered)
            if current > previous
        ]
        if not diffs:
            continue
        expected = float(statistics.median(diffs))
        if expected <= 0:
            continue

        for previous, current in pairwise(ordered):
            gap = current - previous
            if gap > 1.5 * expected:
                regions.append(
                    GapRegion(
                        role=role,
                        stream=stream,
                        start_ns=previous,
                        end_ns=current,
                        duration_ns=gap,
                        expected_interval_ns=expected,
                        gap_multiple=gap / expected,
                    )
                )

    return tuple(
        sorted(
            regions,
            key=lambda region: (
                region.start_ns,
                region.role,
                region.stream,
            ),
        )
    )


def mapped_calibration_events(
    manifest_path: str | Path,
) -> tuple[MappedCalibrationEvent, ...]:
    """Return hash-verified events mapped onto the reference clock.

    Raw target device timestamps and any original session timestamps remain
    attached to every event. This function never rewrites source sessions.
    """

    path = Path(manifest_path)
    bundle = load_calibration_bundle(path, verify_hashes=True)
    return tuple(_mapped_events(bundle, manifest_path=path))


def calibration_gap_regions(
    manifest_path: str | Path,
) -> tuple[GapRegion, ...]:
    path = Path(manifest_path)
    bundle = load_calibration_bundle(path, verify_hashes=True)
    return _gap_regions(_mapped_events(bundle, manifest_path=path))


def replay_calibration_frames(
    manifest_path: str | Path,
    *,
    frame_hz: float = 10.0,
) -> Iterator[CalibrationReplayFrame]:
    if frame_hz <= 0 or not math.isfinite(frame_hz):
        raise ValueError("frame_hz must be positive and finite")

    path = Path(manifest_path)
    bundle = load_calibration_bundle(path, verify_hashes=True)
    events = _mapped_events(bundle, manifest_path=path)
    if not events:
        return

    gaps = _gap_regions(events)
    start = events[0].mapped_reference_time_ns
    end = events[-1].mapped_reference_time_ns
    step = max(1, round(1_000_000_000 / frame_hz))

    cursor = 0
    time_ns = start
    while time_ns <= end:
        frame_end = time_ns + step
        frame_events: list[MappedCalibrationEvent] = []
        while (
            cursor < len(events)
            and events[cursor].mapped_reference_time_ns < frame_end
        ):
            if events[cursor].mapped_reference_time_ns >= time_ns:
                frame_events.append(events[cursor])
            cursor += 1

        active = tuple(
            sorted(
                f"{region.role}:{region.stream}"
                for region in gaps
                if region.start_ns < frame_end
                and region.end_ns > time_ns
            )
        )
        yield CalibrationReplayFrame(
            time_ns=time_ns,
            end_time_ns=frame_end,
            events=tuple(frame_events),
            active_gap_streams=active,
        )
        time_ns = frame_end
