from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .provenance import sha256_file
from .schema import SensorEvent

BODY_MODEL_SCHEMA_VERSION = "motionos.body-model.v2"
DEFAULT_FRAME_CONVENTION = "+X right,+Y up,+Z forward"


Vector3 = tuple[float, float, float]
Matrix3 = tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]


@dataclass(frozen=True)
class BodyModelSource:
    type: str
    artifact_sha256: str | None
    notes: str | None = None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class BodyModelProfile:
    model_id: str
    height_m: float
    frame_convention: str
    landmarks_m: dict[str, Vector3]
    segments_m: dict[str, float]
    joint_limits_deg: dict[str, tuple[float, float]]
    registration_landmarks: tuple[str, ...]
    source: BodyModelSource
    metadata: dict[str, Any]
    profile_sha256: str | None = None
    schema_version: str = BODY_MODEL_SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.schema_version != BODY_MODEL_SCHEMA_VERSION:
            raise ValueError(
                f"unsupported body-model schema: {self.schema_version}"
            )
        if not self.model_id:
            raise ValueError("body model_id is required")
        if not math.isfinite(self.height_m) or self.height_m <= 0:
            raise ValueError("body height_m must be positive and finite")
        if not self.frame_convention:
            raise ValueError("body frame_convention is required")
        if len(self.landmarks_m) < 3:
            raise ValueError("body model requires at least three landmarks")
        if len(self.registration_landmarks) < 3:
            raise ValueError(
                "body model requires at least three registration landmarks"
            )
        if len(set(self.registration_landmarks)) != len(
            self.registration_landmarks
        ):
            raise ValueError("registration landmarks must be unique")

        for name, point in self.landmarks_m.items():
            if not name:
                raise ValueError("landmark names must be non-empty")
            _validate_vector(point, label=f"landmark {name!r}")

        for name in self.registration_landmarks:
            if name not in self.landmarks_m:
                raise ValueError(
                    f"registration landmark is missing from profile: {name}"
                )

        for name, length in self.segments_m.items():
            if not name:
                raise ValueError("segment names must be non-empty")
            if not math.isfinite(length) or length <= 0:
                raise ValueError(
                    f"segment length must be positive and finite: {name}"
                )

        for name, limits in self.joint_limits_deg.items():
            if len(limits) != 2:
                raise ValueError(
                    f"joint limits must contain min/max: {name}"
                )
            low, high = limits
            if (
                not math.isfinite(low)
                or not math.isfinite(high)
                or low > high
            ):
                raise ValueError(f"invalid joint limits: {name}")

        if self.source.artifact_sha256 is not None:
            digest = self.source.artifact_sha256.lower()
            if len(digest) != 64 or any(
                char not in "0123456789abcdef"
                for char in digest
            ):
                raise ValueError(
                    "source artifact_sha256 must be a 64-character hex digest"
                )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "model_id": self.model_id,
            "height_m": self.height_m,
            "frame_convention": self.frame_convention,
            "landmarks_m": {
                name: list(point)
                for name, point in sorted(self.landmarks_m.items())
            },
            "segments_m": dict(sorted(self.segments_m.items())),
            "joint_limits_deg": {
                name: list(limits)
                for name, limits in sorted(self.joint_limits_deg.items())
            },
            "registration_landmarks": list(self.registration_landmarks),
            "source": self.source.to_dict(),
            "metadata": dict(self.metadata),
            "profile_sha256": self.profile_sha256,
        }

    @classmethod
    def from_dict(
        cls,
        data: dict[str, Any],
        *,
        profile_sha256: str | None = None,
    ) -> BodyModelProfile:
        raw_landmarks = data.get("landmarks_m")
        if not isinstance(raw_landmarks, dict):
            raise TypeError("body model landmarks_m must be an object")

        landmarks = {
            str(name): _vector3(value, label=f"landmark {name!r}")
            for name, value in raw_landmarks.items()
        }

        raw_segments = data.get("segments_m", {})
        if not isinstance(raw_segments, dict):
            raise TypeError("body model segments_m must be an object")
        segments = {
            str(name): float(value)
            for name, value in raw_segments.items()
        }

        raw_limits = data.get("joint_limits_deg", {})
        if not isinstance(raw_limits, dict):
            raise TypeError(
                "body model joint_limits_deg must be an object"
            )
        limits = {
            str(name): (
                float(value[0]),
                float(value[1]),
            )
            for name, value in raw_limits.items()
        }

        raw_registration = data.get("registration_landmarks")
        if not isinstance(raw_registration, list):
            raise TypeError(
                "body model registration_landmarks must be a list"
            )
        registration = tuple(str(value) for value in raw_registration)

        raw_source = data.get("source")
        if not isinstance(raw_source, dict):
            raise TypeError("body model source must be an object")
        artifact_sha = raw_source.get("artifact_sha256")
        source = BodyModelSource(
            type=str(raw_source.get("type", "")).strip(),
            artifact_sha256=(
                str(artifact_sha)
                if artifact_sha is not None
                else None
            ),
            notes=(
                str(raw_source["notes"])
                if raw_source.get("notes") is not None
                else None
            ),
        )
        if not source.type:
            raise ValueError("body model source.type is required")

        metadata = data.get("metadata", {})
        if not isinstance(metadata, dict):
            raise TypeError("body model metadata must be an object")

        return cls(
            model_id=str(data["model_id"]),
            height_m=float(data["height_m"]),
            frame_convention=str(
                data.get(
                    "frame_convention",
                    DEFAULT_FRAME_CONVENTION,
                )
            ),
            landmarks_m=landmarks,
            segments_m=segments,
            joint_limits_deg=limits,
            registration_landmarks=registration,
            source=source,
            metadata=dict(metadata),
            profile_sha256=profile_sha256,
            schema_version=str(
                data.get(
                    "schema_version",
                    BODY_MODEL_SCHEMA_VERSION,
                )
            ),
        )


