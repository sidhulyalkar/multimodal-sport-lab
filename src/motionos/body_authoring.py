from __future__ import annotations

import json
import math
import statistics
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

from .body_model import (
    BODY_MODEL_SCHEMA_VERSION,
    DEFAULT_FRAME_CONVENTION,
    BodyModelProfile,
    load_body_model_profile,
    register_vision_pose,
    verify_body_model_source_artifact,
)
from .provenance import (
    session_evidence_sha256,
    sha256_file,
    source_evidence_hashes,
)
from .session import SessionReader

BODY_AUTHORING_SPEC_SCHEMA_VERSION = "motionos.body-model-authoring.v1"
BODY_REGISTRATION_REPORT_SCHEMA_VERSION = "motionos.body-registration-report.v1"
CAMERA_POSE_STREAM = "/camera/pose3d"


@dataclass(frozen=True)
class RegistrationFrameResult:
    sequence: int
    device_time_ns: int
    success: bool
    residual_rms_m: float | None
    residual_max_m: float | None
    scale: float | None
    translation_m: tuple[float, float, float] | None
    rotation: tuple[tuple[float, float, float], ...] | None
    error: str | None

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        if self.translation_m is not None:
            data["translation_m"] = list(self.translation_m)
        if self.rotation is not None:
            data["rotation"] = [list(row) for row in self.rotation]
        return data


def _resolve(raw: str, *, base: Path) -> Path:
    path = Path(raw)
    return path if path.is_absolute() else (base / path).resolve()


def _point3(value: object, *, label: str) -> tuple[float, float, float]:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"{label} must contain exactly three values")
    try:
        point = (float(value[0]), float(value[1]), float(value[2]))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not all(math.isfinite(item) for item in point):
        raise ValueError(f"{label} must be finite")
    return point


def _segment_length(
    landmarks: dict[str, tuple[float, float, float]],
    *,
    name: str,
    pair: object,
) -> float:
    if not isinstance(pair, (list, tuple)) or len(pair) != 2:
        raise ValueError(
            f"segment definition {name!r} must contain two landmark names"
        )
    start_name = str(pair[0])
    end_name = str(pair[1])
    if start_name not in landmarks:
        raise ValueError(
            f"segment {name!r} references missing landmark {start_name!r}"
        )
    if end_name not in landmarks:
        raise ValueError(
            f"segment {name!r} references missing landmark {end_name!r}"
        )

    start = landmarks[start_name]
    end = landmarks[end_name]
    length = math.sqrt(
        sum((end[index] - start[index]) ** 2 for index in range(3))
    )
    if not math.isfinite(length) or length <= 1e-9:
        raise ValueError(
            f"segment {name!r} has zero-length or invalid geometry"
        )
    return length


