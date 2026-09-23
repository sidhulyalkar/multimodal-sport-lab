from __future__ import annotations

import bisect
import json
import math
import statistics
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path

from .camera import CAMERA_POSE_STREAM
from .clock_uncertainty import (
    CLOCK_UNCERTAINTY_SCHEMA_VERSION,
    WeightedAffineClockModel,
)
from .provenance import session_evidence_sha256, sha256_file
from .session import SessionReader

RESIDUAL_SPEC_SCHEMA_VERSION = "motionos.cross-modal-residual-spec.v1"
RESIDUAL_REPORT_SCHEMA_VERSION = "motionos.cross-modal-residual-report.v1"
VISUAL_CONTACT_SCHEMA_VERSION = "motionos.visual-contact-events.v1"
STRATA_SCHEMA_VERSION = "motionos.robustness-strata.v1"
GEOMETRY_SCHEMA_VERSION = "motionos.geometry-measurements.v1"
BODY_REGISTRATION_SCHEMA_VERSION = "motionos.body-registration-report.v1"

STRATA_FIELDS = (
    "motion_speed",
    "occlusion",
    "pose_confidence",
    "distance_framing",
    "sensor_gap",
    "day_id",
    "remount_id",
    "camera_view",
)


@dataclass(frozen=True)
class ArtifactReference:
    path: Path
    sha256: str


@dataclass(frozen=True)
class SessionReference:
    path: Path
    bundle_sha256: str
    reader: SessionReader


@dataclass(frozen=True)
class ClockAnalysis:
    path: Path
    sha256: str
    reference_session_id: str
    reference_bundle_sha256: str
    target_session_id: str
    target_bundle_sha256: str
    model: WeightedAffineClockModel


@dataclass(frozen=True)
class AngularVelocitySample:
    time_ns: int
    omega_rad_s: tuple[float, float, float]
    segment_unit: tuple[float, float, float]
    dt_s: float


@dataclass(frozen=True)
class MappedImuSample:
    device_time_ns: int
    reference_time_ns: int
    gyro_pose_rad_s: tuple[float, float, float]
    predictive_std_ns: float


@dataclass(frozen=True)
class ContactEvent:
    event: str
    time_ns: int
    source_device_time_ns: int | None
    uncertainty_ns: float


def _resolve(raw: object, *, base: Path, label: str) -> Path:
    value = str(raw).strip()
    if not value:
        raise ValueError(f"{label} must be non-empty")
    path = Path(value)
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def _text(value: object, *, label: str) -> str:
    result = str(value).strip()
    if not result:
        raise ValueError(f"{label} must be non-empty")
    return result