@dataclass(frozen=True)
class SimilarityTransform3D:
    scale: float
    rotation: Matrix3
    translation_m: Vector3

    def apply(self, point: Vector3) -> Vector3:
        rotated = _matvec(self.rotation, point)
        return (
            self.scale * rotated[0] + self.translation_m[0],
            self.scale * rotated[1] + self.translation_m[1],
            self.scale * rotated[2] + self.translation_m[2],
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "scale": self.scale,
            "rotation": [list(row) for row in self.rotation],
            "translation_m": list(self.translation_m),
        }


@dataclass(frozen=True)
class PoseRegistrationReceipt:
    profile_id: str
    profile_sha256: str | None
    source_pose_sequence: int
    source_pose_time_ns: int
    landmarks_used: tuple[str, ...]
    transform: SimilarityTransform3D
    residual_rms_m: float
    residual_max_m: float
    residuals_m: dict[str, float]

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": "motionos.pose-registration.v1",
            "profile_id": self.profile_id,
            "profile_sha256": self.profile_sha256,
            "source_pose_sequence": self.source_pose_sequence,
            "source_pose_time_ns": self.source_pose_time_ns,
            "landmarks_used": list(self.landmarks_used),
            "transform": self.transform.to_dict(),
            "residual_rms_m": self.residual_rms_m,
            "residual_max_m": self.residual_max_m,
            "residuals_m": dict(sorted(self.residuals_m.items())),
            "claim_boundary": (
                "This similarity registration is a derived visualization/"
                "conditioning transform from declared landmarks. Raw Vision "
                "pose remains unchanged."
            ),
        }


@dataclass(frozen=True)
class RegisteredPose:
    joints_body_model_m: dict[str, Vector3]
    receipt: PoseRegistrationReceipt

    def to_dict(self) -> dict[str, object]:
        return {
            "joints_body_model_m": {
                name: list(point)
                for name, point in sorted(
                    self.joints_body_model_m.items()
                )
            },
            "coordinate_frame": "personalized_body_model",
            "derived": True,
            "registration": self.receipt.to_dict(),
        }


def load_body_model_profile(
    path: str | Path,
) -> BodyModelProfile:
    source = Path(path)
    raw = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("body model profile must contain a JSON object")
    return BodyModelProfile.from_dict(
        raw,
        profile_sha256=sha256_file(source),
    )


def verify_body_model_source_artifact(
    profile: BodyModelProfile,
    artifact_path: str | Path,
) -> str:
    expected = profile.source.artifact_sha256
    if expected is None:
        raise ValueError(
            "body model profile does not declare a source artifact hash"
        )
    actual = sha256_file(artifact_path)
    if actual.lower() != expected.lower():
        raise ValueError("body model source artifact SHA-256 mismatch")
    return actual


