from __future__ import annotations

import json
import math
import statistics
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path

from .clock_uncertainty import CLOCK_UNCERTAINTY_SCHEMA_VERSION
from .provenance import session_evidence_sha256, sha256_file
from .session import SessionReader

CALIBRATION_BOARD_SCHEMA_VERSION = "motionos.calibration-board.v1"
WORLD_FRAME_SCHEMA_VERSION = "motionos.world-frame.v1"
CAMERA_CALIBRATION_SCHEMA_VERSION = "motionos.camera-calibration.v1"
CAMERA_CALIBRATION_RECEIPT_SCHEMA_VERSION = (
    "motionos.camera-calibration-receipt.v1"
)
CAMERA_MOUNT_VERIFICATION_SCHEMA_VERSION = (
    "motionos.camera-mount-verification.v1"
)
CAMERA_RIG_SPEC_SCHEMA_VERSION = "motionos.camera-rig-spec.v1"
CAMERA_RIG_RECEIPT_SCHEMA_VERSION = "motionos.camera-rig-receipt.v1"
MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION = (
    "motionos.multiview-correspondences.v1"
)
MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION = (
    "motionos.multiview-geometry-report.v1"
)
GEOMETRY_MEASUREMENTS_SCHEMA_VERSION = "motionos.geometry-measurements.v1"

CAMERA_FRAME_CONVENTION = "+X right,+Y down,+Z forward"
SUPPORTED_DISTORTION_MODELS = {
    "none": 0,
    "brown_conrady_5": 5,
    "opencv_rational_8": 8,
    "fisheye_4": 4,
}


Vector3 = tuple[float, float, float]
Matrix3 = tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]
Matrix4 = tuple[
    tuple[float, float, float, float],
    tuple[float, float, float, float],
    tuple[float, float, float, float],
    tuple[float, float, float, float],
]


@dataclass(frozen=True)
class ArtifactReference:
    path: Path
    sha256: str


@dataclass(frozen=True)
class CalibrationBoard:
    board_id: str
    board_type: str
    squares_x: int
    squares_y: int
    square_length_m: float
    marker_length_m: float
    dictionary: str
    printable_source_sha256: str | None
    artifact_sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": CALIBRATION_BOARD_SCHEMA_VERSION,
            "board_id": self.board_id,
            "board_type": self.board_type,
            "squares_x": self.squares_x,
            "squares_y": self.squares_y,
            "square_length_m": self.square_length_m,
            "marker_length_m": self.marker_length_m,
            "dictionary": self.dictionary,
            "printable_source_sha256": self.printable_source_sha256,
            "artifact_sha256": self.artifact_sha256,
        }


@dataclass(frozen=True)
class WorldFrame:
    frame_id: str
    units: str
    x_axis: str
    y_axis: str
    z_axis: str
    origin_description: str
    gravity_direction: Vector3
    calibration_board_sha256: str
    artifact_sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": WORLD_FRAME_SCHEMA_VERSION,
            "frame_id": self.frame_id,
            "units": self.units,
            "axes": {
                "x": self.x_axis,
                "y": self.y_axis,
                "z": self.z_axis,
            },
            "origin_description": self.origin_description,
            "gravity_direction": list(self.gravity_direction),
            "calibration_board_sha256": self.calibration_board_sha256,
            "artifact_sha256": self.artifact_sha256,
        }


@dataclass(frozen=True)
class CameraCalibration:
    calibration_id: str
    camera_id: str
    camera_frame_convention: str
    image_width_px: int
    image_height_px: int
    intrinsics: Matrix3
    distortion_model: str
    distortion_coefficients: tuple[float, ...]
    world_from_camera: Matrix4
    world_frame: WorldFrame
    world_frame_sha256: str
    board: CalibrationBoard
    board_sha256: str
    reprojection_rms_px: float
    reprojection_max_px: float
    observation_count: int
    source_evidence_sha256: dict[str, str]
    source_timestamp_basis: str
    device_model: str
    device_type: str
    camera_position: str
    pixel_format: str
    max_reprojection_rms_px: float
    max_reprojection_max_px: float
    quality_passed: bool
    software_name: str
    software_version: str
    frozen_before_rig_capture: bool
    artifact_sha256: str

    @property
    def camera_center_world_m(self) -> Vector3:
        return (
            self.world_from_camera[0][3],
            self.world_from_camera[1][3],
            self.world_from_camera[2][3],
        )

    @property
    def optical_axis_world(self) -> Vector3:
        return _unit(
            (
                self.world_from_camera[0][2],
                self.world_from_camera[1][2],
                self.world_from_camera[2][2],
            ),
            label="camera optical axis",
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": CAMERA_CALIBRATION_SCHEMA_VERSION,
            "calibration_id": self.calibration_id,
            "camera_id": self.camera_id,
            "camera_frame_convention": self.camera_frame_convention,
            "image_size_px": [
                self.image_width_px,
                self.image_height_px,
            ],
            "intrinsics": [list(row) for row in self.intrinsics],
            "distortion": {
                "model": self.distortion_model,
                "coefficients": list(self.distortion_coefficients),
            },
            "world_from_camera": [
                list(row) for row in self.world_from_camera
            ],
            "world_frame": self.world_frame.to_dict(),
            "world_frame_sha256": self.world_frame_sha256,
            "calibration_board": self.board.to_dict(),
            "calibration_board_sha256": self.board_sha256,
            "reprojection": {
                "rms_px": self.reprojection_rms_px,
                "max_px": self.reprojection_max_px,
                "observation_count": self.observation_count,
            },
            "source_evidence_sha256": dict(
                sorted(self.source_evidence_sha256.items())
            ),
            "source_timestamp_basis": self.source_timestamp_basis,
            "camera_identity": {
                "device_model": self.device_model,
                "camera_unique_id": self.camera_id,
                "device_type": self.device_type,
                "position": self.camera_position,
                "format_width": self.image_width_px,
                "format_height": self.image_height_px,
                "pixel_format": self.pixel_format,
            },
            "acceptance": {
                "max_reprojection_rms_px": self.max_reprojection_rms_px,
                "max_reprojection_max_px": self.max_reprojection_max_px,
                "thresholds_frozen_before_review": True,
                "passed": self.quality_passed,
            },
            "software": {
                "name": self.software_name,
                "version": self.software_version,
            },
            "frozen_before_rig_capture": self.frozen_before_rig_capture,
            "artifact_sha256": self.artifact_sha256,
        }


