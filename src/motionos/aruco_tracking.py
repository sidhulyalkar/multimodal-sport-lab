from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .board_pose import load_board_marker_layout
from .schema import SensorEvent


def track_board_markers(
    video_path: str | Path,
    frame_journal_path: str | Path,
    layout_path: str | Path,
    output_path: str | Path,
    *,
    source_id: str,
    frame_stride: int = 1,
) -> dict[str, object]:
    if frame_stride <= 0:
        raise ValueError("frame_stride must be positive")

    cv2 = _cv2()
    video = Path(video_path).resolve()
    journal = Path(frame_journal_path).resolve()
    layout_source = Path(layout_path).resolve()
    layout = load_board_marker_layout(layout_source)
    if not layout.marker_dictionary:
        raise ValueError(
            "board marker layout must declare marker_dictionary"
        )

    marker_ids = _numeric_marker_ids(layout.markers_m)
    dictionary = _dictionary(
        cv2,
        layout.marker_dictionary,
    )
    detector = _detector(cv2, dictionary)
    source_frames = _video_frame_events(
        journal,
        source_id=source_id,
    )

    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise ValueError(f"unable to open video: {video}")

    frames: list[dict[str, object]] = []
    decoded_count = 0
    try:
        while True:
            ok, image = capture.read()
            if not ok:
                break
            if decoded_count >= len(source_frames):
                raise ValueError(
                    "decoded video contains more frames than the "
                    "MotionOS frame journal"
                )

            event = source_frames[decoded_count]
            if decoded_count % frame_stride == 0:
                gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
                corners, ids = _detect(
                    cv2,
                    detector,
                    gray,
                    dictionary,
                )
                detected: dict[str, object] = {}
                if ids is not None:
                    for marker_corners, marker_id_raw in zip(
                        corners,
                        ids.reshape(-1),
                        strict=True,
                    ):
                        marker_id = int(marker_id_raw)
                        if marker_id not in marker_ids:
                            continue
                        points = marker_corners.reshape(-1, 2)
                        center_x = float(
                            sum(point[0] for point in points)
                            / len(points)
                        )
                        center_y = float(
                            sum(point[1] for point in points)
                            / len(points)
                        )
                        detected[str(marker_id)] = {
                            "u_px": center_x,
                            "v_px": center_y,
                            "corners_px": [
                                [float(point[0]), float(point[1])]
                                for point in points
                            ],
                        }

                if detected:
                    frames.append(
                        {
                            "source_frame_sequence": event.sequence,
                            "source_frame_pts_ns": event.device_time_ns,
                            "decoded_video_frame_index": decoded_count,
                            "image_width_px": int(image.shape[1]),
                            "image_height_px": int(image.shape[0]),
                            "markers": detected,
                        }
                    )
            decoded_count += 1
    finally:
        capture.release()

    if decoded_count != len(source_frames):
        raise ValueError(
            "decoded video frame count does not match the MotionOS "
            "journal's written-frame count"
        )
    if not frames:
        raise ValueError(
            "no declared Indo Board markers were detected in the video"
        )

    result: dict[str, object] = {
        "schema_version": "motionos.board-marker-observations.v1",
        "source_id": source_id,
        "layout_id": layout.layout_id,
        "marker_dictionary": layout.marker_dictionary,
        "layout_sha256": _sha256(layout_source),
        "video_sha256": _sha256(video),
        "frame_journal_sha256": _sha256(journal),
        "frame_stride": frame_stride,
        "decoded_frame_count": decoded_count,
        "observation_frame_count": len(frames),
        "frames": frames,
        "claim_boundary": (
            "Marker pixel centers are image observations tied back to "
            "MotionOS source frame sequence and PTS. They become metric "
            "board coordinates only after calibrated multiview "
            "triangulation and rigid-layout fitting."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _video_frame_events(
    path: Path,
    *,
    source_id: str,
) -> tuple[SensorEvent, ...]:
    frames: list[SensorEvent] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        try:
            event = SensorEvent.from_json(line)
        except Exception as exc:
            raise ValueError(
                f"invalid frame journal event at line {line_number}"
            ) from exc
        if event.stream != "/camera/frame":
            continue
        if event.device_id != source_id:
            continue

        written = event.payload.get("video_written")
        if written is False:
            continue
        frames.append(event)

    if not frames:
        raise ValueError(
            f"no video-backed /camera/frame events found for {source_id}"
        )
    return tuple(frames)


def _numeric_marker_ids(
    markers: dict[str, tuple[float, float, float]],
) -> set[int]:
    result: set[int] = set()
    for marker_id in markers:
        try:
            result.add(int(marker_id))
        except ValueError as exc:
            raise ValueError(
                "ArUco board tracking requires numeric marker IDs"
            ) from exc
    return result


def _cv2() -> Any:
    try:
        import cv2
    except ImportError as exc:
        raise RuntimeError(
            "Board marker tracking requires the optional vision extra: "
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


def _detector(cv2: Any, dictionary: Any) -> Any | None:
    if hasattr(cv2.aruco, "ArucoDetector"):
        return cv2.aruco.ArucoDetector(dictionary)
    return None


def _detect(
    cv2: Any,
    detector: Any | None,
    gray: Any,
    dictionary: Any,
) -> tuple[Any, Any]:
    if detector is not None:
        corners, ids, _rejected = detector.detectMarkers(gray)
        return corners, ids
    corners, ids, _rejected = cv2.aruco.detectMarkers(
        gray,
        dictionary,
    )
    return corners, ids


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
