from __future__ import annotations

import json
import math
from pathlib import Path

from .provenance import sha256_file
from .vision_contract import VisionSessionManifest

ACQUISITION_RECEIPT_SCHEMA_VERSION = (
    "motionos.indo-board-acquisition-receipt.v1"
)
ACQUISITION_PROFILE_ID = "m0-indo-board-two-camera-v1"
ACTION4_PROFILE_ID = "m0-action4-4k60-eisoff-standard-dewarp-v1"
ACTION4_CONFIRMATION_CAPABILITY = (
    "operator_confirmed_acquisition_profile:" + ACTION4_PROFILE_ID
)


def evaluate_indo_board_acquisition(
    vision_session_path: str | Path,
    iphone_metadata_path: str | Path,
    action4_metadata_path: str | Path,
    *,
    output_path: str | Path | None = None,
) -> dict[str, object]:
    vision_path = Path(vision_session_path).resolve()
    iphone_path = Path(iphone_metadata_path).resolve()
    action4_path = Path(action4_metadata_path).resolve()
    for path in (vision_path, iphone_path, action4_path):
        if not path.is_file():
            raise FileNotFoundError(path)

    manifest = VisionSessionManifest.from_dict(_json_object(vision_path))
    iphone = _json_object(iphone_path)
    action4 = _json_object(action4_path)

    camera = _mapping(iphone, "camera")
    pose = _mapping(iphone, "pose")

    checks: list[dict[str, object]] = []
    _check(
        checks,
        "vision_session_sport",
        manifest.sport == "indo_board",
        expected="indo_board",
        observed=manifest.sport,
        verification="machine",
    )
    _check(
        checks,
        "vision_capture_mode",
        manifest.capture_mode == "multiview_calibration",
        expected="multiview_calibration",
        observed=manifest.capture_mode,
        verification="machine",
    )
    _check(
        checks,
        "iphone_session_id",
        str(iphone.get("session_id", "")) == manifest.session_id,
        expected=manifest.session_id,
        observed=str(iphone.get("session_id", "")),
        verification="machine",
    )

    iphone_source_id = str(camera.get("unique_id", "")).strip()
    iphone_source = next(
        (
            source
            for source in manifest.camera_sources
            if source.source_id == iphone_source_id
        ),
        None,
    )
    _check(
        checks,
        "iphone_source_bound_to_manifest",
        iphone_source is not None,
        expected=iphone_source_id or "non-empty camera unique_id",
        observed=(
            iphone_source.source_id
            if iphone_source is not None
            else None
        ),
        verification="machine",
    )
    _check(
        checks,
        "iphone_resolution",
        _integer(camera.get("format_width")) == 1920
        and _integer(camera.get("format_height")) == 1080,
        expected="1920x1080",
        observed=(
            f"{camera.get('format_width')}x"
            f"{camera.get('format_height')}"
        ),
        verification="machine",
    )
    configured_fps = _finite_float(
        camera.get("configured_frame_rate"),
        label="camera.configured_frame_rate",
    )
    _check(
        checks,
        "iphone_frame_rate",
        math.isclose(
            configured_fps,
            30.0,
            rel_tol=0.0,
            abs_tol=0.05,
        ),
        expected=30.0,
        observed=configured_fps,
        verification="machine",
    )
    _check(
        checks,
        "iphone_frame_rate_locked",
        camera.get("frame_rate_locked") is True,
        expected=True,
        observed=camera.get("frame_rate_locked"),
        verification="machine",
    )
    _check(
        checks,
        "iphone_stabilization_off",
        camera.get("stabilization_locked_off") is True
        and str(
            camera.get("preferred_video_stabilization_mode", "")
        )
        == "off",
        expected={
            "stabilization_locked_off": True,
            "preferred_video_stabilization_mode": "off",
        },
        observed={
            "stabilization_locked_off":
                camera.get("stabilization_locked_off"),
            "preferred_video_stabilization_mode":
                camera.get("preferred_video_stabilization_mode"),
        },
        verification="machine",
    )
    _check(
        checks,
        "iphone_pose_stride",
        _integer(pose.get("stride_delivered_frames")) == 3,
        expected=3,
        observed=pose.get("stride_delivered_frames"),
        verification="machine",
    )

    action4_source = next(
        (
            source
            for source in manifest.camera_sources
            if source.source_id == "dji-action4"
        ),
        None,
    )
    capabilities = (
        set(action4_source.capabilities)
        if action4_source is not None
        else set()
    )
    _check(
        checks,
        "action4_source_bound_to_manifest",
        action4_source is not None,
        expected="dji-action4",
        observed=(
            action4_source.source_id
            if action4_source is not None
            else None
        ),
        verification="machine",
    )
    _check(
        checks,
        "action4_profile_operator_confirmed",
        ACTION4_CONFIRMATION_CAPABILITY in capabilities,
        expected=ACTION4_CONFIRMATION_CAPABILITY,
        observed=sorted(capabilities),
        verification="operator_sealed_in_manifest",
    )

    _check(
        checks,
        "action4_session_id",
        str(action4.get("session_id", "")) == manifest.session_id,
        expected=manifest.session_id,
        observed=str(action4.get("session_id", "")),
        verification="machine",
    )
    _check(
        checks,
        "action4_source_id",
        str(action4.get("source_id", "")) == "dji-action4",
        expected="dji-action4",
        observed=str(action4.get("source_id", "")),
        verification="machine",
    )
    _check(
        checks,
        "action4_resolution",
        _integer(action4.get("image_width_px")) == 3840
        and _integer(action4.get("image_height_px")) == 2160,
        expected="3840x2160",
        observed=(
            f"{action4.get('image_width_px')}x"
            f"{action4.get('image_height_px')}"
        ),
        verification="machine",
    )
    action4_fps = _finite_float(
        action4.get("effective_frame_rate_fps"),
        label="action4.effective_frame_rate_fps",
    )
    _check(
        checks,
        "action4_effective_frame_rate",
        math.isclose(
            action4_fps,
            60.0,
            rel_tol=0.0,
            abs_tol=1.0,
        ),
        expected="60 fps ± 1 fps",
        observed=action4_fps,
        verification="machine_from_container_pts",
    )
    _check(
        checks,
        "action4_pose_stride",
        _integer(action4.get("pose_stride_frames")) == 1,
        expected=1,
        observed=action4.get("pose_stride_frames"),
        verification="machine",
    )

    failed = [
        str(check["check_id"])
        for check in checks
        if check["passed"] is not True
    ]
    result: dict[str, object] = {
        "schema_version": ACQUISITION_RECEIPT_SCHEMA_VERSION,
        "profile_id": ACQUISITION_PROFILE_ID,
        "session_id": manifest.session_id,
        "passed": not failed,
        "failed_check_ids": failed,
        "checks": checks,
        "source_sha256": {
            "vision_session": sha256_file(vision_path),
            "iphone_metadata": sha256_file(iphone_path),
            "action4_metadata": sha256_file(action4_path),
        },
        "profile": {
            "iphone": {
                "resolution": "1920x1080",
                "frame_rate_fps": 30.0,
                "pose_stride_frames": 3,
                "stabilization": "off",
            },
            "action4": {
                "resolution": "3840x2160",
                "frame_rate_fps": 60.0,
                "pose_stride_frames": 1,
                "stabilization": "off",
                "fov_mode": "Standard (Dewarp)",
                "stabilization_and_fov_verification":
                    "operator confirmation sealed in vision session",
            },
        },
        "claim_boundary": (
            "Resolution, decoded cadence, software pose stride, and iPhone "
            "stabilization configuration are machine-verifiable. Action 4 "
            "EIS and FOV mode are operator-confirmed because those settings "
            "are not treated as reliably recoverable from the imported MP4. "
            "This receipt verifies acquisition consistency, not biomechanical "
            "accuracy."
        ),
    }

    if output_path is not None:
        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return result


