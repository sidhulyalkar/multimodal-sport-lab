from __future__ import annotations

import glob
import hashlib
import json
import math
import os
from pathlib import Path
from typing import Any

from .world_geometry import load_calibration_board


CHARUCO_CALIBRATION_SPEC_SCHEMA_VERSION = (
    "motionos.charuco-calibration-spec.v1"
)


def calibrate_charuco_from_spec(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    cv2 = _cv2()
    source = Path(spec_path).resolve()
    spec = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(spec, dict):
        raise TypeError("ChArUco calibration spec must be an object")
    if spec.get("schema_version") != (
        CHARUCO_CALIBRATION_SPEC_SCHEMA_VERSION
    ):
        raise ValueError("unsupported ChArUco calibration spec schema")

    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    board_path = _resolve_path(source.parent, spec["calibration_board"])
    world_path = _resolve_path(source.parent, spec["world_frame"])
    board_contract = load_calibration_board(board_path)
    world_raw = _json_object(world_path)
    if world_raw.get("schema_version") != "motionos.world-frame.v1":
        raise ValueError("unsupported world frame schema")

    expected_board_hash = str(
        world_raw.get("calibration_board_sha256", "")
    )
    actual_board_hash = _sha256(board_path)
    if expected_board_hash != actual_board_hash:
        raise ValueError(
            "world frame does not reference the supplied calibration board"
        )

    image_paths = _image_paths(source.parent, spec)
    reference_image = _resolve_path(
        source.parent,
        spec["reference_image"],
    )
    if reference_image not in image_paths:
        raise ValueError(
            "reference_image must be one of the calibration images"
        )
    if len(image_paths) < 5:
        raise ValueError(
            "ChArUco calibration requires at least five images"
        )

    world_from_board = _matrix4(
        spec.get("world_from_board"),
        label="world_from_board",
    )
    _validate_rigid_transform(
        world_from_board,
        label="world_from_board",
    )

    dictionary = _aruco_dictionary(
        cv2,
        board_contract.dictionary,
    )
    charuco_board = _charuco_board(
        cv2,
        board_contract.squares_x,
        board_contract.squares_y,
        board_contract.square_length_m,
        board_contract.marker_length_m,
        dictionary,
    )

    all_corners: list[Any] = []
    all_ids: list[Any] = []
    accepted_paths: list[Path] = []
    image_size: tuple[int, int] | None = None

    for image_path in image_paths:
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError(
                f"unable to decode calibration image: {image_path}"
            )
        height, width = image.shape[:2]
        if image_size is None:
            image_size = (width, height)
        elif image_size != (width, height):
            raise ValueError(
                "all calibration images must have identical dimensions"
            )

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        marker_corners, marker_ids = _detect_markers(
            cv2,
            gray,
            dictionary,
        )
        if marker_ids is None or len(marker_ids) == 0:
            continue

        count, charuco_corners, charuco_ids = (
            cv2.aruco.interpolateCornersCharuco(
                marker_corners,
                marker_ids,
                gray,
                charuco_board,
            )
        )
        if (
            charuco_ids is None
            or charuco_corners is None
            or int(count) < 6
        ):
            continue

        all_corners.append(charuco_corners)
        all_ids.append(charuco_ids)
        accepted_paths.append(image_path)

    if image_size is None:
        raise ValueError("no calibration images could be decoded")
    if len(accepted_paths) < 5:
        raise ValueError(
            "fewer than five images contained enough ChArUco corners"
        )
    if reference_image not in accepted_paths:
        raise ValueError(
            "reference image did not contain enough ChArUco corners"
        )

    calibration = cv2.aruco.calibrateCameraCharuco(
        all_corners,
        all_ids,
        charuco_board,
        image_size,
        None,
        None,
    )
    rms, camera_matrix, distortion, rvecs, tvecs = calibration[:5]

    reference_index = accepted_paths.index(reference_image)
    camera_from_board = _camera_from_board(
        cv2,
        rvecs[reference_index],
        tvecs[reference_index],
    )
    board_from_camera = _invert_rigid(camera_from_board)
    world_from_camera = _matmul4(
        world_from_board,
        board_from_camera,
    )

    reprojection_max = _maximum_reprojection_error(
        cv2,
        charuco_board,
        all_corners,
        all_ids,
        rvecs,
        tvecs,
        camera_matrix,
        distortion,
    )
    observation_count = sum(len(ids) for ids in all_ids)

    source_manifest_path = output.with_name(
        output.stem + "-source-manifest.json"
    )
    source_manifest = {
        "schema_version":
            "motionos.charuco-calibration-source-manifest.v1",
        "spec_sha256": _sha256(source),
        "images": [
            {
                "path": os.path.relpath(
                    path,
                    start=source_manifest_path.parent,
                ),
                "sha256": _sha256(path),
                "accepted": path in accepted_paths,
                "reference_image": path == reference_image,
            }
            for path in image_paths
        ],
    }
    source_manifest_path.write_text(
        json.dumps(source_manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    acceptance = spec.get("acceptance")
    if not isinstance(acceptance, dict):
        raise TypeError("acceptance must be an object")
    max_rms = float(acceptance["max_reprojection_rms_px"])
    max_max = float(acceptance["max_reprojection_max_px"])
    if acceptance.get("thresholds_frozen_before_review") is not True:
        raise ValueError(
            "calibration acceptance thresholds must be frozen"
        )

    camera_identity = spec.get("camera_identity")
    if not isinstance(camera_identity, dict):
        raise TypeError("camera_identity must be an object")
    camera_identity = dict(camera_identity)
    camera_identity["format_width"] = image_size[0]
    camera_identity["format_height"] = image_size[1]

    coefficients = [
        float(value)
        for value in distortion.reshape(-1).tolist()
    ]
    if len(coefficients) < 5:
        coefficients.extend([0.0] * (5 - len(coefficients)))
    coefficients = coefficients[:5]

    result: dict[str, object] = {
        "schema_version": "motionos.camera-calibration.v1",
        "calibration_id": str(spec["calibration_id"]),
        "camera_id": str(spec["camera_id"]),
        "camera_frame_convention": "+X right,+Y down,+Z forward",
        "image_size_px": list(image_size),
        "intrinsics": [
            [float(value) for value in row]
            for row in camera_matrix.tolist()
        ],
        "distortion": {
            "model": "brown_conrady_5",
            "coefficients": coefficients,
        },
        "world_from_camera": [
            list(row) for row in world_from_camera
        ],
        "world_frame": {
            "path": os.path.relpath(
                world_path,
                start=output.parent,
            ),
            "sha256": _sha256(world_path),
        },
        "calibration_board": {
            "path": os.path.relpath(
                board_path,
                start=output.parent,
            ),
            "sha256": actual_board_hash,
        },
        "reprojection": {
            "rms_px": float(rms),
            "max_px": reprojection_max,
            "observation_count": observation_count,
        },
        "acceptance": {
            "max_reprojection_rms_px": max_rms,
            "max_reprojection_max_px": max_max,
            "thresholds_frozen_before_review": True,
        },
        "camera_identity": camera_identity,
        "source_timestamp_basis": str(
            spec["source_timestamp_basis"]
        ),
        "source_evidence": [
            {
                "role": "calibration_capture",
                "path": os.path.relpath(
                    source_manifest_path,
                    start=output.parent,
                ),
                "sha256": _sha256(source_manifest_path),
            }
        ],
        "software": {
            "name": "opencv-charuco",
            "version": str(cv2.__version__),
        },
        "frozen_before_rig_capture": True,
    }

    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _cv2() -> Any:
    try:
        import cv2
    except ImportError as exc:
        raise RuntimeError(
            "ChArUco calibration requires the optional vision extra: "
            "pip install -e '.[vision]'"
        ) from exc
    if not hasattr(cv2, "aruco"):
        raise RuntimeError(
            "OpenCV was installed without the contrib aruco module"
        )
    return cv2


def _image_paths(base: Path, spec: dict[str, object]) -> list[Path]:
    if "images" in spec:
        raw = spec["images"]
        if not isinstance(raw, list) or not raw:
            raise ValueError("images must be a non-empty list")
        paths = [
            _resolve_path(base, item)
            for item in raw
        ]
    elif "image_glob" in spec:
        pattern = str(_resolve_path(base, spec["image_glob"]))
        paths = [
            Path(value).resolve()
            for value in sorted(glob.glob(pattern))
        ]
    else:
        raise ValueError("spec requires images or image_glob")
    unique = list(dict.fromkeys(paths))
    if not unique:
        raise ValueError("no calibration images matched")
    for path in unique:
        if not path.is_file():
            raise FileNotFoundError(path)
    return unique


def _resolve_path(base: Path, value: object) -> Path:
    path = Path(str(value))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _json_object(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _aruco_dictionary(cv2: Any, name: str) -> Any:
    if not hasattr(cv2.aruco, name):
        raise ValueError(f"unsupported ArUco dictionary: {name}")
    return cv2.aruco.getPredefinedDictionary(
        getattr(cv2.aruco, name)
    )


def _charuco_board(
    cv2: Any,
    squares_x: int,
    squares_y: int,
    square_length_m: float,
    marker_length_m: float,
    dictionary: Any,
) -> Any:
    if hasattr(cv2.aruco, "CharucoBoard"):
        return cv2.aruco.CharucoBoard(
            (squares_x, squares_y),
            square_length_m,
            marker_length_m,
            dictionary,
        )
    return cv2.aruco.CharucoBoard_create(
        squares_x,
        squares_y,
        square_length_m,
        marker_length_m,
        dictionary,
    )


def _detect_markers(
    cv2: Any,
    gray: Any,
    dictionary: Any,
) -> tuple[Any, Any]:
    if hasattr(cv2.aruco, "ArucoDetector"):
        detector = cv2.aruco.ArucoDetector(dictionary)
        corners, ids, _rejected = detector.detectMarkers(gray)
        return corners, ids
    corners, ids, _rejected = cv2.aruco.detectMarkers(
        gray,
        dictionary,
    )
    return corners, ids


def _camera_from_board(
    cv2: Any,
    rvec: Any,
    tvec: Any,
) -> tuple[tuple[float, float, float, float], ...]:
    rotation, _ = cv2.Rodrigues(rvec)
    translation = [
        float(value)
        for value in tvec.reshape(-1).tolist()
    ]
    return (
        (
            float(rotation[0, 0]),
            float(rotation[0, 1]),
            float(rotation[0, 2]),
            translation[0],
        ),
        (
            float(rotation[1, 0]),
            float(rotation[1, 1]),
            float(rotation[1, 2]),
            translation[1],
        ),
        (
            float(rotation[2, 0]),
            float(rotation[2, 1]),
            float(rotation[2, 2]),
            translation[2],
        ),
        (0.0, 0.0, 0.0, 1.0),
    )


def _maximum_reprojection_error(
    cv2: Any,
    board: Any,
    corners: list[Any],
    ids: list[Any],
    rvecs: list[Any],
    tvecs: list[Any],
    camera_matrix: Any,
    distortion: Any,
) -> float:
    board_points = board.getChessboardCorners()
    maximum = 0.0
    for frame_corners, frame_ids, rvec, tvec in zip(
        corners,
        ids,
        rvecs,
        tvecs,
        strict=True,
    ):
        object_points = board_points[
            frame_ids.reshape(-1)
        ]
        projected, _ = cv2.projectPoints(
            object_points,
            rvec,
            tvec,
            camera_matrix,
            distortion,
        )
        observed = frame_corners.reshape(-1, 2)
        projected = projected.reshape(-1, 2)
        for observed_point, projected_point in zip(
            observed,
            projected,
            strict=True,
        ):
            error = math.hypot(
                float(observed_point[0] - projected_point[0]),
                float(observed_point[1] - projected_point[1]),
            )
            maximum = max(maximum, error)
    return maximum


def _matrix4(
    raw: object,
    *,
    label: str,
) -> tuple[tuple[float, float, float, float], ...]:
    if not isinstance(raw, list) or len(raw) != 4:
        raise ValueError(f"{label} must be a 4x4 matrix")
    rows = []
    for row in raw:
        if not isinstance(row, list) or len(row) != 4:
            raise ValueError(f"{label} must be a 4x4 matrix")
        rows.append(tuple(float(value) for value in row))
    return tuple(rows)


def _validate_rigid_transform(
    matrix: tuple[tuple[float, float, float, float], ...],
    *,
    label: str,
) -> None:
    if any(
        abs(matrix[3][index] - expected) > 1e-8
        for index, expected in enumerate((0.0, 0.0, 0.0, 1.0))
    ):
        raise ValueError(
            f"{label} must end with [0,0,0,1]"
        )
    rotation = [row[:3] for row in matrix[:3]]
    for row in rotation:
        if abs(sum(value * value for value in row) - 1.0) > 1e-5:
            raise ValueError(f"{label} rotation rows must be unit length")
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
    if abs(determinant - 1.0) > 1e-5:
        raise ValueError(f"{label} rotation determinant must be +1")


def _invert_rigid(
    matrix: tuple[tuple[float, float, float, float], ...],
) -> tuple[tuple[float, float, float, float], ...]:
    rotation = tuple(
        tuple(matrix[column][row] for column in range(3))
        for row in range(3)
    )
    translation = tuple(matrix[row][3] for row in range(3))
    inverse_translation = tuple(
        -sum(
            rotation[row][column] * translation[column]
            for column in range(3)
        )
        for row in range(3)
    )
    return (
        (*rotation[0], inverse_translation[0]),
        (*rotation[1], inverse_translation[1]),
        (*rotation[2], inverse_translation[2]),
        (0.0, 0.0, 0.0, 1.0),
    )


def _matmul4(
    left: tuple[tuple[float, float, float, float], ...],
    right: tuple[tuple[float, float, float, float], ...],
) -> tuple[tuple[float, float, float, float], ...]:
    return tuple(
        tuple(
            sum(
                left[row][index] * right[index][column]
                for index in range(4)
            )
            for column in range(4)
        )
        for row in range(4)
    )