def fit_similarity_transform(
    source_points: dict[str, Vector3],
    target_points: dict[str, Vector3],
    *,
    landmark_order: tuple[str, ...],
) -> tuple[SimilarityTransform3D, dict[str, float]]:
    if len(landmark_order) < 3:
        raise ValueError("similarity fit requires at least three landmarks")
    if len(set(landmark_order)) != len(landmark_order):
        raise ValueError("similarity fit landmarks must be unique")

    missing_source = [
        name
        for name in landmark_order
        if name not in source_points
    ]
    missing_target = [
        name
        for name in landmark_order
        if name not in target_points
    ]
    if missing_source:
        raise ValueError(
            "source pose is missing registration landmarks: "
            + ", ".join(missing_source)
        )
    if missing_target:
        raise ValueError(
            "target profile is missing registration landmarks: "
            + ", ".join(missing_target)
        )

    source = [source_points[name] for name in landmark_order]
    target = [target_points[name] for name in landmark_order]
    for index, point in enumerate(source):
        _validate_vector(point, label=f"source point {index}")
    for index, point in enumerate(target):
        _validate_vector(point, label=f"target point {index}")

    if _is_degenerate(source):
        raise ValueError(
            "source registration landmarks are collinear or degenerate"
        )
    if _is_degenerate(target):
        raise ValueError(
            "target registration landmarks are collinear or degenerate"
        )

    source_center = _centroid(source)
    target_center = _centroid(target)
    source_centered = [
        _subtract(point, source_center)
        for point in source
    ]
    target_centered = [
        _subtract(point, target_center)
        for point in target
    ]

    cross = [[0.0] * 3 for _ in range(3)]
    for source_point, target_point in zip(
        source_centered,
        target_centered,
    ):
        for row in range(3):
            for column in range(3):
                # Horn's Davenport matrix below uses source-by-target
                # cross-dispersion and returns the rotation mapping
                # source -> target.
                cross[row][column] += (
                    source_point[row] * target_point[column]
                )

    rotation = _horn_rotation(cross)

    denominator = sum(
        _dot(point, point)
        for point in source_centered
    )
    if denominator <= 1e-18:
        raise ValueError("source registration landmarks have zero variance")

    numerator = 0.0
    for source_point, target_point in zip(
        source_centered,
        target_centered,
    ):
        numerator += _dot(
            target_point,
            _matvec(rotation, source_point),
        )
    scale = numerator / denominator
    if not math.isfinite(scale) or scale <= 0:
        raise ValueError(
            "similarity fit produced a non-positive scale"
        )

    rotated_center = _matvec(rotation, source_center)
    translation = (
        target_center[0] - scale * rotated_center[0],
        target_center[1] - scale * rotated_center[1],
        target_center[2] - scale * rotated_center[2],
    )
    transform = SimilarityTransform3D(
        scale=scale,
        rotation=rotation,
        translation_m=translation,
    )

    residuals = {
        name: _distance(
            transform.apply(source_points[name]),
            target_points[name],
        )
        for name in landmark_order
    }
    return transform, residuals


def register_vision_pose(
    event: SensorEvent,
    profile: BodyModelProfile,
) -> RegisteredPose:
    if event.stream != "/camera/pose3d":
        raise ValueError(
            "pose registration requires a /camera/pose3d event"
        )
    if (
        event.payload.get("joint_coordinate_frame")
        != "vision_root_joint_relative_meters"
    ):
        raise ValueError(
            "pose registration requires Vision root-relative metric joints"
        )

    raw_joints = event.payload.get("joints_root_relative_m")
    if not isinstance(raw_joints, dict):
        raise TypeError(
            "pose event joints_root_relative_m must be an object"
        )
    vision_joints = {
        str(name): _vector3(value, label=f"Vision joint {name!r}")
        for name, value in raw_joints.items()
    }

    transform, residuals = fit_similarity_transform(
        vision_joints,
        profile.landmarks_m,
        landmark_order=profile.registration_landmarks,
    )
    registered = {
        name: transform.apply(point)
        for name, point in vision_joints.items()
    }

    values = list(residuals.values())
    rms = math.sqrt(
        sum(value * value for value in values) / len(values)
    )
    receipt = PoseRegistrationReceipt(
        profile_id=profile.model_id,
        profile_sha256=profile.profile_sha256,
        source_pose_sequence=event.sequence,
        source_pose_time_ns=event.device_time_ns,
        landmarks_used=profile.registration_landmarks,
        transform=transform,
        residual_rms_m=rms,
        residual_max_m=max(values),
        residuals_m=residuals,
    )
    return RegisteredPose(
        joints_body_model_m=registered,
        receipt=receipt,
    )


def _vector3(value: object, *, label: str) -> Vector3:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"{label} must contain exactly three values")
    try:
        point = (
            float(value[0]),
            float(value[1]),
            float(value[2]),
        )
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    _validate_vector(point, label=label)
    return point


def _validate_vector(point: Vector3, *, label: str) -> None:
    if len(point) != 3 or not all(
        math.isfinite(value)
        for value in point
    ):
        raise ValueError(f"{label} must be a finite 3D point")


def _centroid(points: list[Vector3]) -> Vector3:
    count = float(len(points))
    return (
        sum(point[0] for point in points) / count,
        sum(point[1] for point in points) / count,
        sum(point[2] for point in points) / count,
    )


