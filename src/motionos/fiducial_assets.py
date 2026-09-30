from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any


CHARUCO_BUILD_SPEC_SCHEMA_VERSION = "motionos.charuco-board-build-spec.v1"
ARUCO_MARKER_BUILD_SPEC_SCHEMA_VERSION = (
    "motionos.aruco-marker-build-spec.v1"
)


def build_charuco_board_assets(
    spec_path: str | Path,
    output_directory: str | Path,
) -> dict[str, object]:
    cv2 = _cv2()
    source = Path(spec_path).resolve()
    spec = _json_object(source)
    if spec.get("schema_version") != CHARUCO_BUILD_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported ChArUco board build spec schema")

    board_id = _text(spec, "board_id")
    squares_x = _positive_int(spec, "squares_x")
    squares_y = _positive_int(spec, "squares_y")
    if squares_x < 2 or squares_y < 2:
        raise ValueError("ChArUco board requires at least 2x2 squares")
    square_length_m = _positive_float(spec, "square_length_m")
    marker_length_m = _positive_float(spec, "marker_length_m")
    if marker_length_m >= square_length_m:
        raise ValueError(
            "marker_length_m must be smaller than square_length_m"
        )
    dictionary_name = _text(spec, "dictionary")
    print_dpi = _positive_int(spec, "print_dpi")
    margin_m = _nonnegative_float(spec, "margin_m", default=0.01)

    dictionary = _dictionary(cv2, dictionary_name)
    board = _charuco_board(
        cv2,
        squares_x,
        squares_y,
        square_length_m,
        marker_length_m,
        dictionary,
    )

    board_width_m = squares_x * square_length_m
    board_height_m = squares_y * square_length_m
    page_width_m = board_width_m + 2.0 * margin_m
    page_height_m = board_height_m + 2.0 * margin_m
    width_px = _meters_to_pixels(page_width_m, print_dpi)
    height_px = _meters_to_pixels(page_height_m, print_dpi)
    margin_px = _meters_to_pixels(margin_m, print_dpi)

    image = _charuco_image(
        board,
        size=(width_px, height_px),
        margin_px=margin_px,
    )

    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image_path = output / f"{board_id}.png"
    if not cv2.imwrite(str(image_path), image):
        raise RuntimeError("OpenCV could not write the ChArUco PNG")

    image_sha = _sha256(image_path)
    board_contract = {
        "schema_version": "motionos.calibration-board.v1",
        "board_id": board_id,
        "board_type": "charuco",
        "squares_x": squares_x,
        "squares_y": squares_y,
        "square_length_m": square_length_m,
        "marker_length_m": marker_length_m,
        "dictionary": dictionary_name,
        "printable_source_sha256": image_sha,
    }
    contract_path = output / f"{board_id}.json"
    contract_path.write_text(
        json.dumps(board_contract, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    receipt: dict[str, object] = {
        "schema_version": "motionos.charuco-board-build-receipt.v1",
        "board_id": board_id,
        "source_spec_sha256": _sha256(source),
        "board_contract": {
            "path": contract_path.name,
            "sha256": _sha256(contract_path),
        },
        "printable": {
            "path": image_path.name,
            "sha256": image_sha,
            "print_dpi": print_dpi,
            "pixel_size": [width_px, height_px],
            "board_size_m": [board_width_m, board_height_m],
            "page_size_m": [page_width_m, page_height_m],
            "margin_m": margin_m,
            "print_scale_percent": 100,
        },
        "software": {
            "name": "opencv-aruco",
            "version": str(cv2.__version__),
        },
        "operator_instructions": [
            "Print at 100% / Actual Size; disable Fit, Shrink, or Scale.",
            "Measure one printed square edge with a ruler before calibration.",
            (
                "Reject the print if the measured square edge differs from "
                "square_length_m by more than your physical calibration tolerance."
            ),
            "Keep the generated JSON and PNG together as immutable evidence.",
        ],
        "claim_boundary": (
            "The receipt fixes digital board geometry and intended print scale. "
            "It does not prove a printer reproduced that scale accurately; "
            "physical measurement of the printed board remains required."
        ),
    }
    receipt_path = output / f"{board_id}-build-receipt.json"
    receipt_path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def build_aruco_marker_assets(
    spec_path: str | Path,
    output_directory: str | Path,
) -> dict[str, object]:
    cv2 = _cv2()
    source = Path(spec_path).resolve()
    spec = _json_object(source)
    if spec.get("schema_version") != ARUCO_MARKER_BUILD_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported ArUco marker build spec schema")

    asset_id = _text(spec, "asset_id")
    dictionary_name = _text(spec, "dictionary")
    marker_size_m = _positive_float(spec, "marker_size_m")
    print_dpi = _positive_int(spec, "print_dpi")
    border_bits = _positive_int(spec, "border_bits")
    raw_ids = spec.get("marker_ids")
    if (
        not isinstance(raw_ids, list)
        or len(raw_ids) < 3
        or any(isinstance(value, bool) for value in raw_ids)
    ):
        raise ValueError("marker_ids must contain at least three integers")
    marker_ids = [int(value) for value in raw_ids]
    if len(marker_ids) != len(set(marker_ids)):
        raise ValueError("marker_ids must be unique")
    if any(value < 0 for value in marker_ids):
        raise ValueError("marker_ids must be non-negative")

    dictionary = _dictionary(cv2, dictionary_name)
    dictionary_size = _dictionary_size(dictionary)
    if any(marker_id >= dictionary_size for marker_id in marker_ids):
        raise ValueError(
            "marker ID exceeds the selected dictionary capacity"
        )

    marker_pixels = _meters_to_pixels(marker_size_m, print_dpi)
    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)

    markers: list[dict[str, object]] = []
    for marker_id in marker_ids:
        image = _aruco_marker_image(
            cv2,
            dictionary,
            marker_id,
            marker_pixels,
            border_bits=border_bits,
        )
        filename = f"{asset_id}-marker-{marker_id}.png"
        path = output / filename
        if not cv2.imwrite(str(path), image):
            raise RuntimeError(
                f"OpenCV could not write ArUco marker {marker_id}"
            )
        markers.append(
            {
                "marker_id": marker_id,
                "path": filename,
                "sha256": _sha256(path),
                "pixel_size": [marker_pixels, marker_pixels],
                "physical_size_m": marker_size_m,
            }
        )

    manifest: dict[str, object] = {
        "schema_version": "motionos.aruco-marker-build-receipt.v1",
        "asset_id": asset_id,
        "source_spec_sha256": _sha256(source),
        "dictionary": dictionary_name,
        "marker_size_m": marker_size_m,
        "print_dpi": print_dpi,
        "border_bits": border_bits,
        "markers": markers,
        "software": {
            "name": "opencv-aruco",
            "version": str(cv2.__version__),
        },
        "operator_instructions": [
            "Print at 100% / Actual Size; disable Fit, Shrink, or Scale.",
            "Measure the outer black marker width after printing.",
            "Mount markers flat and do not cover their black border.",
            (
                "Measure final marker-center coordinates on the physical board "
                "after mounting; those measurements define the rigid layout."
            ),
        ],
        "claim_boundary": (
            "Generated marker files fix dictionary IDs and intended physical "
            "size. Final board pose still depends on measured mounted marker "
            "centers in the frozen board-layout contract."
        ),
    }
    manifest_path = output / f"{asset_id}-build-receipt.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def _cv2() -> Any:
    try:
        import cv2
    except ImportError as exc:
        raise RuntimeError(
            "Fiducial generation requires the optional vision extra: "
            "pip install -e '.[vision]'"
        ) from exc
    if not hasattr(cv2, "aruco"):
        raise RuntimeError(
            "OpenCV was installed without the contrib aruco module"
        )
    return cv2


def _dictionary(cv2: Any, name: str) -> Any:
    if not hasattr(cv2.aruco, name):
        raise ValueError(f"unsupported ArUco dictionary: {name}")
    return cv2.aruco.getPredefinedDictionary(
        getattr(cv2.aruco, name)
    )


def _dictionary_size(dictionary: Any) -> int:
    bytes_list = getattr(dictionary, "bytesList", None)
    if bytes_list is None:
        raise RuntimeError("OpenCV dictionary does not expose marker capacity")
    return int(bytes_list.shape[0])


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


def _charuco_image(
    board: Any,
    *,
    size: tuple[int, int],
    margin_px: int,
) -> Any:
    if hasattr(board, "generateImage"):
        return board.generateImage(
            size,
            marginSize=margin_px,
            borderBits=1,
        )
    return board.draw(
        size,
        marginSize=margin_px,
        borderBits=1,
    )


def _aruco_marker_image(
    cv2: Any,
    dictionary: Any,
    marker_id: int,
    pixels: int,
    *,
    border_bits: int,
) -> Any:
    if hasattr(cv2.aruco, "generateImageMarker"):
        return cv2.aruco.generateImageMarker(
            dictionary,
            marker_id,
            pixels,
            borderBits=border_bits,
        )
    return cv2.aruco.drawMarker(
        dictionary,
        marker_id,
        pixels,
        borderBits=border_bits,
    )


def _meters_to_pixels(meters: float, dpi: int) -> int:
    pixels = round(meters / 0.0254 * dpi)
    if pixels <= 0:
        raise ValueError("physical dimension resolves to zero pixels")
    return pixels


def _json_object(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw


def _text(document: dict[str, object], key: str) -> str:
    value = str(document.get(key, "")).strip()
    if not value:
        raise ValueError(f"{key} is required")
    return value


def _positive_int(document: dict[str, object], key: str) -> int:
    raw = document.get(key)
    if isinstance(raw, bool):
        raise TypeError(f"{key} must be a positive integer")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be a positive integer") from exc
    try:
        exact = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be a positive integer") from exc
    if value <= 0 or not math.isfinite(exact) or exact != value:
        raise ValueError(f"{key} must be a positive integer")
    return value


def _positive_float(document: dict[str, object], key: str) -> float:
    raw = document.get(key)
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be positive") from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{key} must be positive")
    return value


def _nonnegative_float(
    document: dict[str, object],
    key: str,
    *,
    default: float,
) -> float:
    raw = document.get(key, default)
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be non-negative") from exc
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{key} must be non-negative")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