def build_body_model_from_spec(
    spec_path: str | Path,
    output_path: str | Path,
) -> BodyModelProfile:
    spec_file = Path(spec_path).resolve()
    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("body-model authoring spec must contain a JSON object")
    if raw.get("schema_version") != BODY_AUTHORING_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported body-model authoring spec schema")

    model_id = str(raw.get("model_id", "")).strip()
    if not model_id:
        raise ValueError("body-model authoring spec requires model_id")

    try:
        height_m = float(raw["height_m"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(
            "body-model authoring spec requires numeric height_m"
        ) from exc
    if not math.isfinite(height_m) or height_m <= 0:
        raise ValueError("body-model authoring height_m must be positive")

    source_raw = raw.get("source")
    if not isinstance(source_raw, dict):
        raise TypeError("body-model authoring source must be an object")
    source_type = str(source_raw.get("type", "")).strip()
    artifact_raw = str(source_raw.get("artifact", "")).strip()
    if not source_type or not artifact_raw:
        raise ValueError(
            "body-model authoring source requires type and artifact"
        )
    source_artifact = _resolve(artifact_raw, base=spec_file.parent)
    if not source_artifact.is_file():
        raise FileNotFoundError(
            f"body-model source artifact does not exist: {source_artifact}"
        )

    landmarks_raw = raw.get("landmarks_m")
    if not isinstance(landmarks_raw, dict):
        raise TypeError("body-model authoring landmarks_m must be an object")
    landmarks = {
        str(name): _point3(value, label=f"landmark {name!r}")
        for name, value in landmarks_raw.items()
    }

    registration_raw = raw.get("registration_landmarks")
    if not isinstance(registration_raw, list):
        raise TypeError(
            "body-model authoring registration_landmarks must be a list"
        )
    registration = [str(value) for value in registration_raw]

    definitions_raw = raw.get("segment_definitions", {})
    if not isinstance(definitions_raw, dict):
        raise TypeError(
            "body-model authoring segment_definitions must be an object"
        )
    explicit_raw = raw.get("segments_m", {})
    if not isinstance(explicit_raw, dict):
        raise TypeError("body-model authoring segments_m must be an object")

    duplicate_segments = set(definitions_raw) & set(explicit_raw)
    if duplicate_segments:
        raise ValueError(
            "segment names cannot be both computed and explicit: "
            + ", ".join(sorted(str(value) for value in duplicate_segments))
        )

    segments = {
        str(name): _segment_length(
            landmarks,
            name=str(name),
            pair=pair,
        )
        for name, pair in definitions_raw.items()
    }
    for name, value in explicit_raw.items():
        try:
            length = float(value)
        except (TypeError, ValueError) as exc:
            raise ValueError(
                f"explicit segment {name!r} must be numeric"
            ) from exc
        if not math.isfinite(length) or length <= 0:
            raise ValueError(
                f"explicit segment {name!r} must be positive and finite"
            )
        segments[str(name)] = length

    limits_raw = raw.get("joint_limits_deg", {})
    if not isinstance(limits_raw, dict):
        raise TypeError(
            "body-model authoring joint_limits_deg must be an object"
        )

    metadata_raw = raw.get("metadata", {})
    if not isinstance(metadata_raw, dict):
        raise TypeError("body-model authoring metadata must be an object")
    metadata = dict(metadata_raw)
    metadata.update(
        {
            "authoring_spec_sha256": sha256_file(spec_file),
            "source_artifact_name": source_artifact.name,
            "source_artifact_reference": artifact_raw,
            "segment_definition_count": len(definitions_raw),
            "explicit_segment_count": len(explicit_raw),
        }
    )

    profile_payload = {
        "schema_version": BODY_MODEL_SCHEMA_VERSION,
        "model_id": model_id,
        "height_m": height_m,
        "frame_convention": str(
            raw.get("frame_convention", DEFAULT_FRAME_CONVENTION)
        ),
        "landmarks_m": {
            name: list(point)
            for name, point in sorted(landmarks.items())
        },
        "segments_m": dict(sorted(segments.items())),
        "joint_limits_deg": limits_raw,
        "registration_landmarks": registration,
        "source": {
            "type": source_type,
            "artifact_sha256": sha256_file(source_artifact),
            "notes": (
                str(source_raw["notes"])
                if source_raw.get("notes") is not None
                else None
            ),
        },
        "metadata": metadata,
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(profile_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    profile = load_body_model_profile(output)
    verify_body_model_source_artifact(profile, source_artifact)
    return profile


def _nearest_rank(values: list[float], probability: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(probability * len(ordered)))
    return ordered[min(rank - 1, len(ordered) - 1)]


def _distribution(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {
            "median": None,
            "p95": None,
            "max": None,
        }
    return {
        "median": statistics.median(values),
        "p95": _nearest_rank(values, 0.95),
        "max": max(values),
    }


def build_body_registration_report(
    profile_path: str | Path,
    camera_session: str | Path,
) -> dict[str, object]:
    profile_file = Path(profile_path).resolve()
    profile = load_body_model_profile(profile_file)
    reader = SessionReader(camera_session)

    pose_events = list(reader.iter_stream(CAMERA_POSE_STREAM))
    frame_results: list[RegistrationFrameResult] = []
    residual_rms: list[float] = []
    residual_max: list[float] = []
    scales: list[float] = []
    successful_times: list[int] = []
    errors: Counter[str] = Counter()

    for event in pose_events:
        try:
            registered = register_vision_pose(event, profile)
        except (KeyError, TypeError, ValueError) as exc:
            error = f"{type(exc).__name__}: {exc}"
            errors[error] += 1
            frame_results.append(
                RegistrationFrameResult(
                    sequence=event.sequence,
                    device_time_ns=event.device_time_ns,
                    success=False,
                    residual_rms_m=None,
                    residual_max_m=None,
                    scale=None,
                    translation_m=None,
                    rotation=None,
                    error=error,
                )
            )
            continue

        receipt = registered.receipt
        residual_rms.append(receipt.residual_rms_m)
        residual_max.append(receipt.residual_max_m)
        scales.append(receipt.transform.scale)
        successful_times.append(event.device_time_ns)
        frame_results.append(
            RegistrationFrameResult(
                sequence=event.sequence,
                device_time_ns=event.device_time_ns,
                success=True,
                residual_rms_m=receipt.residual_rms_m,
                residual_max_m=receipt.residual_max_m,
                scale=receipt.transform.scale,
                translation_m=receipt.transform.translation_m,
                rotation=receipt.transform.rotation,
                error=None,
            )
        )

    scale_median = statistics.median(scales) if scales else None
    scale_min = min(scales) if scales else None
    scale_max = max(scales) if scales else None
    scale_range = (
        scale_max - scale_min
        if scale_min is not None and scale_max is not None
        else None
    )
    scale_cv = (
        statistics.pstdev(scales) / statistics.mean(scales)
        if len(scales) >= 2 and statistics.mean(scales) != 0
        else 0.0 if len(scales) == 1 else None
    )

    time_span = None
    if successful_times:
        first = min(successful_times)
        last = max(successful_times)
        time_span = {
            "first_device_time_ns": first,
            "last_device_time_ns": last,
            "span_s": (last - first) / 1e9,
        }

    return {
        "schema_version": BODY_REGISTRATION_REPORT_SCHEMA_VERSION,
        "profile": {
            "model_id": profile.model_id,
            "profile_sha256": profile.profile_sha256,
            "source_type": profile.source.type,
            "source_artifact_sha256": profile.source.artifact_sha256,
            "registration_landmarks": list(profile.registration_landmarks),
        },
        "camera_session": {
            "session_id": reader.manifest.session_id,
            "bundle_sha256": session_evidence_sha256(reader),
            "source_evidence_sha256": source_evidence_hashes(reader),
            "pose_stream": CAMERA_POSE_STREAM,
        },
        "frame_accounting": {
            "total_pose_frames": len(pose_events),
            "successful_registrations": len(scales),
            "failed_registrations": len(pose_events) - len(scales),
            "failure_reasons": dict(sorted(errors.items())),
        },
        "residual_rms_m": _distribution(residual_rms),
        "residual_max_m": _distribution(residual_max),
        "scale": {
            "median": scale_median,
            "min": scale_min,
            "max": scale_max,
            "range": scale_range,
            "coefficient_of_variation": scale_cv,
        },
        "successful_time_span": time_span,
        "frames": [frame.to_dict() for frame in frame_results],
        "claim_boundary": (
            "This report measures registration repeatability against one "
            "declared personalized landmark geometry. Repeatability is not "
            "ground-truth anatomical or biomechanical accuracy, and no "
            "universal pass threshold is applied."
        ),
    }


def write_body_registration_report(
    profile_path: str | Path,
    camera_session: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    report = build_body_registration_report(
        profile_path,
        camera_session,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report