def _subtract(left: Vector3, right: Vector3) -> Vector3:
    return (
        left[0] - right[0],
        left[1] - right[1],
        left[2] - right[2],
    )


def _dot(left: Vector3, right: Vector3) -> float:
    return (
        left[0] * right[0]
        + left[1] * right[1]
        + left[2] * right[2]
    )


def _cross(left: Vector3, right: Vector3) -> Vector3:
    return (
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    )


def _norm(point: Vector3) -> float:
    return math.sqrt(_dot(point, point))


def _distance(left: Vector3, right: Vector3) -> float:
    return _norm(_subtract(left, right))


def _is_degenerate(points: list[Vector3]) -> bool:
    origin = points[0]
    vectors = [
        _subtract(point, origin)
        for point in points[1:]
    ]
    longest = max((_norm(vector) for vector in vectors), default=0.0)
    if longest <= 1e-9:
        return True

    for first_index in range(len(vectors)):
        for second_index in range(first_index + 1, len(vectors)):
            area = _norm(
                _cross(
                    vectors[first_index],
                    vectors[second_index],
                )
            )
            if area > 1e-8 * longest * longest:
                return False
    return True


def _matvec(matrix: Matrix3, point: Vector3) -> Vector3:
    return (
        _dot(matrix[0], point),
        _dot(matrix[1], point),
        _dot(matrix[2], point),
    )


def _horn_rotation(
    cross: list[list[float]],
) -> Matrix3:
    sxx, sxy, sxz = cross[0]
    syx, syy, syz = cross[1]
    szx, szy, szz = cross[2]

    trace = sxx + syy + szz
    matrix = (
        (
            trace,
            syz - szy,
            szx - sxz,
            sxy - syx,
        ),
        (
            syz - szy,
            sxx - syy - szz,
            sxy + syx,
            szx + sxz,
        ),
        (
            szx - sxz,
            sxy + syx,
            -sxx + syy - szz,
            syz + szy,
        ),
        (
            sxy - syx,
            szx + sxz,
            syz + szy,
            -sxx - syy + szz,
        ),
    )

    # Plain power iteration converges to the eigenvector whose
    # eigenvalue has the largest magnitude. Horn's method needs the
    # largest *algebraic* eigenvalue, which may not have the largest
    # magnitude when a negative eigenvalue dominates. Shift the
    # symmetric matrix by a strict spectral bound times identity.
    # This preserves eigenvectors and eigenvalue ordering while making
    # every shifted eigenvalue positive.
    spectral_bound = max(
        sum(abs(value) for value in row)
        for row in matrix
    )
    shift = spectral_bound + 1.0
    shifted = tuple(
        tuple(
            value + (shift if row == column else 0.0)
            for column, value in enumerate(matrix[row])
        )
        for row in range(4)
    )

    quaternion = (1.0, 0.0, 0.0, 0.0)
    for _ in range(120):
        candidate = tuple(
            sum(
                shifted[row][column] * quaternion[column]
                for column in range(4)
            )
            for row in range(4)
        )
        length = math.sqrt(sum(value * value for value in candidate))
        if length <= 1e-18:
            raise ValueError("rotation fit is degenerate")
        candidate = tuple(value / length for value in candidate)

        # q and -q represent the same rotation. Keep the sign
        # continuous so convergence is not hidden by a sign flip.
        if sum(
            candidate[index] * quaternion[index]
            for index in range(4)
        ) < 0:
            candidate = tuple(-value for value in candidate)

        if sum(
            (candidate[index] - quaternion[index]) ** 2
            for index in range(4)
        ) <= 1e-24:
            quaternion = candidate
            break
        quaternion = candidate

    w, x, y, z = quaternion
    rotation: Matrix3 = (
        (
            1 - 2 * (y * y + z * z),
            2 * (x * y - z * w),
            2 * (x * z + y * w),
        ),
        (
            2 * (x * y + z * w),
            1 - 2 * (x * x + z * z),
            2 * (y * z - x * w),
        ),
        (
            2 * (x * z - y * w),
            2 * (y * z + x * w),
            1 - 2 * (x * x + y * y),
        ),
    )

    determinant = (
        rotation[0][0]
        * (
            rotation[1][1] * rotation[2][2]
            - rotation[1][2] * rotation[2][1]
        )
        - rotation[0][1]
        * (
            rotation[1][0] * rotation[2][2]
            - rotation[1][2] * rotation[2][0]
        )
        + rotation[0][2]
        * (
            rotation[1][0] * rotation[2][1]
            - rotation[1][1] * rotation[2][0]
        )
    )
    if determinant < 0.999 or determinant > 1.001:
        raise ValueError(
            "rotation fit did not produce a proper 3D rotation"
        )
    return rotation
