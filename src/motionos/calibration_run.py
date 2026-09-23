from __future__ import annotations

import json
import math
import os
from dataclasses import asdict, dataclass
from pathlib import Path

from .body_model import (
    BodyModelProfile,
    load_body_model_profile,
    register_vision_pose,
)
from .calibration import (
    CalibrationBundle,
    CalibrationReplayFrame,
    calibration_gap_regions,
    load_calibration_bundle,
    replay_calibration_frames,
)
from .provenance import sha256_file
from .qc import inspect_stream
from .schema import SensorEvent
from .session import SessionReader

RUN_SCHEMA_VERSION = "motionos.calibration-run.v1"
REPLAY_SCHEMA_VERSION = "motionos.replay-lab.v1"
REPORT_SCHEMA_VERSION = "motionos.calibration-report.v1"


@dataclass(frozen=True)
class RunArtifactReference:
    path: str
    sha256: str
    kind: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class CalibrationRun:
    run_id: str
    sport: str
    protocol_version: str
    calibration_bundle: RunArtifactReference
    profiles: tuple[RunArtifactReference, ...]
    artifacts: tuple[RunArtifactReference, ...]
    movement_blocks: tuple[dict[str, object], ...]
    sync_landmarks: tuple[dict[str, object], ...]
    notes: tuple[str, ...]
    failure_modes: tuple[str, ...]
    reference_role: str
    reference_session_id: str
    source_roles: tuple[str, ...]
    schema_version: str = RUN_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "run_id": self.run_id,
            "sport": self.sport,
            "protocol_version": self.protocol_version,
            "calibration_bundle": self.calibration_bundle.to_dict(),
            "profiles": [profile.to_dict() for profile in self.profiles],
            "artifacts": [artifact.to_dict() for artifact in self.artifacts],
            "movement_blocks": list(self.movement_blocks),
            "sync_landmarks": list(self.sync_landmarks),
            "notes": list(self.notes),
            "failure_modes": list(self.failure_modes),
            "reference_role": self.reference_role,
            "reference_session_id": self.reference_session_id,
            "source_roles": list(self.source_roles),
            "claim_boundary": (
                "This manifest groups already-captured evidence. It does not "
                "rewrite source sessions or upgrade unqualified sensor data."
            ),
        }


def _portable_path(path: Path, *, relative_to: Path) -> str:
    return os.path.relpath(path.resolve(), relative_to.resolve())


def _resolve_path(raw: str, *, base: Path) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (base / path).resolve()


def _artifact(
    path: Path,
    *,
    output_dir: Path,
    kind: str,
) -> RunArtifactReference:
    if not path.is_file():
        raise FileNotFoundError(f"{kind} file does not exist: {path}")
    return RunArtifactReference(
        path=_portable_path(path, relative_to=output_dir),
        sha256=sha256_file(path),
        kind=kind,
    )


def _object_list(
    value: object,
    *,
    field: str,
) -> tuple[dict[str, object], ...]:
    if value is None:
        return ()
    if not isinstance(value, list):
        raise TypeError(f"{field} must be a list")
    result: list[dict[str, object]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise TypeError(f"{field}[{index}] must be an object")
        result.append(dict(item))
    return tuple(result)


def _string_list(
    value: object,
    *,
    field: str,
) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list):
        raise TypeError(f"{field} must be a list")
    return tuple(str(item) for item in value)