def require_indo_board_acquisition(
    vision_session_path: str | Path,
    iphone_metadata_path: str | Path,
    action4_metadata_path: str | Path,
) -> dict[str, object]:
    receipt = evaluate_indo_board_acquisition(
        vision_session_path,
        iphone_metadata_path,
        action4_metadata_path,
    )
    if receipt["passed"] is not True:
        failed = ", ".join(receipt["failed_check_ids"])
        raise ValueError(
            "Indo Board acquisition profile failed: " + failed
        )
    return receipt


def _check(
    checks: list[dict[str, object]],
    check_id: str,
    passed: bool,
    *,
    expected: object,
    observed: object,
    verification: str,
) -> None:
    checks.append(
        {
            "check_id": check_id,
            "passed": bool(passed),
            "expected": expected,
            "observed": observed,
            "verification": verification,
        }
    )


def _mapping(
    source: dict[str, object],
    key: str,
) -> dict[str, object]:
    value = source.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"{key} must be an object")
    return value


def _integer(raw: object) -> int | None:
    if isinstance(raw, bool):
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    try:
        if float(raw) != value:
            return None
    except (TypeError, ValueError):
        return None
    return value


def _finite_float(
    raw: object,
    *,
    label: str,
) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be numeric") from exc
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite")
    return value


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw
