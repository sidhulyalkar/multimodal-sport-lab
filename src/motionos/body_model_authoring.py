from __future__ import annotations

import json
import math
import statistics
from dataclasses import asdict, dataclass
from pathlib import Path

from .body_model import (
    BODY_MODEL_SCHEMA_VERSION,
    BodyModelProfile,
    load_body_model_profile,
    register_vision_pose,
)
from .provenance import (
    session_evidence_sha256,
    sha256_file,
    source_evidence_hashes,
)
from .session import SessionReader


@dataclass(frozen=True)
class RegistrationFrameResult:
    sequence: int
    device_time_ns: int
    residual_rms_m: float
    residual_max_m: float
    scale: float
    translation_m: tuple[float, float, float]
    rotation: tuple[
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
    ]

    def to_dict(self) -> dict[str, object]:
        return {
            "sequence": self.sequence,
            "device_time_ns": self.device_time_ns,
            "residual_rms_m": self.residual_rms_m,
            "residual_max_m": self.residual_max_m,
            "scale": self.scale,
            "translation_m": list(self.translation_m),
            "rotation": [list(row) for row in self.rotation],
        }


@dataclass(frozen=True)
class RegistrationFailure:
    sequence: int
    device_time_ns: int
    reason: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class RegistrationRepeatabilityReport:
    profile_id: str
    profile_sha256: str | None
    camera_session_id: str
    camera_bundle_sha256: str
    camera_source_evidence_sha256: dict[str, str]
    landmarks_used: tuple[str, ...]
    total_pose_frames: int
    successful_registrations: int
    failed_registrations: int
    successful_span_s: float | None
    residual_rms_median: float | None
    residual_rms_p95: float | None
    residual_rms_max: float | None
    scale_median: float | None
    scale_min: float | None
    scale_max: float | None
    scale_range: float | None
    scale_coefficient_of_variation: float | None
    frames: tuple[RegistrationFrameResult, ...]
    failures: tuple[RegistrationFailure, ...]
    schema_version: str = "motionos.body-registration-repeatability.v1"

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "profile_id": self.profile_id,
            "profile_sha256": self.profile_sha256,
            "camera_session_id": self.camera_session_id,
            "camera_bundle_sha256": self.camera_bundle_sha256,
            "camera_source_evidence_sha256": dict(
                self.camera_source_evidence_sha256
            ),
            "landmarks_used": list(self.landmarks_used),
            "counts": {
                "total_pose_frames": self.total_pose_frames,
                "successful_registrations":
                    self.successful_registrations,
                "failed_registrations": self.failed_registrations,
            },
            "successful_span_s": self.successful_span_s,
            "residual_rms_m": {
                "median": self.residual_rms_median,
                "p95": self.residual_rms_p95,
                "max": self.residual_rms_max,
            },
            "scale": {
                "median": self.scale_median,
                "min": self.scale_min,
                "max": self.scale_max,
                "range": self.scale_range,
                "coefficient_of_variation":
                    self.scale_coefficient_of_variation,
            },
            "frames": [frame.to_dict() for frame in self.frames],
            "failures": [failure.to_dict() for failure in self.failures],
            "claim_boundary": (
                "Registration repeatability measures consistency, not "
                "ground-truth body geometry or biomechanical accuracy."
            ),
        }


def build_body_model_profile(
    spec_path: str | Path,
    output_path: str | Path,
) -> BodyModelProfile:
    spec_file = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("body-model authoring spec must contain a JSON object")

    source_raw = raw.get("source_artifact")
    if source_raw is None:
        raise ValueError("source_artifact is required")
    source_artifact = Path(str(source_raw))
    if not source_artifact.is_absolute():
        source_artifact = (spec_file.parent / source_artifact).resolve()
    if not source_artifact.is_file():
        raise FileNotFoundError(
            f"body-model source artifact does not exist: {source_artifact}"
        )

    raw_landmarks = raw.get("landmarks_m")
    if not isinstance(raw_landmarks, dict):
        raise TypeError("landmarks_m must be an object")
    landmarks = {
        str(name): _point3(value, label=f"landmark {name!r}")
        for name, value in raw_landmarks.items()
    }

    raw_pairs = raw.get("segment_pairs", {})
    if not isinstance(raw_pairs, dict):
        raise TypeError("segment_pairs must be an object")

    raw_explicit = raw.get("segments_m", {})
    if not isinstance(raw_explicit, dict):
        raise TypeError("segments_m must be an object")
    explicit = {
        str(name): float(value)
        for name, value in raw_explicit.items()
    }

    duplicate = sorted(set(raw_pairs) & set(explicit))
    if duplicate:
        raise ValueError(
            "segment names cannot appear in both segment_pairs and segments_m: "
            + ", ".join(duplicate)
        )

    segments = dict(explicit)
    for name, pair in raw_pairs.items():
        segment_name = str(name)
        if not isinstance(pair, list) or len(pair) != 2:
            raise ValueError(
                f"segment pair {segment_name!r} must contain two landmarks"
            )
        start_name = str(pair[0])
        end_name = str(pair[1])
        if start_name not in landmarks or end_name not in landmarks:
            missing = [
                landmark
                for landmark in (start_name, end_name)
                if landmark not in landmarks
            ]
            raise ValueError(
                f"segment {segment_name!r} is missing landmarks: "
                + ", ".join(missing)
            )
        distance = _distance(
            landmarks[start_name],
            landmarks[end_name],
        )
        if distance <= 1e-9:
            raise ValueError(
                f"segment {segment_name!r} has zero-length geometry"
            )
        segments[segment_name] = distance

    profile = {
        "schema_version": BODY_MODEL_SCHEMA_VERSION,
        "model_id": str(raw["model_id"]),
        "height_m": float(raw["height_m"]),
        "frame_convention": str(raw["frame_convention"]),
        "landmarks_m": {
            name: list(point)
            for name, point in landmarks.items()
        },
        "segments_m": segments,
        "joint_limits_deg": raw.get("joint_limits_deg", {}),
        "registration_landmarks": raw["registration_landmarks"],
        "source": {
            "type": str(raw.get("source_type", "3d_body_scan")),
            "artifact_sha256": sha256_file(source_artifact),
            "notes": (
                str(raw["source_notes"])
                if raw.get("source_notes") is not None
                else None
            ),
        },
        "metadata": dict(raw.get("metadata", {})),
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(profile, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return load_body_model_profile(output)


def evaluate_body_registration(
    profile_path: str | Path,
    camera_session: str | Path,
) -> RegistrationRepeatabilityReport:
    profile = load_body_model_profile(profile_path)
    reader = SessionReader(camera_session)
    pose_events = list(reader.iter_stream("/camera/pose3d"))

    successes: list[RegistrationFrameResult] = []
    failures: list[RegistrationFailure] = []

    for event in pose_events:
        try:
            registered = register_vision_pose(event, profile)
        except (KeyError, TypeError, ValueError) as exc:
            failures.append(
                RegistrationFailure(
                    sequence=event.sequence,
                    device_time_ns=event.device_time_ns,
                    reason=f"{type(exc).__name__}: {exc}",
                )
            )
            continue

        receipt = registered.receipt
        successes.append(
            RegistrationFrameResult(
                sequence=event.sequence,
                device_time_ns=event.device_time_ns,
                residual_rms_m=receipt.residual_rms_m,
                residual_max_m=receipt.residual_max_m,
                scale=receipt.transform.scale,
                translation_m=receipt.transform.translation_m,
                rotation=receipt.transform.rotation,
            )
        )

    residuals = [frame.residual_rms_m for frame in successes]
    scales = [frame.scale for frame in successes]

    span_s = None
    if len(successes) >= 2:
        span_s = (
            successes[-1].device_time_ns
            - successes[0].device_time_ns
        ) / 1e9
    elif len(successes) == 1:
        span_s = 0.0

    scale_cv = None
    if scales:
        mean_scale = statistics.fmean(scales)
        if abs(mean_scale) > 1e-12:
            scale_cv = statistics.pstdev(scales) / abs(mean_scale)

    return RegistrationRepeatabilityReport(
        profile_id=profile.model_id,
        profile_sha256=profile.profile_sha256,
        camera_session_id=reader.manifest.session_id,
        camera_bundle_sha256=session_evidence_sha256(reader),
        camera_source_evidence_sha256=source_evidence_hashes(reader),
        landmarks_used=profile.registration_landmarks,
        total_pose_frames=len(pose_events),
        successful_registrations=len(successes),
        failed_registrations=len(failures),
        successful_span_s=span_s,
        residual_rms_median=(
            statistics.median(residuals)
            if residuals
            else None
        ),
        residual_rms_p95=_percentile(residuals, 0.95),
        residual_rms_max=max(residuals) if residuals else None,
        scale_median=statistics.median(scales) if scales else None,
        scale_min=min(scales) if scales else None,
        scale_max=max(scales) if scales else None,
        scale_range=(
            max(scales) - min(scales)
            if scales
            else None
        ),
        scale_coefficient_of_variation=scale_cv,
        frames=tuple(successes),
        failures=tuple(failures),
    )


def write_registration_repeatability_report(
    profile_path: str | Path,
    camera_session: str | Path,
    output_path: str | Path,
) -> RegistrationRepeatabilityReport:
    report = evaluate_body_registration(
        profile_path,
        camera_session,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def _point3(
    value: object,
    *,
    label: str,
) -> tuple[float, float, float]:
    if not isinstance(value, list) or len(value) != 3:
        raise ValueError(f"{label} must contain exactly three values")
    try:
        point = (
            float(value[0]),
            float(value[1]),
            float(value[2]),
        )
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not all(math.isfinite(component) for component in point):
        raise ValueError(f"{label} must be finite")
    return point


def _distance(
    first: tuple[float, float, float],
    second: tuple[float, float, float],
) -> float:
    return math.sqrt(
        sum(
            (left - right) ** 2
            for left, right in zip(first, second)
        )
    )


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    if not 0.0 <= fraction <= 1.0:
        raise ValueError("percentile fraction must be between 0 and 1")

    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    position = fraction * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return (
        ordered[lower] * (1.0 - weight)
        + ordered[upper] * weight
    )