def build_calibration_run(
    spec_path: str | Path,
    output_path: str | Path,
) -> CalibrationRun:
    spec = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    raw = json.loads(spec.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("calibration run spec must contain a JSON object")

    run_id = str(raw.get("run_id", "")).strip()
    sport = str(raw.get("sport", "")).strip()
    protocol_version = str(raw.get("protocol_version", "")).strip()
    if not run_id or not sport or not protocol_version:
        raise ValueError(
            "run_id, sport, and protocol_version are required"
        )

    bundle_raw = raw.get("calibration_bundle")
    if bundle_raw is None:
        raise ValueError("calibration_bundle is required")
    bundle_path = _resolve_path(
        str(bundle_raw),
        base=spec.parent,
    )
    bundle = load_calibration_bundle(
        bundle_path,
        verify_hashes=True,
    )

    profiles_raw = raw.get("profiles", [])
    if not isinstance(profiles_raw, list):
        raise TypeError("profiles must be a list")

    profiles: list[RunArtifactReference] = []
    for index, item in enumerate(profiles_raw):
        if not isinstance(item, dict):
            raise TypeError(f"profiles[{index}] must be an object")
        if item.get("path") is None:
            raise ValueError(f"profiles[{index}] requires path")
        profiles.append(
            _artifact(
                _resolve_path(
                    str(item["path"]),
                    base=spec.parent,
                ),
                output_dir=output.parent,
                kind=str(item.get("kind", "profile")),
            )
        )

    artifacts_raw = raw.get("artifacts", [])
    if not isinstance(artifacts_raw, list):
        raise TypeError("artifacts must be a list")

    artifacts: list[RunArtifactReference] = []
    for index, item in enumerate(artifacts_raw):
        if not isinstance(item, dict):
            raise TypeError(f"artifacts[{index}] must be an object")
        if item.get("path") is None:
            raise ValueError(f"artifacts[{index}] requires path")
        artifacts.append(
            _artifact(
                _resolve_path(
                    str(item["path"]),
                    base=spec.parent,
                ),
                output_dir=output.parent,
                kind=str(item.get("kind", "run_artifact")),
            )
        )

    run = CalibrationRun(
        run_id=run_id,
        sport=sport,
        protocol_version=protocol_version,
        calibration_bundle=_artifact(
            bundle_path,
            output_dir=output.parent,
            kind="calibration_bundle",
        ),
        profiles=tuple(profiles),
        artifacts=tuple(artifacts),
        movement_blocks=_object_list(
            raw.get("movement_blocks"),
            field="movement_blocks",
        ),
        sync_landmarks=_object_list(
            raw.get("sync_landmarks"),
            field="sync_landmarks",
        ),
        notes=_string_list(raw.get("notes"), field="notes"),
        failure_modes=_string_list(
            raw.get("failure_modes"),
            field="failure_modes",
        ),
        reference_role=bundle.reference_role,
        reference_session_id=bundle.reference_session_id,
        source_roles=tuple(source.role for source in bundle.sources),
    )
    output.write_text(
        json.dumps(run.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return run


def load_calibration_run(
    path: str | Path,
    *,
    verify_hashes: bool = True,
) -> CalibrationRun:
    manifest_path = Path(path).resolve()
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("calibration run must contain a JSON object")
    if raw.get("schema_version") != RUN_SCHEMA_VERSION:
        raise ValueError("unsupported calibration run schema")

    bundle_raw = raw.get("calibration_bundle")
    if not isinstance(bundle_raw, dict):
        raise TypeError("calibration_bundle must be an object")
    bundle_ref = RunArtifactReference(
        path=str(bundle_raw["path"]),
        sha256=str(bundle_raw["sha256"]),
        kind=str(bundle_raw["kind"]),
    )

    profiles_raw = raw.get("profiles", [])
    if not isinstance(profiles_raw, list):
        raise TypeError("profiles must be a list")
    profiles = tuple(
        RunArtifactReference(
            path=str(item["path"]),
            sha256=str(item["sha256"]),
            kind=str(item["kind"]),
        )
        for item in profiles_raw
        if isinstance(item, dict)
    )
    if len(profiles) != len(profiles_raw):
        raise TypeError("profile entries must be objects")

    artifacts_raw = raw.get("artifacts", [])
    if not isinstance(artifacts_raw, list):
        raise TypeError("artifacts must be a list")
    artifacts = tuple(
        RunArtifactReference(
            path=str(item["path"]),
            sha256=str(item["sha256"]),
            kind=str(item["kind"]),
        )
        for item in artifacts_raw
        if isinstance(item, dict)
    )
    if len(artifacts) != len(artifacts_raw):
        raise TypeError("artifact entries must be objects")

    run = CalibrationRun(
        run_id=str(raw["run_id"]),
        sport=str(raw["sport"]),
        protocol_version=str(raw["protocol_version"]),
        calibration_bundle=bundle_ref,
        profiles=profiles,
        artifacts=artifacts,
        movement_blocks=_object_list(
            raw.get("movement_blocks"),
            field="movement_blocks",
        ),
        sync_landmarks=_object_list(
            raw.get("sync_landmarks"),
            field="sync_landmarks",
        ),
        notes=_string_list(raw.get("notes"), field="notes"),
        failure_modes=_string_list(
            raw.get("failure_modes"),
            field="failure_modes",
        ),
        reference_role=str(raw["reference_role"]),
        reference_session_id=str(raw["reference_session_id"]),
        source_roles=tuple(str(value) for value in raw["source_roles"]),
        schema_version=str(raw["schema_version"]),
    )

    if verify_hashes:
        base = manifest_path.parent
        bundle_path = _resolve_path(
            run.calibration_bundle.path,
            base=base,
        )
        if sha256_file(bundle_path) != run.calibration_bundle.sha256:
            raise ValueError("calibration bundle hash changed")
        load_calibration_bundle(bundle_path, verify_hashes=True)

        for profile in run.profiles:
            profile_path = _resolve_path(profile.path, base=base)
            if sha256_file(profile_path) != profile.sha256:
                raise ValueError(
                    f"run profile hash changed: {profile.kind}"
                )

        for artifact in run.artifacts:
            artifact_path = _resolve_path(artifact.path, base=base)
            if sha256_file(artifact_path) != artifact.sha256:
                raise ValueError(
                    f"run artifact hash changed: {artifact.kind}"
                )

    return run


def calibration_bundle_path(
    run_path: str | Path,
    run: CalibrationRun | None = None,
) -> Path:
    manifest_path = Path(run_path).resolve()
    resolved_run = run or load_calibration_run(
        manifest_path,
        verify_hashes=True,
    )
    return _resolve_path(
        resolved_run.calibration_bundle.path,
        base=manifest_path.parent,
    )


def _receipt_state(receipt: dict[str, object] | None) -> str:
    if receipt is None:
        return "missing"
    if receipt.get("passed") is True:
        return "qualified"
    if receipt.get("passed") is False:
        return "failed"
    if receipt.get("capture_passed") is True:
        return "capture_only"
    if receipt.get("capture_passed") is False:
        return "failed"
    return "reported"


def _read_json_artifact(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    raw = json.loads(path.read_text(encoding="utf-8"))
    return dict(raw) if isinstance(raw, dict) else None


def _source_report(
    *,
    bundle_path: Path,
    bundle: CalibrationBundle,
    role: str,
    gaps_by_role: dict[str, list[dict[str, object]]],
) -> dict[str, object]:
    source = next(item for item in bundle.sources if item.role == role)
    session_path = _resolve_path(
        source.session_path,
        base=bundle_path.parent,
    )
    reader = SessionReader(session_path)

    streams = {}
    for stream in reader.list_streams():
        qc = inspect_stream(stream, list(reader.iter_stream(stream)))
        streams[stream] = qc.to_dict()

    receipt_payload = None
    receipt_path = None
    if source.receipt is not None:
        receipt_path = _resolve_path(
            source.receipt.path,
            base=bundle_path.parent,
        )
        receipt_payload = _read_json_artifact(receipt_path)

    model = source.clock_model
    return {
        "role": role,
        "session_id": source.session_id,
        "bundle_sha256": source.bundle_sha256,
        "source_evidence_sha256": dict(source.source_evidence_sha256),
        "qualification": {
            "state": _receipt_state(receipt_payload),
            "receipt_path": (
                source.receipt.path
                if source.receipt is not None
                else None
            ),
            "protocol": (
                receipt_payload.get("protocol")
                if receipt_payload is not None
                else None
            ),
            "passed": (
                receipt_payload.get("passed")
                if receipt_payload is not None
                else None
            ),
            "capture_passed": (
                receipt_payload.get("capture_passed")
                if receipt_payload is not None
                else None
            ),
            "receipt": receipt_payload,
        },
        "clock": (
            {
                "reference": False,
                "drift_ppm": model.drift_ppm,
                "residual_rms_ms": model.residual_rms_ns / 1e6,
                "mapping_quality": source.mapping_quality,
                "observations_used": model.observations_used,
            }
            if model is not None
            else {
                "reference": role == bundle.reference_role,
                "drift_ppm": 0.0 if role == bundle.reference_role else None,
                "residual_rms_ms": (
                    0.0 if role == bundle.reference_role else None
                ),
                "mapping_quality": source.mapping_quality,
                "observations_used": None,
            }
        ),
        "streams": streams,
        "gaps": gaps_by_role.get(role, []),
    }


def build_calibration_report(
    run_path: str | Path,
) -> dict[str, object]:
    run_manifest = Path(run_path).resolve()
    run = load_calibration_run(run_manifest, verify_hashes=True)
    bundle_path = calibration_bundle_path(run_manifest, run)
    bundle = load_calibration_bundle(bundle_path, verify_hashes=True)

    gaps_by_role: dict[str, list[dict[str, object]]] = {}
    for gap in calibration_gap_regions(bundle_path):
        gaps_by_role.setdefault(gap.role, []).append(gap.to_dict())

    sources = [
        _source_report(
            bundle_path=bundle_path,
            bundle=bundle,
            role=source.role,
            gaps_by_role=gaps_by_role,
        )
        for source in bundle.sources
    ]

    blockers: list[str] = []
    for source in sources:
        qualification = source["qualification"]
        assert isinstance(qualification, dict)
        state = qualification["state"]
        if state != "qualified":
            blockers.append(
                f"{source['role']}: qualification receipt {state}; "
                "full physical qualification required"
            )

        clock = source["clock"]
        assert isinstance(clock, dict)
        if (
            source["role"] != bundle.reference_role
            and clock["residual_rms_ms"] is None
        ):
            blockers.append(
                f"{source['role']}: missing clock model"
            )

    blockers.extend(
        f"recorded failure: {message}"
        for message in run.failure_modes
    )

    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "run_id": run.run_id,
        "sport": run.sport,
        "protocol_version": run.protocol_version,
        "reference_role": run.reference_role,
        "reference_session_id": run.reference_session_id,
        "calibration_bundle": run.calibration_bundle.to_dict(),
        "profiles": [profile.to_dict() for profile in run.profiles],
        "artifacts": [artifact.to_dict() for artifact in run.artifacts],
        "movement_blocks": list(run.movement_blocks),
        "sync_landmarks": list(run.sync_landmarks),
        "notes": list(run.notes),
        "failure_modes": list(run.failure_modes),
        "sources": sources,
        "unresolved_blockers": blockers,
        "claim_boundary": (
            "This report summarizes evidence integrity, timing, and gaps. "
            "It is not an athletic score or biomechanical validation."
        ),
    }


def write_calibration_report(
    run_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    report = build_calibration_report(run_path)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def _latest(
    frame: CalibrationReplayFrame,
    *,
    role: str,
    stream: str,
) -> dict[str, object] | None:
    candidates = [
        event
        for event in frame.events
        if event.role == role and event.stream == stream
    ]
    if not candidates:
        return None
    event = max(
        candidates,
        key=lambda item: (
            item.mapped_reference_time_ns,
            item.sequence,
        ),
    )
    return {
        "raw_device_time_ns": event.raw_device_time_ns,
        "source_session_time_ns": event.source_session_time_ns,
        "mapped_reference_time_ns": event.mapped_reference_time_ns,
        "mapping_quality": event.mapping_quality,
        "sequence": event.sequence,
        "payload": dict(event.payload),
        "sample_count_in_frame": len(candidates),
    }


def _vector_magnitude(
    event: dict[str, object] | None,
    keys: tuple[str, ...],
) -> float | None:
    if event is None:
        return None
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None
    try:
        values = [float(payload[key]) for key in keys]
    except (KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(value) for value in values):
        return None
    return math.sqrt(sum(value * value for value in values))


def _number(
    event: dict[str, object] | None,
    key: str,
) -> float | None:
    if event is None:
        return None
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None
    value = payload.get(key)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _pressure_view(
    event: dict[str, object] | None,
) -> dict[str, object] | None:
    if event is None:
        return None
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None

    pressure = payload.get("pressure_kpa")
    pressure_values = (
        [float(value) for value in pressure]
        if isinstance(pressure, list)
        else None
    )
    if pressure_values is not None and not all(
        math.isfinite(value) for value in pressure_values
    ):
        pressure_values = None

    return {
        **event,
        "pressure_kpa": pressure_values,
        "normal_force_n": _number(event, "normal_force_n"),
        "cop_normalized": (
            [
                _number(event, "cop_x_normalized"),
                _number(event, "cop_y_normalized"),
            ]
            if _number(event, "cop_x_normalized") is not None
            and _number(event, "cop_y_normalized") is not None
            else None
        ),
        "cop_coordinate_basis": payload.get("cop_coordinate_basis"),
    }


def _body_model_profile(
    run_manifest: Path,
    run: CalibrationRun,
) -> tuple[BodyModelProfile | None, dict[str, object]]:
    body_refs = [
        profile
        for profile in run.profiles
        if profile.kind == "body_model"
    ]
    if not body_refs:
        return None, {
            "state": "unavailable",
            "reason": "run has no body_model profile",
        }
    if len(body_refs) > 1:
        return None, {
            "state": "unavailable",
            "reason": "run references multiple body_model profiles",
        }

    reference = body_refs[0]
    profile_path = _resolve_path(
        reference.path,
        base=run_manifest.parent,
    )
    try:
        profile = load_body_model_profile(profile_path)
    except (
        OSError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as exc:
        return None, {
            "state": "unavailable",
            "reason": f"{type(exc).__name__}: {exc}",
            "profile_path": reference.path,
            "profile_sha256": reference.sha256,
        }

    if profile.profile_sha256 != reference.sha256:
        return None, {
            "state": "unavailable",
            "reason": "body-model run-reference hash mismatch",
            "profile_path": reference.path,
            "profile_sha256": reference.sha256,
        }

    return profile, {
        "state": "available",
        "profile_id": profile.model_id,
        "profile_sha256": profile.profile_sha256,
        "frame_convention": profile.frame_convention,
        "registration_landmarks": list(profile.registration_landmarks),
    }


def _pose_view(
    event: dict[str, object] | None,
    *,
    body_profile: BodyModelProfile | None,
) -> dict[str, object] | None:
    if event is None:
        return None
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None
    joints = payload.get("joints_root_relative_m")

    view: dict[str, object] = {
        **event,
        "joints_root_relative_m": (
            dict(joints)
            if isinstance(joints, dict)
            else None
        ),
        "joint_parents": (
            dict(payload["joint_parents"])
            if isinstance(payload.get("joint_parents"), dict)
            else None
        ),
        "body_height_m": _number(event, "body_height_m"),
        "coordinate_frame": payload.get("joint_coordinate_frame"),
        "camera_origin_matrix": payload.get("camera_origin_matrix"),
        "registered_pose": None,
        "registration_error": None,
    }

    if body_profile is None:
        return view

    try:
        pose_event = SensorEvent(
            session_id="replay-camera",
            device_id="replay-camera",
            stream="/camera/pose3d",
            sequence=int(event["sequence"]),
            device_time_ns=int(event["raw_device_time_ns"]),
            session_time_ns=(
                int(event["source_session_time_ns"])
                if event.get("source_session_time_ns") is not None
                else None
            ),
            payload=dict(payload),
        )
        registered = register_vision_pose(
            pose_event,
            body_profile,
        )
        view["registered_pose"] = registered.to_dict()
    except (KeyError, TypeError, ValueError) as exc:
        view["registration_error"] = (
            f"{type(exc).__name__}: {exc}"
        )

    return view

def _project_replay_frame(
    frame: CalibrationReplayFrame,
    *,
    reference_start_ns: int,
    body_profile: BodyModelProfile | None,
) -> dict[str, object]:
    watch_imu = _latest(
        frame,
        role="watch",
        stream="/body/watch/imu",
    )
    watch_hr = _latest(
        frame,
        role="watch",
        stream="/body/watch/hr",
    )
    equipment_accel = _latest(
        frame,
        role="equipment",
        stream="/equipment/imu/accel",
    )
    equipment_gyro = _latest(
        frame,
        role="equipment",
        stream="/equipment/imu/gyro",
    )
    left_pressure = _pressure_view(
        _latest(
            frame,
            role="insoles",
            stream="/body/left_foot/pressure",
        )
    )
    right_pressure = _pressure_view(
        _latest(
            frame,
            role="insoles",
            stream="/body/right_foot/pressure",
        )
    )
    left_imu = _latest(
        frame,
        role="insoles",
        stream="/body/left_foot/imu",
    )
    right_imu = _latest(
        frame,
        role="insoles",
        stream="/body/right_foot/imu",
    )
    pose = _pose_view(
        _latest(
            frame,
            role="camera",
            stream="/camera/pose3d",
        ),
        body_profile=body_profile,
    )
    camera_frame = _latest(
        frame,
        role="camera",
        stream="/camera/frame",
    )

    left_force = (
        float(left_pressure["normal_force_n"])
        if left_pressure is not None
        and left_pressure.get("normal_force_n") is not None
        else None
    )
    right_force = (
        float(right_pressure["normal_force_n"])
        if right_pressure is not None
        and right_pressure.get("normal_force_n") is not None
        else None
    )

    load_fraction_left = None
    load_asymmetry = None
    if (
        left_force is not None
        and right_force is not None
        and left_force + right_force > 0
    ):
        total = left_force + right_force
        load_fraction_left = left_force / total
        load_asymmetry = (right_force - left_force) / total

    return {
        "t_ms": (frame.time_ns - reference_start_ns) / 1e6,
        "time_ns": frame.time_ns,
        "end_time_ns": frame.end_time_ns,
        "streams_present": sorted(
            {
                event.stream
                for event in frame.events
            }
        ),
        "active_gap_streams": list(frame.active_gap_streams),
        "watch": {
            "heart_rate_bpm": _number(watch_hr, "bpm"),
            "hr_event": watch_hr,
            "imu_event": watch_imu,
            "accel_magnitude_m_s2": _vector_magnitude(
                watch_imu,
                ("ax", "ay", "az"),
            ),
            "gyro_magnitude_rad_s": _vector_magnitude(
                watch_imu,
                ("gx", "gy", "gz"),
            ),
        },
        "equipment": {
            "accel_event": equipment_accel,
            "gyro_event": equipment_gyro,
            "accel_magnitude_m_s2": _vector_magnitude(
                equipment_accel,
                ("ax", "ay", "az"),
            ),
            "gyro_magnitude_rad_s": _vector_magnitude(
                equipment_gyro,
                ("gx", "gy", "gz"),
            ),
        },
        "left_foot": {
            "pressure": left_pressure,
            "imu_event": left_imu,
        },
        "right_foot": {
            "pressure": right_pressure,
            "imu_event": right_imu,
        },
        "camera": {
            "pose3d": pose,
            "frame": camera_frame,
        },
        "derived": {
            "left_load_fraction": load_fraction_left,
            "load_asymmetry": load_asymmetry,
            "derivation_notes": {
                "load_fraction": (
                    "computed only when left and right normal_force_n "
                    "events both occur inside this replay frame"
                ),
                "load_asymmetry": "(right-left)/(right+left)",
                "missing_values": (
                    "null means no qualifying event in this frame; "
                    "no carry-forward or interpolation"
                ),
            },
        },
    }


def build_replay_lab_payload(
    run_path: str | Path,
    *,
    frame_hz: float = 10.0,
) -> dict[str, object]:
    if frame_hz <= 0 or not math.isfinite(frame_hz):
        raise ValueError("frame_hz must be positive and finite")

    run_manifest = Path(run_path).resolve()
    run = load_calibration_run(run_manifest, verify_hashes=True)
    bundle_path = calibration_bundle_path(run_manifest, run)
    report = build_calibration_report(run_manifest)
    body_profile, body_registration = _body_model_profile(
        run_manifest,
        run,
    )

    replay_frames = list(
        replay_calibration_frames(
            bundle_path,
            frame_hz=frame_hz,
        )
    )
    if not replay_frames:
        frames: list[dict[str, object]] = []
        reference_start_ns = None
    else:
        reference_start_ns = replay_frames[0].time_ns
        frames = [
            _project_replay_frame(
                frame,
                reference_start_ns=reference_start_ns,
                body_profile=body_profile,
            )
            for frame in replay_frames
        ]

    sources = report["sources"]
    assert isinstance(sources, list)

    return {
        "schema_version": REPLAY_SCHEMA_VERSION,
        "run": {
            "run_id": run.run_id,
            "sport": run.sport,
            "protocol_version": run.protocol_version,
            "reference_role": run.reference_role,
            "reference_session_id": run.reference_session_id,
            "reference_start_ns": reference_start_ns,
            "movement_blocks": list(run.movement_blocks),
            "sync_landmarks": list(run.sync_landmarks),
            "notes": list(run.notes),
            "failure_modes": list(run.failure_modes),
        },
        "devices": [
            {
                "id": source["role"],
                "role": source["role"],
                "session_id": source["session_id"],
                "qualification": {
                    "state": source["qualification"]["state"],
                    "protocol": source["qualification"]["protocol"],
                    "passed": source["qualification"]["passed"],
                    "capture_passed":
                        source["qualification"]["capture_passed"],
                },
                "clock": source["clock"],
                "streams": source["streams"],
                "gap_count": len(source["gaps"]),
            }
            for source in sources
        ],
        "gaps": [
            gap
            for source in sources
            for gap in source["gaps"]
        ],
        "frame_hz": frame_hz,
        "frames": frames,
        "body_registration": body_registration,
        "provenance": {
            "run_manifest_sha256": sha256_file(run_manifest),
            "calibration_bundle_sha256":
                run.calibration_bundle.sha256,
            "profiles": [
                profile.to_dict()
                for profile in run.profiles
            ],
            "artifacts": [
                artifact.to_dict()
                for artifact in run.artifacts
            ],
        },
        "claim_boundary": (
            "Replay values are measured or explicitly labeled derived "
            "quantities. Missing frame data remains null; no interpolation "
            "or last-value carry-forward is performed."
        ),
    }


def write_replay_lab_payload(
    run_path: str | Path,
    output_path: str | Path,
    *,
    frame_hz: float = 10.0,
) -> dict[str, object]:
    payload = build_replay_lab_payload(
        run_path,
        frame_hz=frame_hz,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