def _positive_number(value: object, *, label: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not math.isfinite(number) or number <= 0:
        raise ValueError(f"{label} must be positive and finite")
    return number


def _nonnegative_number(value: object, *, label: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not math.isfinite(number) or number < 0:
        raise ValueError(f"{label} must be non-negative and finite")
    return number


def _artifact_reference(
    raw: object,
    *,
    base: Path,
    label: str,
) -> ArtifactReference:
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must be an object")
    path = _resolve(raw.get("path", ""), base=base, label=f"{label}.path")
    if not path.is_file():
        raise FileNotFoundError(f"{label} does not exist: {path}")
    expected = _text(raw.get("sha256", ""), label=f"{label}.sha256").lower()
    actual = sha256_file(path)
    if actual != expected:
        raise ValueError(f"{label} hash mismatch")
    return ArtifactReference(path=path, sha256=actual)


def _session_reference(
    raw: object,
    *,
    base: Path,
    label: str,
) -> SessionReference:
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must be an object")
    path = _resolve(
        raw.get("session", ""),
        base=base,
        label=f"{label}.session",
    )
    if not path.is_dir():
        raise FileNotFoundError(f"{label} session does not exist: {path}")
    reader = SessionReader(path)
    actual = session_evidence_sha256(reader)
    expected = _text(
        raw.get("bundle_sha256", ""),
        label=f"{label}.bundle_sha256",
    ).lower()
    if actual != expected:
        raise ValueError(f"{label} session bundle hash mismatch")
    return SessionReference(
        path=path,
        bundle_sha256=actual,
        reader=reader,
    )


def _weighted_model(raw: dict[str, object]) -> WeightedAffineClockModel:
    covariance = raw.get("covariance_at_origin")
    if not isinstance(covariance, dict):
        raise TypeError("clock uncertainty covariance must be an object")
    return WeightedAffineClockModel(
        slope=float(raw["slope"]),
        intercept_ns=float(raw["intercept_ns"]),
        origin_device_time_ns=float(raw["origin_device_time_ns"]),
        origin_session_time_ns=float(raw["origin_session_time_ns"]),
        residual_rms_ns=float(raw["residual_rms_ns"]),
        reduced_chi_square=float(raw["reduced_chi_square"]),
        variance_scale=float(raw["variance_scale"]),
        origin_variance_ns2=float(covariance["origin_variance_ns2"]),
        origin_slope_covariance_ns=float(
            covariance["origin_slope_covariance_ns"]
        ),
        slope_variance=float(covariance["slope_variance"]),
        observations_used=int(raw["observations_used"]),
        support_start_ns=int(raw["support_start_ns"]),
        support_end_ns=int(raw["support_end_ns"]),
    )


def _clock_analysis(
    raw: object,
    *,
    base: Path,
    reference: SessionReference,
    target: SessionReference,
    label: str,
) -> ClockAnalysis:
    artifact = _artifact_reference(raw, base=base, label=label)
    data = json.loads(artifact.path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError(f"{label} must contain a JSON object")
    if data.get("schema_version") != CLOCK_UNCERTAINTY_SCHEMA_VERSION:
        raise ValueError(f"{label} has unsupported clock uncertainty schema")

    reference_raw = data.get("reference")
    target_raw = data.get("target")
    model_raw = data.get("weighted_affine")
    if not isinstance(reference_raw, dict):
        raise TypeError(f"{label}.reference must be an object")
    if not isinstance(target_raw, dict):
        raise TypeError(f"{label}.target must be an object")
    if not isinstance(model_raw, dict):
        raise TypeError(f"{label}.weighted_affine must be an object")

    reference_id = str(reference_raw.get("session_id", ""))
    target_id = str(target_raw.get("session_id", ""))
    reference_bundle = str(reference_raw.get("bundle_sha256", ""))
    target_bundle = str(target_raw.get("bundle_sha256", ""))

    if reference_id != reference.reader.manifest.session_id:
        raise ValueError(f"{label} reference session ID mismatch")
    if target_id != target.reader.manifest.session_id:
        raise ValueError(f"{label} target session ID mismatch")
    if reference_bundle != reference.bundle_sha256:
        raise ValueError(f"{label} reference bundle hash mismatch")
    if target_bundle != target.bundle_sha256:
        raise ValueError(f"{label} target bundle hash mismatch")

    return ClockAnalysis(
        path=artifact.path,
        sha256=artifact.sha256,
        reference_session_id=reference_id,
        reference_bundle_sha256=reference_bundle,
        target_session_id=target_id,
        target_bundle_sha256=target_bundle,
        model=_weighted_model(model_raw),
    )


def _vector3(value: object, *, label: str) -> tuple[float, float, float]:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"{label} must contain three values")
    try:
        point = (float(value[0]), float(value[1]), float(value[2]))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not all(math.isfinite(item) for item in point):
        raise ValueError(f"{label} must be finite")
    return point


def _subtract(
    left: tuple[float, float, float],
    right: tuple[float, float, float],
) -> tuple[float, float, float]:
    return tuple(left[index] - right[index] for index in range(3))


def _scale(
    value: tuple[float, float, float],
    factor: float,
) -> tuple[float, float, float]:
    return tuple(component * factor for component in value)


def _dot(
    left: tuple[float, float, float],
    right: tuple[float, float, float],
) -> float:
    return sum(left[index] * right[index] for index in range(3))


def _cross(
    left: tuple[float, float, float],
    right: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    )


def _norm(value: tuple[float, float, float]) -> float:
    return math.sqrt(_dot(value, value))


def _unit(
    value: tuple[float, float, float],
    *,
    label: str,
) -> tuple[float, float, float]:
    magnitude = _norm(value)
    if magnitude <= 1e-12:
        raise ValueError(f"{label} has zero length")
    return _scale(value, 1.0 / magnitude)


def _rotation_matrix(
    raw: object,
    *,
    label: str,
) -> tuple[tuple[float, float, float], ...]:
    if not isinstance(raw, list) or len(raw) != 3:
        raise ValueError(f"{label} must be a 3x3 matrix")
    rows = tuple(
        _vector3(row, label=f"{label}[{index}]")
        for index, row in enumerate(raw)
    )
    for index, row in enumerate(rows):
        if abs(_norm(row) - 1.0) > 1e-3:
            raise ValueError(f"{label} row {index} is not unit length")
    for left, right in ((0, 1), (0, 2), (1, 2)):
        if abs(_dot(rows[left], rows[right])) > 1e-3:
            raise ValueError(f"{label} rows are not orthogonal")
    determinant = _dot(rows[0], _cross(rows[1], rows[2]))
    if abs(determinant - 1.0) > 1e-3:
        raise ValueError(f"{label} must be a proper rotation matrix")
    return rows


def _rotate(
    matrix: tuple[tuple[float, float, float], ...],
    value: tuple[float, float, float],
) -> tuple[float, float, float]:
    return tuple(_dot(row, value) for row in matrix)


def _segment_vector(
    event_payload: dict[str, object],
    *,
    proximal_joint: str,
    distal_joint: str,
) -> tuple[float, float, float]:
    if (
        event_payload.get("joint_coordinate_frame")
        != "vision_root_joint_relative_meters"
    ):
        raise ValueError(
            "camera segment kinematics require "
            "vision_root_joint_relative_meters"
        )
    joints = event_payload.get("joints_root_relative_m")
    if not isinstance(joints, dict):
        raise TypeError("camera pose lacks joints_root_relative_m")
    if proximal_joint not in joints or distal_joint not in joints:
        raise KeyError(
            f"camera pose lacks {proximal_joint!r} or {distal_joint!r}"
        )
    proximal = _vector3(
        joints[proximal_joint],
        label=f"joint {proximal_joint}",
    )
    distal = _vector3(
        joints[distal_joint],
        label=f"joint {distal_joint}",
    )
    return _subtract(distal, proximal)


def _camera_angular_velocity(
    reader: SessionReader,
    *,
    proximal_joint: str,
    distal_joint: str,
    max_pose_interval_s: float,
) -> tuple[list[AngularVelocitySample], dict[str, int]]:
    poses = sorted(
        reader.iter_stream(CAMERA_POSE_STREAM),
        key=lambda item: item.device_time_ns,
    )
    samples: list[AngularVelocitySample] = []
    skipped = {
        "missing_joint_or_invalid_pose": 0,
        "nonpositive_dt": 0,
        "pose_interval_too_large": 0,
        "degenerate_segment": 0,
    }

    for previous, current in pairwise(poses):
        dt_ns = current.device_time_ns - previous.device_time_ns
        if dt_ns <= 0:
            skipped["nonpositive_dt"] += 1
            continue
        dt_s = dt_ns / 1e9
        if dt_s > max_pose_interval_s:
            skipped["pose_interval_too_large"] += 1
            continue
        try:
            previous_vector = _segment_vector(
                previous.payload,
                proximal_joint=proximal_joint,
                distal_joint=distal_joint,
            )
            current_vector = _segment_vector(
                current.payload,
                proximal_joint=proximal_joint,
                distal_joint=distal_joint,
            )
            previous_unit = _unit(
                previous_vector,
                label="previous segment",
            )
            current_unit = _unit(
                current_vector,
                label="current segment",
            )
        except (KeyError, TypeError):
            skipped["missing_joint_or_invalid_pose"] += 1
            continue
        except ValueError:
            skipped["degenerate_segment"] += 1
            continue

        cross = _cross(previous_unit, current_unit)
        cross_norm = _norm(cross)
        dot = max(-1.0, min(1.0, _dot(previous_unit, current_unit)))
        angle = math.atan2(cross_norm, dot)
        if cross_norm <= 1e-12 or angle <= 1e-12:
            omega = (0.0, 0.0, 0.0)
        else:
            axis = _scale(cross, 1.0 / cross_norm)
            omega = _scale(axis, angle / dt_s)

        samples.append(
            AngularVelocitySample(
                time_ns=current.device_time_ns,
                omega_rad_s=omega,
                segment_unit=current_unit,
                dt_s=dt_s,
            )
        )
    return samples, skipped


def _mapped_imu_samples(
    reader: SessionReader,
    *,
    stream: str,
    rotation: tuple[tuple[float, float, float], ...],
    clock: ClockAnalysis,
) -> list[MappedImuSample]:
    samples: list[MappedImuSample] = []
    for event in reader.iter_stream(stream):
        try:
            gyro = (
                float(event.payload["gx"]),
                float(event.payload["gy"]),
                float(event.payload["gz"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"IMU stream {stream!r} lacks numeric gx/gy/gz"
            ) from exc
        if not all(math.isfinite(value) for value in gyro):
            raise ValueError(f"IMU stream {stream!r} has non-finite gyro")
        samples.append(
            MappedImuSample(
                device_time_ns=event.device_time_ns,
                reference_time_ns=clock.model.map(event.device_time_ns),
                gyro_pose_rad_s=_rotate(rotation, gyro),
                predictive_std_ns=clock.model.predictive_std_ns(
                    event.device_time_ns
                ),
            )
        )
    return sorted(samples, key=lambda item: item.reference_time_ns)


def _nearest_imu(
    samples: list[MappedImuSample],
    times: list[int],
    target_time_ns: int,
    *,
    excluded_indices: set[int],
) -> tuple[int, MappedImuSample] | None:
    if not samples:
        return None
    insertion = bisect.bisect_left(times, target_time_ns)
    candidates: list[tuple[int, MappedImuSample]] = []
    left = insertion - 1
    right = insertion
    while left >= 0 or right < len(samples):
        if left >= 0 and left not in excluded_indices:
            candidates.append((left, samples[left]))
        if right < len(samples) and right not in excluded_indices:
            candidates.append((right, samples[right]))
        if candidates:
            break
        left -= 1
        right += 1
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda item: abs(
            item[1].reference_time_ns - target_time_ns
        ),
    )


def _distribution(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "rms": None,
            "p95_abs": None,
            "max_abs": None,
        }
    absolute = sorted(abs(value) for value in values)
    rank = min(len(absolute) - 1, math.ceil(0.95 * len(absolute)) - 1)
    return {
        "count": len(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "rms": math.sqrt(
            sum(value * value for value in values) / len(values)
        ),
        "p95_abs": absolute[rank],
        "max_abs": absolute[-1],
    }


def _load_strata(
    raw: object,
    *,
    base: Path,
) -> tuple[ArtifactReference | None, list[dict[str, object]]]:
    if raw is None:
        return None, []
    artifact = _artifact_reference(raw, base=base, label="strata")
    data = json.loads(artifact.path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("strata artifact must contain a JSON object")
    if data.get("schema_version") != STRATA_SCHEMA_VERSION:
        raise ValueError("unsupported robustness strata schema")
    intervals_raw = data.get("intervals")
    if not isinstance(intervals_raw, list):
        raise TypeError("robustness strata intervals must be a list")

    intervals: list[dict[str, object]] = []
    for index, item in enumerate(intervals_raw):
        if not isinstance(item, dict):
            raise TypeError(f"strata interval {index} must be an object")
        start = int(item["start_ns"])
        end = int(item["end_ns"])
        labels = item.get("labels")
        if start < 0 or end <= start:
            raise ValueError(f"strata interval {index} must have start < end")
        if not isinstance(labels, dict):
            raise TypeError(f"strata interval {index}.labels must be an object")
        unknown = sorted(set(labels) - set(STRATA_FIELDS))
        if unknown:
            raise ValueError(
                "unsupported strata labels: " + ", ".join(unknown)
            )
        intervals.append(
            {
                "start_ns": start,
                "end_ns": end,
                "labels": {
                    str(key): _text(
                        value,
                        label=f"strata interval {index}.{key}",
                    )
                    for key, value in labels.items()
                },
            }
        )
    return artifact, intervals


def _labels_at(
    time_ns: int,
    intervals: list[dict[str, object]],
) -> dict[str, str]:
    labels = {field: "__unlabeled__" for field in STRATA_FIELDS}
    for interval in intervals:
        if int(interval["start_ns"]) <= time_ns <= int(interval["end_ns"]):
            raw_labels = interval["labels"]
            assert isinstance(raw_labels, dict)
            for key, value in raw_labels.items():
                existing = labels[str(key)]
                if existing not in {"__unlabeled__", str(value)}:
                    raise ValueError(
                        f"conflicting stratum labels for {key!r} at {time_ns}"
                    )
                labels[str(key)] = str(value)
    return labels


def _stratify(
    samples: list[dict[str, object]],
    *,
    value_key: str,
) -> dict[str, object]:
    report: dict[str, object] = {}
    for field in STRATA_FIELDS:
        buckets: dict[str, list[float]] = {}
        for sample in samples:
            labels = sample.get("strata")
            if not isinstance(labels, dict):
                continue
            label = str(labels.get(field, "__unlabeled__"))
            value = sample.get(value_key)
            if value is None:
                continue
            buckets.setdefault(label, []).append(float(value))
        report[field] = {
            label: _distribution(values)
            for label, values in sorted(buckets.items())
        }
    return report


def _imu_video_comparison(
    raw: dict[str, object],
    *,
    base: Path,
    camera: SessionReference,
    intervals: list[dict[str, object]],
) -> dict[str, object]:
    comparison_id = _text(
        raw.get("comparison_id", ""),
        label="imu_video.comparison_id",
    )
    imu = _session_reference(
        raw.get("imu"),
        base=base,
        label=f"{comparison_id}.imu",
    )
    clock = _clock_analysis(
        raw.get("clock_uncertainty"),
        base=base,
        reference=camera,
        target=imu,
        label=f"{comparison_id}.clock_uncertainty",
    )
    stream = _text(raw.get("stream", ""), label=f"{comparison_id}.stream")
    proximal = _text(
        raw.get("proximal_joint", ""),
        label=f"{comparison_id}.proximal_joint",
    )
    distal = _text(
        raw.get("distal_joint", ""),
        label=f"{comparison_id}.distal_joint",
    )
    rotation = _rotation_matrix(
        raw.get("imu_to_pose_rotation"),
        label=f"{comparison_id}.imu_to_pose_rotation",
    )
    max_pairing_delta_ns = round(
        _positive_number(
            raw.get("max_pairing_delta_ms", 30.0),
            label=f"{comparison_id}.max_pairing_delta_ms",
        )
        * 1e6
    )
    max_pose_interval_s = (
        _positive_number(
            raw.get("max_pose_interval_ms", 100.0),
            label=f"{comparison_id}.max_pose_interval_ms",
        )
        / 1e3
    )

    visual, skipped = _camera_angular_velocity(
        camera.reader,
        proximal_joint=proximal,
        distal_joint=distal,
        max_pose_interval_s=max_pose_interval_s,
    )
    imu_samples = _mapped_imu_samples(
        imu.reader,
        stream=stream,
        rotation=rotation,
        clock=clock,
    )
    imu_times = [item.reference_time_ns for item in imu_samples]

    samples: list[dict[str, object]] = []
    unmatched_visual = 0
    used_imu_indices: set[int] = set()
    for visual_sample in visual:
        nearest = _nearest_imu(
            imu_samples,
            imu_times,
            visual_sample.time_ns,
            excluded_indices=used_imu_indices,
        )
        if nearest is None:
            unmatched_visual += 1
            continue
        matched_index, matched = nearest
        if (
            abs(matched.reference_time_ns - visual_sample.time_ns)
            > max_pairing_delta_ns
        ):
            unmatched_visual += 1
            continue
        used_imu_indices.add(matched_index)

        axial = _scale(
            visual_sample.segment_unit,
            _dot(
                matched.gyro_pose_rad_s,
                visual_sample.segment_unit,
            ),
        )
        gyro_perpendicular = _subtract(
            matched.gyro_pose_rad_s,
            axial,
        )
        residual = _subtract(
            gyro_perpendicular,
            visual_sample.omega_rad_s,
        )
        residual_norm = _norm(residual)
        samples.append(
            {
                "reference_time_ns": visual_sample.time_ns,
                "visual_omega_rad_s": list(visual_sample.omega_rad_s),
                "visual_omega_magnitude_rad_s": _norm(
                    visual_sample.omega_rad_s
                ),
                "transformed_gyro_rad_s": list(
                    matched.gyro_pose_rad_s
                ),
                "transformed_gyro_perpendicular_rad_s": list(
                    gyro_perpendicular
                ),
                "residual_rad_s": list(residual),
                "residual_norm_rad_s": residual_norm,
                "pairing_delta_ms": (
                    matched.reference_time_ns - visual_sample.time_ns
                )
                / 1e6,
                "clock_predictive_std_ms": (
                    matched.predictive_std_ns / 1e6
                ),
                "pose_interval_ms": visual_sample.dt_s * 1e3,
                "strata": _labels_at(
                    visual_sample.time_ns,
                    intervals,
                ),
            }
        )

    residuals = [
        float(sample["residual_norm_rad_s"])
        for sample in samples
    ]
    pairing = [
        float(sample["pairing_delta_ms"])
        for sample in samples
    ]
    return {
        "comparison_id": comparison_id,
        "kind": "vision_segment_vs_transformed_gyro_perpendicular",
        "camera_session_id": camera.reader.manifest.session_id,
        "imu_session_id": imu.reader.manifest.session_id,
        "imu_stream": stream,
        "segment": {
            "proximal_joint": proximal,
            "distal_joint": distal,
            "coordinate_frame": "vision_root_joint_relative_meters",
        },
        "clock_uncertainty_sha256": clock.sha256,
        "pairing": {
            "max_pairing_delta_ms": max_pairing_delta_ns / 1e6,
            "matched_samples": len(samples),
            "unmatched_visual_samples": unmatched_visual,
            "visual_samples_available": len(visual),
            "skipped_visual_intervals": skipped,
        },
        "residual_norm_rad_s": _distribution(residuals),
        "pairing_delta_ms": _distribution(pairing),
        "stratified_residual_norm_rad_s": _stratify(
            samples,
            value_key="residual_norm_rad_s",
        ),
        "samples": samples,
        "claim_boundary": (
            "Vision observes segment-axis rotation but not twist about the "
            "segment axis. The IMU gyro is rotated into the declared pose "
            "frame and projected perpendicular to the visual segment axis "
            "before comparison. This is a consistency residual, not a "
            "ground-truth angular-velocity error."
        ),
    }


def _visual_contact_events(
    artifact: ArtifactReference,
    *,
    side: str,
) -> list[ContactEvent]:
    raw = json.loads(artifact.path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("visual contact artifact must contain a JSON object")
    if raw.get("schema_version") != VISUAL_CONTACT_SCHEMA_VERSION:
        raise ValueError("unsupported visual contact event schema")
    events_raw = raw.get("events")
    if not isinstance(events_raw, list):
        raise TypeError("visual contact events must be a list")

    events: list[ContactEvent] = []
    for index, item in enumerate(events_raw):
        if not isinstance(item, dict):
            raise TypeError(f"visual contact event {index} must be an object")
        if str(item.get("side")) != side:
            continue
        event = str(item.get("event", ""))
        if event not in {"contact_onset", "contact_release"}:
            raise ValueError(f"unsupported visual contact event: {event}")
        uncertainty = _positive_number(
            item.get("uncertainty_ns"),
            label=f"visual contact event {index}.uncertainty_ns",
        )
        events.append(
            ContactEvent(
                event=event,
                time_ns=int(item["time_ns"]),
                source_device_time_ns=None,
                uncertainty_ns=uncertainty,
            )
        )
    return sorted(events, key=lambda item: item.time_ns)


def _pressure_contact_events(
    reader: SessionReader,
    *,
    stream: str,
    threshold_n: float,
    clock: ClockAnalysis,
) -> list[ContactEvent]:
    events = sorted(
        reader.iter_stream(stream),
        key=lambda item: item.device_time_ns,
    )
    result: list[ContactEvent] = []
    previous_above: bool | None = None
    for item in events:
        try:
            force = float(item.payload["normal_force_n"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(
                f"pressure stream {stream!r} lacks numeric normal_force_n"
            ) from exc
        if not math.isfinite(force) or force < 0:
            raise ValueError(
                f"pressure stream {stream!r} has invalid normal_force_n"
            )
        above = force >= threshold_n
        if previous_above is None:
            previous_above = above
            continue
        event_name = None
        if not previous_above and above:
            event_name = "contact_onset"
        elif previous_above and not above:
            event_name = "contact_release"
        previous_above = above
        if event_name is None:
            continue
        result.append(
            ContactEvent(
                event=event_name,
                time_ns=clock.model.map(item.device_time_ns),
                source_device_time_ns=item.device_time_ns,
                uncertainty_ns=clock.model.predictive_std_ns(
                    item.device_time_ns
                ),
            )
        )
    return result


def _pressure_video_comparison(
    raw: dict[str, object],
    *,
    base: Path,
    camera: SessionReference,
    intervals: list[dict[str, object]],
) -> dict[str, object]:
    comparison_id = _text(
        raw.get("comparison_id", ""),
        label="pressure_video.comparison_id",
    )
    side = _text(raw.get("side", ""), label=f"{comparison_id}.side")
    if side not in {"left", "right"}:
        raise ValueError(f"{comparison_id}.side must be left or right")
    insole = _session_reference(
        raw.get("insole"),
        base=base,
        label=f"{comparison_id}.insole",
    )
    clock = _clock_analysis(
        raw.get("clock_uncertainty"),
        base=base,
        reference=camera,
        target=insole,
        label=f"{comparison_id}.clock_uncertainty",
    )
    visual_artifact = _artifact_reference(
        raw.get("visual_events"),
        base=base,
        label=f"{comparison_id}.visual_events",
    )
    stream = _text(raw.get("stream", ""), label=f"{comparison_id}.stream")
    threshold = _positive_number(
        raw.get("force_threshold_n"),
        label=f"{comparison_id}.force_threshold_n",
    )
    max_match_delta_ns = round(
        _positive_number(
            raw.get("max_match_delta_ms", 250.0),
            label=f"{comparison_id}.max_match_delta_ms",
        )
        * 1e6
    )

    visual = _visual_contact_events(visual_artifact, side=side)
    pressure = _pressure_contact_events(
        insole.reader,
        stream=stream,
        threshold_n=threshold,
        clock=clock,
    )

    used_pressure: set[int] = set()
    samples: list[dict[str, object]] = []
    unmatched_visual = 0
    for visual_event in visual:
        candidates = [
            (index, pressure_event)
            for index, pressure_event in enumerate(pressure)
            if index not in used_pressure
            and pressure_event.event == visual_event.event
        ]
        if not candidates:
            unmatched_visual += 1
            continue
        index, matched = min(
            candidates,
            key=lambda item: abs(
                item[1].time_ns - visual_event.time_ns
            ),
        )
        residual_ns = matched.time_ns - visual_event.time_ns
        if abs(residual_ns) > max_match_delta_ns:
            unmatched_visual += 1
            continue
        used_pressure.add(index)
        combined_std = math.sqrt(
            matched.uncertainty_ns**2
            + visual_event.uncertainty_ns**2
        )
        samples.append(
            {
                "event": visual_event.event,
                "side": side,
                "visual_time_ns": visual_event.time_ns,
                "pressure_mapped_time_ns": matched.time_ns,
                "pressure_device_time_ns": matched.source_device_time_ns,
                "residual_ms": residual_ns / 1e6,
                "combined_timing_std_ms": combined_std / 1e6,
                "absolute_residual_over_combined_std": (
                    abs(residual_ns) / combined_std
                ),
                "strata": _labels_at(
                    visual_event.time_ns,
                    intervals,
                ),
            }
        )

    residuals = [float(sample["residual_ms"]) for sample in samples]
    ratios = [
        float(sample["absolute_residual_over_combined_std"])
        for sample in samples
    ]
    return {
        "comparison_id": comparison_id,
        "kind": "pressure_threshold_vs_reviewed_visual_contact",
        "side": side,
        "camera_session_id": camera.reader.manifest.session_id,
        "insole_session_id": insole.reader.manifest.session_id,
        "pressure_stream": stream,
        "force_threshold_n": threshold,
        "clock_uncertainty_sha256": clock.sha256,
        "visual_events_sha256": visual_artifact.sha256,
        "matching": {
            "max_match_delta_ms": max_match_delta_ns / 1e6,
            "visual_event_count": len(visual),
            "pressure_event_count": len(pressure),
            "matched_events": len(samples),
            "unmatched_visual_events": unmatched_visual,
            "unmatched_pressure_events": len(pressure) - len(used_pressure),
        },
        "residual_ms": _distribution(residuals),
        "absolute_residual_over_combined_std": _distribution(ratios),
        "stratified_residual_ms": _stratify(
            samples,
            value_key="residual_ms",
        ),
        "samples": samples,
        "claim_boundary": (
            "Pressure contact is a threshold-defined normal-force event and "
            "visual contact is explicit reviewed evidence. Their timing "
            "difference measures cross-modal consistency only. The report "
            "does not infer contact from root-relative pose geometry."
        ),
    }


def _body_registration_geometry(
    raw: object,
    *,
    base: Path,
    camera: SessionReference,
    intervals: list[dict[str, object]],
) -> dict[str, object] | None:
    if raw is None:
        return None
    artifact = _artifact_reference(
        raw,
        base=base,
        label="body_registration_report",
    )
    data = json.loads(artifact.path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("body registration report must be a JSON object")
    if data.get("schema_version") != BODY_REGISTRATION_SCHEMA_VERSION:
        raise ValueError("unsupported body registration report schema")
    camera_raw = data.get("camera_session")
    if not isinstance(camera_raw, dict):
        raise TypeError(
            "body registration report camera_session must be an object"
        )
    if str(camera_raw.get("session_id", "")) != (
        camera.reader.manifest.session_id
    ):
        raise ValueError("body registration camera session ID mismatch")
    if str(camera_raw.get("bundle_sha256", "")) != camera.bundle_sha256:
        raise ValueError("body registration camera bundle hash mismatch")

    frames_raw = data.get("frames")
    if not isinstance(frames_raw, list):
        raise TypeError("body registration frames must be a list")

    samples: list[dict[str, object]] = []
    failed = 0
    for index, item in enumerate(frames_raw):
        if not isinstance(item, dict):
            raise TypeError(
                f"body registration frame {index} must be an object"
            )
        if item.get("success") is not True:
            failed += 1
            continue
        residual = item.get("residual_rms_m")
        if residual is None:
            raise ValueError(
                f"successful body registration frame {index} lacks residual"
            )
        time_ns = int(item["device_time_ns"])
        samples.append(
            {
                "time_ns": time_ns,
                "residual_rms_m": float(residual),
                "strata": _labels_at(time_ns, intervals),
            }
        )

    values = [
        float(sample["residual_rms_m"])
        for sample in samples
    ]
    return {
        "artifact_sha256": artifact.sha256,
        "successful_frames": len(samples),
        "failed_frames": failed,
        "residual_rms_m": _distribution(values),
        "stratified_residual_rms_m": _stratify(
            samples,
            value_key="residual_rms_m",
        ),
        "samples": samples,
        "claim_boundary": data.get("claim_boundary"),
    }


def _geometry_measurements(
    raw: object,
    *,
    base: Path,
    intervals: list[dict[str, object]],
) -> dict[str, object] | None:
    if raw is None:
        return None
    artifact = _artifact_reference(
        raw,
        base=base,
        label="geometry_measurements",
    )
    data = json.loads(artifact.path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("geometry measurements must be a JSON object")
    if data.get("schema_version") != GEOMETRY_SCHEMA_VERSION:
        raise ValueError("unsupported geometry measurements schema")
    measurements = data.get("measurements")
    if not isinstance(measurements, list):
        raise TypeError("geometry measurements must be a list")

    allowed = {
        "camera_reprojection_residual_px": "px",
        "cross_view_triangulation_disagreement_m": "m",
    }
    by_metric: dict[str, list[dict[str, object]]] = {
        key: [] for key in allowed
    }
    for index, item in enumerate(measurements):
        if not isinstance(item, dict):
            raise TypeError(f"geometry measurement {index} must be an object")
        metric = str(item.get("metric", ""))
        if metric not in allowed:
            raise ValueError(f"unsupported geometry metric: {metric}")
        if str(item.get("unit", "")) != allowed[metric]:
            raise ValueError(f"geometry metric {metric} has wrong unit")
        value = _nonnegative_number(
            item.get("value"),
            label=f"geometry measurement {index}.value",
        )
        time_ns = int(item["time_ns"])
        by_metric[metric].append(
            {
                "time_ns": time_ns,
                "value": value,
                "strata": _labels_at(time_ns, intervals),
            }
        )

    result: dict[str, object] = {
        "artifact_sha256": artifact.sha256,
        "metrics": {},
    }
    metrics = result["metrics"]
    assert isinstance(metrics, dict)
    for metric, samples in by_metric.items():
        values = [float(sample["value"]) for sample in samples]
        metrics[metric] = {
            "distribution": _distribution(values),
            "stratified": _stratify(samples, value_key="value"),
            "samples": samples,
        }
    return result


def build_cross_modal_residual_report(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    spec_file = Path(spec_path).resolve()
    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("cross-modal residual spec must be a JSON object")
    if raw.get("schema_version") != RESIDUAL_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported cross-modal residual spec schema")

    experiment_id = _text(
        raw.get("experiment_id", ""),
        label="experiment_id",
    )
    camera = _session_reference(
        raw.get("camera"),
        base=spec_file.parent,
        label="camera",
    )
    strata_artifact, intervals = _load_strata(
        raw.get("strata"),
        base=spec_file.parent,
    )

    imu_raw = raw.get("imu_video", [])
    if not isinstance(imu_raw, list):
        raise TypeError("imu_video must be a list")
    imu_video = []
    for index, item in enumerate(imu_raw):
        if not isinstance(item, dict):
            raise TypeError(f"imu_video {index} must be an object")
        imu_video.append(
            _imu_video_comparison(
                dict(item),
                base=spec_file.parent,
                camera=camera,
                intervals=intervals,
            )
        )

    pressure_raw = raw.get("pressure_video", [])
    if not isinstance(pressure_raw, list):
        raise TypeError("pressure_video must be a list")
    pressure_video = []
    for index, item in enumerate(pressure_raw):
        if not isinstance(item, dict):
            raise TypeError(f"pressure_video {index} must be an object")
        pressure_video.append(
            _pressure_video_comparison(
                dict(item),
                base=spec_file.parent,
                camera=camera,
                intervals=intervals,
            )
        )

    body_registration = _body_registration_geometry(
        raw.get("body_registration_report"),
        base=spec_file.parent,
        camera=camera,
        intervals=intervals,
    )
    geometry = _geometry_measurements(
        raw.get("geometry_measurements"),
        base=spec_file.parent,
        intervals=intervals,
    )

    report = {
        "schema_version": RESIDUAL_REPORT_SCHEMA_VERSION,
        "experiment_id": experiment_id,
        "spec_sha256": sha256_file(spec_file),
        "camera": {
            "session_id": camera.reader.manifest.session_id,
            "bundle_sha256": camera.bundle_sha256,
            "pose_stream": CAMERA_POSE_STREAM,
        },
        "strata": {
            "schema_version": (
                STRATA_SCHEMA_VERSION if strata_artifact is not None else None
            ),
            "artifact_sha256": (
                strata_artifact.sha256
                if strata_artifact is not None
                else None
            ),
            "fields": list(STRATA_FIELDS),
            "interval_count": len(intervals),
        },
        "imu_video": imu_video,
        "pressure_video": pressure_video,
        "geometry": {
            "body_registration": body_registration,
            "explicit_measurements": geometry,
            "camera_reprojection": (
                "available in explicit_measurements when independently "
                "computed 2D/3D correspondence evidence is supplied"
            ),
            "cross_view_triangulation": (
                "available in explicit_measurements when multi-view "
                "triangulation evidence is supplied"
            ),
        },
        "aggregation_policy": (
            "No scalar aggregate quality score is produced. Report "
            "modality-specific residual distributions and strata instead."
        ),
        "claim_boundary": (
            "Residual agreement measures consistency between evidence "
            "streams. It does not prove either stream is physically accurate "
            "unless one has an independent qualified reference."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report