@dataclass(frozen=True)
class RigCamera:
    camera_id: str
    session_id: str
    session_bundle_sha256: str
    calibration: CameraCalibration
    calibration_sha256: str
    clock_uncertainty_sha256: str
    mount_verification_sha256: str
    mount_translation_drift_m: float
    mount_rotation_drift_deg: float

    def to_dict(self) -> dict[str, object]:
        return {
            "camera_id": self.camera_id,
            "session_id": self.session_id,
            "session_bundle_sha256": self.session_bundle_sha256,
            "calibration_sha256": self.calibration_sha256,
            "clock_uncertainty_sha256": self.clock_uncertainty_sha256,
            "mount_verification_sha256":
                self.mount_verification_sha256,
            "mount_translation_drift_m":
                self.mount_translation_drift_m,
            "mount_rotation_drift_deg": self.mount_rotation_drift_deg,
            "calibration": self.calibration.to_dict(),
        }


def _text(value: object, *, label: str) -> str:
    result = str(value).strip()
    if not result:
        raise ValueError(f"{label} must be non-empty")
    return result


def _number(value: object, *, label: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not math.isfinite(result):
        raise ValueError(f"{label} must be finite")
    return result


def _positive(value: object, *, label: str) -> float:
    result = _number(value, label=label)
    if result <= 0:
        raise ValueError(f"{label} must be positive")
    return result


def _nonnegative(value: object, *, label: str) -> float:
    result = _number(value, label=label)
    if result < 0:
        raise ValueError(f"{label} must be non-negative")
    return result


def _hex_digest(value: object, *, label: str) -> str:
    digest = _text(value, label=label).lower()
    if len(digest) != 64 or any(
        char not in "0123456789abcdef" for char in digest
    ):
        raise ValueError(f"{label} must be a 64-character SHA-256 hex digest")
    return digest


def _resolve(raw: object, *, base: Path, label: str) -> Path:
    value = _text(raw, label=label)
    path = Path(value)
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def _json_object(path: Path, *, label: str) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{label} must contain a JSON object")
    return dict(raw)


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
    expected = _hex_digest(
        raw.get("sha256", ""),
        label=f"{label}.sha256",
    )
    actual = sha256_file(path)
    if actual != expected:
        raise ValueError(f"{label} hash mismatch")
    return ArtifactReference(path=path, sha256=actual)


def _session_reference(
    raw: object,
    *,
    base: Path,
    label: str,
) -> tuple[Path, SessionReader, str]:
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
    expected = _hex_digest(
        raw.get("bundle_sha256", ""),
        label=f"{label}.bundle_sha256",
    )
    if actual != expected:
        raise ValueError(f"{label} session bundle hash mismatch")
    return path, reader, actual


def _vector3(value: object, *, label: str) -> Vector3:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise ValueError(f"{label} must contain exactly three values")
    point = tuple(
        _number(item, label=f"{label}[{index}]")
        for index, item in enumerate(value)
    )
    return (point[0], point[1], point[2])


def _matrix3(value: object, *, label: str) -> Matrix3:
    if not isinstance(value, list) or len(value) != 3:
        raise ValueError(f"{label} must be a 3x3 matrix")
    rows = tuple(
        _vector3(row, label=f"{label}[{index}]")
        for index, row in enumerate(value)
    )
    return (rows[0], rows[1], rows[2])


def _matrix4(value: object, *, label: str) -> Matrix4:
    if not isinstance(value, list) or len(value) != 4:
        raise ValueError(f"{label} must be a 4x4 matrix")
    rows: list[tuple[float, float, float, float]] = []
    for row_index, row in enumerate(value):
        if not isinstance(row, (list, tuple)) or len(row) != 4:
            raise ValueError(f"{label}[{row_index}] must contain four values")
        parsed = tuple(
            _number(item, label=f"{label}[{row_index}][{column}]")
            for column, item in enumerate(row)
        )
        rows.append((parsed[0], parsed[1], parsed[2], parsed[3]))
    return (rows[0], rows[1], rows[2], rows[3])


def _dot(left: Vector3, right: Vector3) -> float:
    return sum(left[index] * right[index] for index in range(3))


def _subtract(left: Vector3, right: Vector3) -> Vector3:
    return (
        left[0] - right[0],
        left[1] - right[1],
        left[2] - right[2],
    )


def _add(left: Vector3, right: Vector3) -> Vector3:
    return (
        left[0] + right[0],
        left[1] + right[1],
        left[2] + right[2],
    )


def _scale(value: Vector3, factor: float) -> Vector3:
    return (
        value[0] * factor,
        value[1] * factor,
        value[2] * factor,
    )


def _norm(value: Vector3) -> float:
    return math.sqrt(_dot(value, value))


def _unit(value: Vector3, *, label: str) -> Vector3:
    magnitude = _norm(value)
    if magnitude <= 1e-12:
        raise ValueError(f"{label} has zero length")
    return _scale(value, 1.0 / magnitude)


def _cross(left: Vector3, right: Vector3) -> Vector3:
    return (
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    )


def _matvec(matrix: Matrix3, value: Vector3) -> Vector3:
    return (
        _dot(matrix[0], value),
        _dot(matrix[1], value),
        _dot(matrix[2], value),
    )


def _transpose(matrix: Matrix3) -> Matrix3:
    return (
        (matrix[0][0], matrix[1][0], matrix[2][0]),
        (matrix[0][1], matrix[1][1], matrix[2][1]),
        (matrix[0][2], matrix[1][2], matrix[2][2]),
    )


def _rotation(matrix: Matrix4) -> Matrix3:
    return (
        (matrix[0][0], matrix[0][1], matrix[0][2]),
        (matrix[1][0], matrix[1][1], matrix[1][2]),
        (matrix[2][0], matrix[2][1], matrix[2][2]),
    )


def _translation(matrix: Matrix4) -> Vector3:
    return (matrix[0][3], matrix[1][3], matrix[2][3])


def _validate_rotation(matrix: Matrix3, *, label: str) -> None:
    for index, row in enumerate(matrix):
        if abs(_norm(row) - 1.0) > 1e-4:
            raise ValueError(f"{label} row {index} is not unit length")
    for left, right in combinations(range(3), 2):
        if abs(_dot(matrix[left], matrix[right])) > 1e-4:
            raise ValueError(f"{label} rows are not orthogonal")
    determinant = _dot(matrix[0], _cross(matrix[1], matrix[2]))
    if abs(determinant - 1.0) > 1e-4:
        raise ValueError(f"{label} determinant must be +1")


def _validate_rigid_transform(matrix: Matrix4, *, label: str) -> None:
    if any(
        abs(matrix[3][index] - expected) > 1e-9
        for index, expected in enumerate((0.0, 0.0, 0.0, 1.0))
    ):
        raise ValueError(f"{label} must end with homogeneous row [0,0,0,1]")
    _validate_rotation(_rotation(matrix), label=f"{label}.rotation")


def _angle_deg(left: Vector3, right: Vector3) -> float:
    a = _unit(left, label="left direction")
    b = _unit(right, label="right direction")
    cosine = max(-1.0, min(1.0, _dot(a, b)))
    return math.degrees(math.acos(cosine))


def _rotation_difference_deg(left: Matrix3, right: Matrix3) -> float:
    relative = tuple(
        tuple(
            sum(left[k][i] * right[k][j] for k in range(3))
            for j in range(3)
        )
        for i in range(3)
    )
    trace = relative[0][0] + relative[1][1] + relative[2][2]
    cosine = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    return math.degrees(math.acos(cosine))


def load_calibration_board(path: str | Path) -> CalibrationBoard:
    source = Path(path).resolve()
    raw = _json_object(source, label="calibration board")
    if raw.get("schema_version") != CALIBRATION_BOARD_SCHEMA_VERSION:
        raise ValueError("unsupported calibration-board schema")
    board_id = _text(raw.get("board_id", ""), label="board_id")
    board_type = _text(raw.get("board_type", ""), label="board_type")
    if board_type != "charuco":
        raise ValueError("initial calibration-board type must be charuco")
    squares_x = int(raw.get("squares_x", 0))
    squares_y = int(raw.get("squares_y", 0))
    if squares_x < 2 or squares_y < 2:
        raise ValueError("ChArUco board requires at least 2x2 squares")
    square_length = _positive(
        raw.get("square_length_m"),
        label="square_length_m",
    )
    marker_length = _positive(
        raw.get("marker_length_m"),
        label="marker_length_m",
    )
    if marker_length >= square_length:
        raise ValueError("marker_length_m must be smaller than square_length_m")
    dictionary = _text(raw.get("dictionary", ""), label="dictionary")
    printable = raw.get("printable_source_sha256")
    printable_hash = (
        _hex_digest(printable, label="printable_source_sha256")
        if printable is not None
        else None
    )
    return CalibrationBoard(
        board_id=board_id,
        board_type=board_type,
        squares_x=squares_x,
        squares_y=squares_y,
        square_length_m=square_length,
        marker_length_m=marker_length,
        dictionary=dictionary,
        printable_source_sha256=printable_hash,
        artifact_sha256=sha256_file(source),
    )


def load_world_frame(
    path: str | Path,
    *,
    board: CalibrationBoard | None = None,
) -> WorldFrame:
    source = Path(path).resolve()
    raw = _json_object(source, label="world frame")
    if raw.get("schema_version") != WORLD_FRAME_SCHEMA_VERSION:
        raise ValueError("unsupported world-frame schema")
    if raw.get("units") != "m":
        raise ValueError("world-frame units must be meters")
    axes = raw.get("axes")
    if not isinstance(axes, dict):
        raise TypeError("world-frame axes must be an object")
    gravity = _unit(
        _vector3(
            raw.get("gravity_direction"),
            label="gravity_direction",
        ),
        label="gravity_direction",
    )
    board_hash = _hex_digest(
        raw.get("calibration_board_sha256", ""),
        label="calibration_board_sha256",
    )
    if board is not None and board_hash != board.artifact_sha256:
        raise ValueError("world frame calibration-board hash mismatch")
    return WorldFrame(
        frame_id=_text(raw.get("frame_id", ""), label="frame_id"),
        units="m",
        x_axis=_text(axes.get("x", ""), label="axes.x"),
        y_axis=_text(axes.get("y", ""), label="axes.y"),
        z_axis=_text(axes.get("z", ""), label="axes.z"),
        origin_description=_text(
            raw.get("origin_description", ""),
            label="origin_description",
        ),
        gravity_direction=gravity,
        calibration_board_sha256=board_hash,
        artifact_sha256=sha256_file(source),
    )


def _source_evidence(
    raw: object,
    *,
    base: Path,
) -> dict[str, str]:
    if not isinstance(raw, list) or not raw:
        raise ValueError("source_evidence must be a non-empty list")
    result: dict[str, str] = {}
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise TypeError(f"source_evidence[{index}] must be an object")
        role = _text(
            item.get("role", ""),
            label=f"source_evidence[{index}].role",
        )
        if role in result:
            raise ValueError(f"source evidence roles must be unique: {role}")
        artifact = _artifact_reference(
            item,
            base=base,
            label=f"source_evidence[{index}]",
        )
        result[role] = artifact.sha256
    return result


def load_camera_calibration(path: str | Path) -> CameraCalibration:
    source = Path(path).resolve()
    raw = _json_object(source, label="camera calibration")
    if raw.get("schema_version") != CAMERA_CALIBRATION_SCHEMA_VERSION:
        raise ValueError("unsupported camera-calibration schema")

    board_ref = _artifact_reference(
        raw.get("calibration_board"),
        base=source.parent,
        label="calibration_board",
    )
    board = load_calibration_board(board_ref.path)
    if board.artifact_sha256 != board_ref.sha256:
        raise ValueError("calibration board artifact hash mismatch")

    world_ref = _artifact_reference(
        raw.get("world_frame"),
        base=source.parent,
        label="world_frame",
    )
    world = load_world_frame(world_ref.path, board=board)
    if world.artifact_sha256 != world_ref.sha256:
        raise ValueError("world frame artifact hash mismatch")

    image_size = raw.get("image_size_px")
    if (
        not isinstance(image_size, list)
        or len(image_size) != 2
        or int(image_size[0]) <= 0
        or int(image_size[1]) <= 0
    ):
        raise ValueError("image_size_px must contain positive width/height")

    intrinsics = _matrix3(raw.get("intrinsics"), label="intrinsics")
    if intrinsics[0][0] <= 0 or intrinsics[1][1] <= 0:
        raise ValueError("camera focal lengths must be positive")
    if (
        abs(intrinsics[2][0]) > 1e-9
        or abs(intrinsics[2][1]) > 1e-9
        or abs(intrinsics[2][2] - 1.0) > 1e-9
    ):
        raise ValueError("intrinsics last row must be [0,0,1]")

    distortion = raw.get("distortion")
    if not isinstance(distortion, dict):
        raise TypeError("camera distortion must be an object")
    model = _text(distortion.get("model", ""), label="distortion.model")
    if model not in SUPPORTED_DISTORTION_MODELS:
        raise ValueError(f"unsupported distortion model: {model}")
    coefficients_raw = distortion.get("coefficients")
    if not isinstance(coefficients_raw, list):
        raise TypeError("distortion coefficients must be a list")
    coefficients = tuple(
        _number(value, label=f"distortion.coefficients[{index}]")
        for index, value in enumerate(coefficients_raw)
    )
    if len(coefficients) != SUPPORTED_DISTORTION_MODELS[model]:
        raise ValueError(
            f"distortion model {model} requires "
            f"{SUPPORTED_DISTORTION_MODELS[model]} coefficients"
        )

    transform = _matrix4(
        raw.get("world_from_camera"),
        label="world_from_camera",
    )
    _validate_rigid_transform(transform, label="world_from_camera")

    reprojection = raw.get("reprojection")
    if not isinstance(reprojection, dict):
        raise TypeError("camera reprojection must be an object")
    rms = _nonnegative(
        reprojection.get("rms_px"),
        label="reprojection.rms_px",
    )
    maximum = _nonnegative(
        reprojection.get("max_px"),
        label="reprojection.max_px",
    )
    count = int(reprojection.get("observation_count", 0))
    if count <= 0:
        raise ValueError("reprojection observation_count must be positive")
    if maximum < rms:
        raise ValueError("reprojection max_px cannot be smaller than rms_px")

    software = raw.get("software")
    if not isinstance(software, dict):
        raise TypeError("camera calibration software must be an object")

    identity = raw.get("camera_identity")
    if not isinstance(identity, dict):
        raise TypeError("camera calibration camera_identity must be an object")
    camera_id = _text(
        identity.get("camera_unique_id", ""),
        label="camera_identity.camera_unique_id",
    )
    if camera_id != _text(raw.get("camera_id", ""), label="camera_id"):
        raise ValueError("camera_identity.camera_unique_id must equal camera_id")
    if int(identity.get("format_width", 0)) != int(image_size[0]) or int(
        identity.get("format_height", 0)
    ) != int(image_size[1]):
        raise ValueError(
            "camera_identity format dimensions must match image_size_px"
        )

    acceptance = raw.get("acceptance")
    if not isinstance(acceptance, dict):
        raise TypeError("camera calibration acceptance must be an object")
    if acceptance.get("thresholds_frozen_before_review") is not True:
        raise ValueError(
            "camera calibration acceptance thresholds must be frozen "
            "before review"
        )
    max_rms = _positive(
        acceptance.get("max_reprojection_rms_px"),
        label="acceptance.max_reprojection_rms_px",
    )
    max_max = _positive(
        acceptance.get("max_reprojection_max_px"),
        label="acceptance.max_reprojection_max_px",
    )
    quality_passed = rms <= max_rms and maximum <= max_max

    frame_convention = _text(
        raw.get("camera_frame_convention", ""),
        label="camera_frame_convention",
    )
    if frame_convention != CAMERA_FRAME_CONVENTION:
        raise ValueError(
            "camera calibration must use canonical pinhole convention "
            f"{CAMERA_FRAME_CONVENTION!r}"
        )
    frozen = raw.get("frozen_before_rig_capture")
    if frozen is not True:
        raise ValueError(
            "camera calibration must be frozen before rig capture"
        )

    return CameraCalibration(
        calibration_id=_text(
            raw.get("calibration_id", ""),
            label="calibration_id",
        ),
        camera_id=camera_id,
        camera_frame_convention=frame_convention,
        image_width_px=int(image_size[0]),
        image_height_px=int(image_size[1]),
        intrinsics=intrinsics,
        distortion_model=model,
        distortion_coefficients=coefficients,
        world_from_camera=transform,
        world_frame=world,
        world_frame_sha256=world_ref.sha256,
        board=board,
        board_sha256=board_ref.sha256,
        reprojection_rms_px=rms,
        reprojection_max_px=maximum,
        observation_count=count,
        source_evidence_sha256=_source_evidence(
            raw.get("source_evidence"),
            base=source.parent,
        ),
        source_timestamp_basis=_text(
            raw.get("source_timestamp_basis", ""),
            label="source_timestamp_basis",
        ),
        device_model=_text(
            identity.get("device_model", ""),
            label="camera_identity.device_model",
        ),
        device_type=_text(
            identity.get("device_type", ""),
            label="camera_identity.device_type",
        ),
        camera_position=_text(
            identity.get("position", ""),
            label="camera_identity.position",
        ),
        pixel_format=_text(
            identity.get("pixel_format", ""),
            label="camera_identity.pixel_format",
        ),
        max_reprojection_rms_px=max_rms,
        max_reprojection_max_px=max_max,
        quality_passed=quality_passed,
        software_name=_text(
            software.get("name", ""),
            label="software.name",
        ),
        software_version=_text(
            software.get("version", ""),
            label="software.version",
        ),
        frozen_before_rig_capture=True,
        artifact_sha256=sha256_file(source),
    )


def write_camera_calibration_receipt(
    calibration_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    calibration = load_camera_calibration(calibration_path)
    receipt = {
        "schema_version": CAMERA_CALIBRATION_RECEIPT_SCHEMA_VERSION,
        "passed": calibration.quality_passed,
        "calibration_sha256": calibration.artifact_sha256,
        "calibration": calibration.to_dict(),
        "claim_boundary": (
            "A passing calibration receipt validates the declared metric "
            "camera model, provenance, coordinate contract, and predeclared "
            "reprojection thresholds. It does not "
            "prove the camera stayed fixed after calibration."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def _mount_verification(
    raw: object,
    *,
    base: Path,
    calibration: CameraCalibration,
    session_id: str,
) -> tuple[str, float, float]:
    artifact = _artifact_reference(
        raw,
        base=base,
        label=f"{calibration.camera_id}.mount_verification",
    )
    data = _json_object(artifact.path, label="camera mount verification")
    if data.get("schema_version") != CAMERA_MOUNT_VERIFICATION_SCHEMA_VERSION:
        raise ValueError("unsupported camera-mount-verification schema")
    if str(data.get("camera_id", "")) != calibration.camera_id:
        raise ValueError("mount verification camera_id mismatch")
    if str(data.get("session_id", "")) != session_id:
        raise ValueError("mount verification session_id mismatch")
    if str(data.get("calibration_sha256", "")) != (
        calibration.artifact_sha256
    ):
        raise ValueError("mount verification calibration hash mismatch")

    observed = _matrix4(
        data.get("observed_world_from_camera"),
        label="observed_world_from_camera",
    )
    _validate_rigid_transform(
        observed,
        label="observed_world_from_camera",
    )
    source_raw = data.get("source_evidence")
    _source_evidence(source_raw, base=artifact.path.parent)

    translation_drift = _norm(
        _subtract(
            _translation(observed),
            calibration.camera_center_world_m,
        )
    )
    rotation_drift = _rotation_difference_deg(
        _rotation(calibration.world_from_camera),
        _rotation(observed),
    )
    return artifact.sha256, translation_drift, rotation_drift


def _clock_mapping(
    raw: object,
    *,
    base: Path,
    reference_reader: SessionReader,
    reference_bundle_sha256: str,
    camera_reader: SessionReader,
    camera_bundle_sha256: str,
    camera_id: str,
) -> str:
    artifact = _artifact_reference(
        raw,
        base=base,
        label=f"{camera_id}.clock_uncertainty",
    )
    data = _json_object(artifact.path, label="clock uncertainty")
    if data.get("schema_version") != CLOCK_UNCERTAINTY_SCHEMA_VERSION:
        raise ValueError("unsupported clock uncertainty schema")
    reference = data.get("reference")
    target = data.get("target")
    if not isinstance(reference, dict) or not isinstance(target, dict):
        raise TypeError("clock uncertainty requires reference and target")
    if str(reference.get("session_id", "")) != (
        reference_reader.manifest.session_id
    ):
        raise ValueError(f"{camera_id} clock reference session mismatch")
    if str(reference.get("bundle_sha256", "")) != reference_bundle_sha256:
        raise ValueError(f"{camera_id} clock reference bundle mismatch")
    if str(target.get("session_id", "")) != (
        camera_reader.manifest.session_id
    ):
        raise ValueError(f"{camera_id} clock target session mismatch")
    if str(target.get("bundle_sha256", "")) != camera_bundle_sha256:
        raise ValueError(f"{camera_id} clock target bundle mismatch")
    return artifact.sha256


def build_camera_rig_receipt(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    spec_file = Path(spec_path).resolve()
    raw = _json_object(spec_file, label="camera rig spec")
    if raw.get("schema_version") != CAMERA_RIG_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported camera-rig spec schema")
    if raw.get("thresholds_frozen_before_review") is not True:
        raise ValueError("camera-rig thresholds must be frozen before review")

    min_baseline = _positive(
        raw.get("min_pairwise_baseline_m"),
        label="min_pairwise_baseline_m",
    )
    min_view_angle = _positive(
        raw.get("min_pairwise_view_angle_deg"),
        label="min_pairwise_view_angle_deg",
    )
    max_translation_drift = _nonnegative(
        raw.get("max_mount_translation_drift_m"),
        label="max_mount_translation_drift_m",
    )
    max_rotation_drift = _nonnegative(
        raw.get("max_mount_rotation_drift_deg"),
        label="max_mount_rotation_drift_deg",
    )

    _ref_path, reference_reader, reference_bundle = _session_reference(
        raw.get("reference_session"),
        base=spec_file.parent,
        label="reference_session",
    )

    cameras_raw = raw.get("cameras")
    if not isinstance(cameras_raw, list) or len(cameras_raw) < 2:
        raise ValueError("camera rig requires at least two cameras")

    cameras: list[RigCamera] = []
    calibration_quality_passed = True
    world_hash: str | None = None
    board_hash: str | None = None
    camera_ids: set[str] = set()
    session_ids: set[str] = set()

    for index, item in enumerate(cameras_raw):
        if not isinstance(item, dict):
            raise TypeError(f"camera rig camera {index} must be an object")
        calibration_ref = _artifact_reference(
            item.get("calibration"),
            base=spec_file.parent,
            label=f"cameras[{index}].calibration",
        )
        calibration = load_camera_calibration(calibration_ref.path)
        if calibration.artifact_sha256 != calibration_ref.sha256:
            raise ValueError("camera calibration hash mismatch")
        calibration_quality_passed = (
            calibration_quality_passed
            and calibration.quality_passed
        )

        if calibration.camera_id in camera_ids:
            raise ValueError("camera rig camera IDs must be unique")
        camera_ids.add(calibration.camera_id)

        _path, camera_reader, camera_bundle = _session_reference(
            item.get("camera_session"),
            base=spec_file.parent,
            label=f"cameras[{index}].camera_session",
        )
        session_id = camera_reader.manifest.session_id
        if session_id in session_ids:
            raise ValueError("camera rig session IDs must be unique")
        session_ids.add(session_id)

        device_ids = {
            device.device_id
            for device in camera_reader.manifest.devices
        }
        if calibration.camera_id not in device_ids:
            raise ValueError(
                f"camera calibration ID {calibration.camera_id!r} "
                "is absent from camera session device IDs"
            )

        if world_hash is None:
            world_hash = calibration.world_frame_sha256
        elif calibration.world_frame_sha256 != world_hash:
            raise ValueError("camera rig world-frame hashes do not match")
        if board_hash is None:
            board_hash = calibration.board_sha256
        elif calibration.board_sha256 != board_hash:
            raise ValueError("camera rig calibration-board hashes do not match")

        clock_hash = _clock_mapping(
            item.get("clock_uncertainty"),
            base=spec_file.parent,
            reference_reader=reference_reader,
            reference_bundle_sha256=reference_bundle,
            camera_reader=camera_reader,
            camera_bundle_sha256=camera_bundle,
            camera_id=calibration.camera_id,
        )
        (
            mount_hash,
            translation_drift,
            rotation_drift,
        ) = _mount_verification(
            item.get("mount_verification"),
            base=spec_file.parent,
            calibration=calibration,
            session_id=session_id,
        )
        cameras.append(
            RigCamera(
                camera_id=calibration.camera_id,
                session_id=session_id,
                session_bundle_sha256=camera_bundle,
                calibration=calibration,
                calibration_sha256=calibration.artifact_sha256,
                clock_uncertainty_sha256=clock_hash,
                mount_verification_sha256=mount_hash,
                mount_translation_drift_m=translation_drift,
                mount_rotation_drift_deg=rotation_drift,
            )
        )

    pairwise_geometry: list[dict[str, object]] = []
    geometry_passed = True
    for left, right in combinations(cameras, 2):
        baseline = _norm(
            _subtract(
                left.calibration.camera_center_world_m,
                right.calibration.camera_center_world_m,
            )
        )
        view_angle = _angle_deg(
            left.calibration.optical_axis_world,
            right.calibration.optical_axis_world,
        )
        pair_passed = (
            baseline >= min_baseline
            and view_angle >= min_view_angle
        )
        geometry_passed = geometry_passed and pair_passed
        pairwise_geometry.append(
            {
                "camera_ids": [left.camera_id, right.camera_id],
                "baseline_m": baseline,
                "view_axis_angle_deg": view_angle,
                "passed": pair_passed,
            }
        )

    mount_passed = all(
        camera.mount_translation_drift_m <= max_translation_drift
        and camera.mount_rotation_drift_deg <= max_rotation_drift
        for camera in cameras
    )
    passed = (
        calibration_quality_passed
        and geometry_passed
        and mount_passed
    )

    receipt = {
        "schema_version": CAMERA_RIG_RECEIPT_SCHEMA_VERSION,
        "rig_id": _text(raw.get("rig_id", ""), label="rig_id"),
        "passed": passed,
        "spec_sha256": sha256_file(spec_file),
        "reference_session": {
            "session_id": reference_reader.manifest.session_id,
            "bundle_sha256": reference_bundle,
        },
        "world_frame_sha256": world_hash,
        "calibration_board_sha256": board_hash,
        "thresholds": {
            "min_pairwise_baseline_m": min_baseline,
            "min_pairwise_view_angle_deg": min_view_angle,
            "max_mount_translation_drift_m": max_translation_drift,
            "max_mount_rotation_drift_deg": max_rotation_drift,
            "frozen_before_review": True,
        },
        "gates": {
            "camera_calibration_quality_passed":
                calibration_quality_passed,
            "pairwise_geometry_passed": geometry_passed,
            "mount_stability_passed": mount_passed,
        },
        "pairwise_geometry": pairwise_geometry,
        "cameras": [camera.to_dict() for camera in cameras],
        "claim_boundary": (
            "passed=true validates a shared metric world-frame contract, "
            "camera/session/calibration provenance, per-camera time mapping, "
            "declared viewpoint separation, and capture-time mount stability. "
            "It is not a laboratory motion-capture accuracy claim."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def _camera_from_embedded(raw: dict[str, object]) -> CameraCalibration:
    world_raw = raw.get("world_frame")
    board_raw = raw.get("calibration_board")
    distortion = raw.get("distortion")
    reprojection = raw.get("reprojection")
    software = raw.get("software")
    if not isinstance(world_raw, dict):
        raise TypeError("embedded world_frame must be an object")
    if not isinstance(board_raw, dict):
        raise TypeError("embedded calibration_board must be an object")
    if not isinstance(distortion, dict):
        raise TypeError("embedded distortion must be an object")
    if not isinstance(reprojection, dict):
        raise TypeError("embedded reprojection must be an object")
    if not isinstance(software, dict):
        raise TypeError("embedded software must be an object")

    board = CalibrationBoard(
        board_id=str(board_raw["board_id"]),
        board_type=str(board_raw["board_type"]),
        squares_x=int(board_raw["squares_x"]),
        squares_y=int(board_raw["squares_y"]),
        square_length_m=float(board_raw["square_length_m"]),
        marker_length_m=float(board_raw["marker_length_m"]),
        dictionary=str(board_raw["dictionary"]),
        printable_source_sha256=(
            str(board_raw["printable_source_sha256"])
            if board_raw.get("printable_source_sha256") is not None
            else None
        ),
        artifact_sha256=str(board_raw["artifact_sha256"]),
    )
    world = WorldFrame(
        frame_id=str(world_raw["frame_id"]),
        units=str(world_raw["units"]),
        x_axis=str(world_raw["axes"]["x"]),
        y_axis=str(world_raw["axes"]["y"]),
        z_axis=str(world_raw["axes"]["z"]),
        origin_description=str(world_raw["origin_description"]),
        gravity_direction=_vector3(
            world_raw["gravity_direction"],
            label="embedded gravity_direction",
        ),
        calibration_board_sha256=str(
            world_raw["calibration_board_sha256"]
        ),
        artifact_sha256=str(world_raw["artifact_sha256"]),
    )
    image_size = raw["image_size_px"]
    if not isinstance(image_size, list) or len(image_size) != 2:
        raise ValueError("embedded image_size_px must contain two values")
    coefficients = distortion["coefficients"]
    if not isinstance(coefficients, list):
        raise TypeError("embedded distortion coefficients must be a list")

    return CameraCalibration(
        calibration_id=str(raw["calibration_id"]),
        camera_id=str(raw["camera_id"]),
        camera_frame_convention=str(raw["camera_frame_convention"]),
        image_width_px=int(image_size[0]),
        image_height_px=int(image_size[1]),
        intrinsics=_matrix3(raw["intrinsics"], label="embedded intrinsics"),
        distortion_model=str(distortion["model"]),
        distortion_coefficients=tuple(float(value) for value in coefficients),
        world_from_camera=_matrix4(
            raw["world_from_camera"],
            label="embedded world_from_camera",
        ),
        world_frame=world,
        world_frame_sha256=str(raw["world_frame_sha256"]),
        board=board,
        board_sha256=str(raw["calibration_board_sha256"]),
        reprojection_rms_px=float(reprojection["rms_px"]),
        reprojection_max_px=float(reprojection["max_px"]),
        observation_count=int(reprojection["observation_count"]),
        source_evidence_sha256={
            str(key): str(value)
            for key, value in raw.get("source_evidence_sha256", {}).items()
        },
        source_timestamp_basis=str(raw["source_timestamp_basis"]),
        device_model=str(raw["camera_identity"]["device_model"]),
        device_type=str(raw["camera_identity"]["device_type"]),
        camera_position=str(raw["camera_identity"]["position"]),
        pixel_format=str(raw["camera_identity"]["pixel_format"]),
        max_reprojection_rms_px=float(
            raw["acceptance"]["max_reprojection_rms_px"]
        ),
        max_reprojection_max_px=float(
            raw["acceptance"]["max_reprojection_max_px"]
        ),
        quality_passed=bool(raw["acceptance"]["passed"]),
        software_name=str(software["name"]),
        software_version=str(software["version"]),
        frozen_before_rig_capture=bool(raw["frozen_before_rig_capture"]),
        artifact_sha256=str(raw["artifact_sha256"]),
    )


def _undistort_normalized(
    xd: float,
    yd: float,
    *,
    model: str,
    coefficients: tuple[float, ...],
) -> tuple[float, float]:
    if model == "none":
        return xd, yd
    if model not in {"brown_conrady_5", "opencv_rational_8"}:
        raise ValueError(
            f"triangulation does not yet support distortion model {model!r}"
        )

    if model == "brown_conrady_5":
        k1, k2, p1, p2, k3 = coefficients
        k4 = k5 = k6 = 0.0
    else:
        k1, k2, p1, p2, k3, k4, k5, k6 = coefficients

    x = xd
    y = yd
    for _ in range(12):
        r2 = x * x + y * y
        r4 = r2 * r2
        r6 = r4 * r2
        numerator = 1.0 + k1 * r2 + k2 * r4 + k3 * r6
        denominator = 1.0 + k4 * r2 + k5 * r4 + k6 * r6
        if abs(denominator) <= 1e-12:
            raise ValueError("distortion inversion denominator is zero")
        radial = numerator / denominator
        if abs(radial) <= 1e-12:
            raise ValueError("distortion inversion radial scale is zero")
        tangential_x = (
            2.0 * p1 * x * y
            + p2 * (r2 + 2.0 * x * x)
        )
        tangential_y = (
            p1 * (r2 + 2.0 * y * y)
            + 2.0 * p2 * x * y
        )
        x = (xd - tangential_x) / radial
        y = (yd - tangential_y) / radial
    return x, y


def _distort_normalized(
    x: float,
    y: float,
    *,
    model: str,
    coefficients: tuple[float, ...],
) -> tuple[float, float]:
    if model == "none":
        return x, y
    if model not in {"brown_conrady_5", "opencv_rational_8"}:
        raise ValueError(
            f"reprojection does not yet support distortion model {model!r}"
        )
    if model == "brown_conrady_5":
        k1, k2, p1, p2, k3 = coefficients
        k4 = k5 = k6 = 0.0
    else:
        k1, k2, p1, p2, k3, k4, k5, k6 = coefficients

    r2 = x * x + y * y
    r4 = r2 * r2
    r6 = r4 * r2
    numerator = 1.0 + k1 * r2 + k2 * r4 + k3 * r6
    denominator = 1.0 + k4 * r2 + k5 * r4 + k6 * r6
    if abs(denominator) <= 1e-12:
        raise ValueError("distortion denominator is zero")
    radial = numerator / denominator
    tangential_x = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
    tangential_y = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
    return (
        x * radial + tangential_x,
        y * radial + tangential_y,
    )


def _pixel_to_world_ray(
    calibration: CameraCalibration,
    *,
    u_px: float,
    v_px: float,
) -> tuple[Vector3, Vector3]:
    k = calibration.intrinsics
    a = k[0][0]
    b = k[0][1]
    c = k[1][0]
    d = k[1][1]
    determinant = a * d - b * c
    if abs(determinant) <= 1e-12:
        raise ValueError("camera intrinsics upper-left 2x2 is singular")
    rhs_u = u_px - k[0][2]
    rhs_v = v_px - k[1][2]
    xd = (d * rhs_u - b * rhs_v) / determinant
    yd = (-c * rhs_u + a * rhs_v) / determinant
    x, y = _undistort_normalized(
        xd,
        yd,
        model=calibration.distortion_model,
        coefficients=calibration.distortion_coefficients,
    )
    direction_camera = _unit((x, y, 1.0), label="camera ray")
    direction_world = _unit(
        _matvec(_rotation(calibration.world_from_camera), direction_camera),
        label="world ray",
    )
    return calibration.camera_center_world_m, direction_world


def _solve_3x3(
    matrix: list[list[float]],
    vector: list[float],
) -> Vector3:
    augmented = [
        list(row) + [value]
        for row, value in zip(matrix, vector, strict=True)
    ]
    for pivot in range(3):
        swap = max(
            range(pivot, 3),
            key=lambda row: abs(augmented[row][pivot]),
        )
        if abs(augmented[swap][pivot]) <= 1e-12:
            raise ValueError("triangulation geometry is singular")
        augmented[pivot], augmented[swap] = (
            augmented[swap],
            augmented[pivot],
        )
        scale = augmented[pivot][pivot]
        augmented[pivot] = [
            value / scale for value in augmented[pivot]
        ]
        for row in range(3):
            if row == pivot:
                continue
            factor = augmented[row][pivot]
            augmented[row] = [
                value - factor * pivot_value
                for value, pivot_value in zip(
                    augmented[row],
                    augmented[pivot],
                    strict=True,
                )
            ]
    return (
        augmented[0][3],
        augmented[1][3],
        augmented[2][3],
    )


def _triangulate_rays(
    rays: list[tuple[Vector3, Vector3]],
) -> Vector3:
    if len(rays) < 2:
        raise ValueError("triangulation requires at least two camera rays")
    matrix = [[0.0] * 3 for _ in range(3)]
    vector = [0.0] * 3
    for origin, direction in rays:
        projection = [
            [
                (1.0 if row == column else 0.0)
                - direction[row] * direction[column]
                for column in range(3)
            ]
            for row in range(3)
        ]
        for row in range(3):
            for column in range(3):
                matrix[row][column] += projection[row][column]
            vector[row] += sum(
                projection[row][column] * origin[column]
                for column in range(3)
            )
    return _solve_3x3(matrix, vector)


def _ray_distance(
    point: Vector3,
    origin: Vector3,
    direction: Vector3,
) -> float:
    offset = _subtract(point, origin)
    projected = _scale(direction, _dot(offset, direction))
    return _norm(_subtract(offset, projected))


def _project_world_point(
    calibration: CameraCalibration,
    point_world: Vector3,
) -> tuple[float, float]:
    rotation_world_from_camera = _rotation(
        calibration.world_from_camera
    )
    rotation_camera_from_world = _transpose(
        rotation_world_from_camera
    )
    offset = _subtract(point_world, calibration.camera_center_world_m)
    point_camera = _matvec(rotation_camera_from_world, offset)
    if point_camera[2] <= 1e-9:
        raise ValueError(
            f"point projects behind camera {calibration.camera_id}"
        )
    x = point_camera[0] / point_camera[2]
    y = point_camera[1] / point_camera[2]
    xd, yd = _distort_normalized(
        x,
        y,
        model=calibration.distortion_model,
        coefficients=calibration.distortion_coefficients,
    )
    k = calibration.intrinsics
    return (
        k[0][0] * xd + k[0][1] * yd + k[0][2],
        k[1][0] * xd + k[1][1] * yd + k[1][2],
    )


def _distribution(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "rms": None,
            "p95": None,
            "max": None,
        }
    ordered = sorted(values)
    rank = min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1)
    return {
        "count": len(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "rms": math.sqrt(
            sum(value * value for value in values) / len(values)
        ),
        "p95": ordered[rank],
        "max": ordered[-1],
    }


def triangulate_multiview(
    rig_receipt_path: str | Path,
    correspondences_path: str | Path,
    output_path: str | Path,
    *,
    measurements_output_path: str | Path | None = None,
) -> dict[str, object]:
    rig_path = Path(rig_receipt_path).resolve()
    rig = _json_object(rig_path, label="camera rig receipt")
    if rig.get("schema_version") != CAMERA_RIG_RECEIPT_SCHEMA_VERSION:
        raise ValueError("unsupported camera-rig receipt schema")
    if rig.get("passed") is not True:
        raise ValueError(
            "multiview geometry requires a passing camera-rig receipt"
        )

    cameras_raw = rig.get("cameras")
    if not isinstance(cameras_raw, list) or len(cameras_raw) < 2:
        raise ValueError("camera-rig receipt requires at least two cameras")
    calibrations: dict[str, CameraCalibration] = {}
    for index, item in enumerate(cameras_raw):
        if not isinstance(item, dict):
            raise TypeError(f"rig camera {index} must be an object")
        calibration_raw = item.get("calibration")
        if not isinstance(calibration_raw, dict):
            raise TypeError(f"rig camera {index} calibration must be an object")
        calibration = _camera_from_embedded(calibration_raw)
        _validate_rigid_transform(
            calibration.world_from_camera,
            label=f"{calibration.camera_id}.world_from_camera",
        )
        calibrations[calibration.camera_id] = calibration

    correspondence_path = Path(correspondences_path).resolve()
    correspondence = _json_object(
        correspondence_path,
        label="multiview correspondences",
    )
    if (
        correspondence.get("schema_version")
        != MULTIVIEW_CORRESPONDENCES_SCHEMA_VERSION
    ):
        raise ValueError("unsupported multiview-correspondences schema")
    if str(correspondence.get("rig_id", "")) != str(rig.get("rig_id", "")):
        raise ValueError("multiview correspondences rig_id mismatch")
    if str(correspondence.get("rig_receipt_sha256", "")) != (
        sha256_file(rig_path)
    ):
        raise ValueError("multiview correspondences rig receipt hash mismatch")
    if correspondence.get("frozen_before_geometry_review") is not True:
        raise ValueError(
            "multiview correspondences must be frozen before geometry review"
        )

    points_raw = correspondence.get("points")
    if not isinstance(points_raw, list) or not points_raw:
        raise ValueError("multiview correspondences require points")

    points: list[dict[str, object]] = []
    reprojection_values: list[float] = []
    disagreement_values: list[float] = []
    geometry_measurements: list[dict[str, object]] = []

    for index, item in enumerate(points_raw):
        if not isinstance(item, dict):
            raise TypeError(f"multiview point {index} must be an object")
        point_id = _text(
            item.get("point_id", ""),
            label=f"points[{index}].point_id",
        )
        reference_time_ns = int(item["reference_time_ns"])
        observations_raw = item.get("observations")
        if not isinstance(observations_raw, dict):
            raise TypeError(
                f"points[{index}].observations must be an object"
            )

        rays: list[tuple[Vector3, Vector3]] = []
        parsed_observations: dict[str, tuple[float, float]] = {}
        for camera_id, observation in observations_raw.items():
            if camera_id not in calibrations:
                raise ValueError(
                    f"point {point_id} references unknown camera {camera_id}"
                )
            if not isinstance(observation, dict):
                raise TypeError(
                    f"point {point_id} observation {camera_id} "
                    "must be an object"
                )
            u_px = _number(
                observation.get("u_px"),
                label=f"{point_id}.{camera_id}.u_px",
            )
            v_px = _number(
                observation.get("v_px"),
                label=f"{point_id}.{camera_id}.v_px",
            )
            calibration = calibrations[camera_id]
            if not (
                0.0 <= u_px < calibration.image_width_px
                and 0.0 <= v_px < calibration.image_height_px
            ):
                raise ValueError(
                    f"point {point_id} observation {camera_id} "
                    "falls outside image bounds"
                )
            parsed_observations[str(camera_id)] = (u_px, v_px)
            rays.append(
                _pixel_to_world_ray(
                    calibration,
                    u_px=u_px,
                    v_px=v_px,
                )
            )
        if len(rays) < 2:
            raise ValueError(
                f"point {point_id} requires at least two camera observations"
            )

        point_world = _triangulate_rays(rays)
        ray_distances = [
            _ray_distance(point_world, origin, direction)
            for origin, direction in rays
        ]
        disagreement = math.sqrt(
            sum(value * value for value in ray_distances)
            / len(ray_distances)
        )
        disagreement_values.append(disagreement)

        residuals: dict[str, float] = {}
        for camera_id, (u_px, v_px) in parsed_observations.items():
            projected = _project_world_point(
                calibrations[camera_id],
                point_world,
            )
            residual = math.hypot(
                projected[0] - u_px,
                projected[1] - v_px,
            )
            residuals[camera_id] = residual
            reprojection_values.append(residual)

        mean_reprojection = statistics.mean(residuals.values())
        points.append(
            {
                "point_id": point_id,
                "reference_time_ns": reference_time_ns,
                "world_position_m": list(point_world),
                "camera_count": len(parsed_observations),
                "reprojection_residual_px": dict(sorted(residuals.items())),
                "mean_reprojection_residual_px": mean_reprojection,
                "ray_disagreement_rms_m": disagreement,
            }
        )
        geometry_measurements.extend(
            [
                {
                    "time_ns": reference_time_ns,
                    "metric": "camera_reprojection_residual_px",
                    "value": mean_reprojection,
                    "unit": "px",
                    "point_id": point_id,
                },
                {
                    "time_ns": reference_time_ns,
                    "metric":
                        "cross_view_triangulation_disagreement_m",
                    "value": disagreement,
                    "unit": "m",
                    "point_id": point_id,
                },
            ]
        )

    report = {
        "schema_version": MULTIVIEW_GEOMETRY_REPORT_SCHEMA_VERSION,
        "rig_id": rig["rig_id"],
        "rig_receipt_sha256": sha256_file(rig_path),
        "correspondences_sha256": sha256_file(correspondence_path),
        "world_frame_sha256": rig["world_frame_sha256"],
        "calibration_board_sha256": rig["calibration_board_sha256"],
        "point_count": len(points),
        "reprojection_residual_px": _distribution(reprojection_values),
        "ray_disagreement_rms_m": _distribution(disagreement_values),
        "points": points,
        "claim_boundary": (
            "Triangulation and reprojection quantify internal calibrated "
            "multi-view geometric consistency. They do not by themselves "
            "establish laboratory ground-truth accuracy."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if measurements_output_path is not None:
        measurements = {
            "schema_version": GEOMETRY_MEASUREMENTS_SCHEMA_VERSION,
            "source_multiview_geometry_report_sha256": sha256_file(output),
            "measurements": geometry_measurements,
        }
        measurement_output = Path(measurements_output_path)
        measurement_output.parent.mkdir(parents=True, exist_ok=True)
        measurement_output.write_text(
            json.dumps(measurements, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    return report
