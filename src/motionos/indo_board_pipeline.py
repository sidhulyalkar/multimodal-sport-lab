from __future__ import annotations

import json
import math
from pathlib import Path

from .aruco_tracking import track_board_markers
from .board_marker_correspondences import (
    load_marker_frames,
    pair_marker_frames,
    write_board_marker_correspondences,
)
from .board_pose_series import build_board_pose_series
from .indo_board import analyze_indo_board
from .indo_board_reconstruction import build_indo_board_samples
from .longitudinal import update_longitudinal_profile
from .multiview_pose import write_skeleton_sequence_correspondences
from .pose2d_io import (
    infer_pose2d_source_id,
    load_pose2d_journal,
    pair_pose_observations,
)
from .provenance import sha256_file
from .vision_clock import build_vision_clock_bundle, load_clock_from_bundle
from .vision_contract import VisionSessionManifest
from .vision_sync import write_external_camera_sync
from .world_geometry import triangulate_multiview
from .wrist_fusion import build_wrist_acceleration_fusion

PIPELINE_SPEC_SCHEMA_VERSION = "motionos.indo-board-pipeline-spec.v1"


def process_indo_board_pipeline(
    spec_path: str | Path,
    output_directory: str | Path,
) -> dict[str, object]:
    spec_source = Path(spec_path).resolve()
    spec = validate_indo_board_pipeline_spec(spec_source)

    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = spec_source.parent

    vision_session = _resolve(base, spec["vision_session"])
    watch_journal = _resolve(base, spec["watch_journal"])
    rig_receipt = _resolve(base, spec["rig_receipt"])
    marker_layout = _resolve(base, spec["board_marker_layout"])

    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    iphone_video = _resolve(base, iphone["video"])
    iphone_journal = _resolve(base, iphone["journal"])
    action4_video = _resolve(base, action4["video"])
    action4_journal = _resolve(base, action4["journal"])

    profile_path = _resolve(base, spec["longitudinal_profile"])
    thresholds = _mapping(spec, "thresholds")
    fusion = _mapping(spec, "wrist_fusion")

    maximum_pose_pair_ms = float(
        thresholds.get("maximum_pose_pair_ms", 10.0)
    )
    maximum_marker_pair_ms = float(
        thresholds.get("maximum_marker_pair_ms", 10.0)
    )
    minimum_joint_confidence = float(
        thresholds.get("minimum_joint_confidence", 0.6)
    )
    marker_frame_stride = int(
        thresholds.get("marker_frame_stride", 1)
    )

    manifest = VisionSessionManifest.from_dict(
        _json_object(vision_session)
    )
    rig = _json_object(rig_receipt)
    if rig.get("schema_version") != "motionos.camera-rig-receipt.v1":
        raise ValueError("pipeline requires a camera-rig receipt")
    if rig.get("passed") is not True:
        raise ValueError("pipeline requires a passing camera-rig receipt")
    rig_id = str(rig["rig_id"])

    external_sync_path = output / "action4-clock-sync.json"
    write_external_camera_sync(
        vision_session,
        iphone_journal,
        action4_journal,
        external_sync_path,
    )

    clock_bundle_path = output / "vision-clock-bundle.json"
    build_vision_clock_bundle(
        vision_session,
        watch_journal,
        iphone_journal,
        external_sync_path,
        clock_bundle_path,
    )
    iphone_clock = load_clock_from_bundle(
        clock_bundle_path,
        "iphone_camera_to_watch",
    )
    action4_clock = load_clock_from_bundle(
        clock_bundle_path,
        "action4_to_watch",
    )

    iphone_pose = load_pose2d_journal(
        iphone_journal,
        clock_model=iphone_clock,
    )
    action4_pose = load_pose2d_journal(
        action4_journal,
        source_id="dji-action4",
        clock_model=action4_clock,
    )
    pose_pairs = pair_pose_observations(
        iphone_pose.observations,
        action4_pose.observations,
        maximum_time_delta_ms=maximum_pose_pair_ms,
    )
    if not pose_pairs:
        raise ValueError(
            "no synchronized iPhone/Action4 pose frames survived"
        )

    skeleton_correspondences = output / "skeleton-correspondences.json"
    write_skeleton_sequence_correspondences(
        pose_pairs,
        skeleton_correspondences,
        rig_id=rig_id,
        rig_receipt_path=rig_receipt,
        minimum_joint_confidence=minimum_joint_confidence,
        maximum_frame_time_delta_ms=maximum_pose_pair_ms,
    )
    skeleton_geometry = output / "skeleton-geometry.json"
    triangulate_multiview(
        rig_receipt,
        skeleton_correspondences,
        skeleton_geometry,
    )

    iphone_markers_path = output / "iphone-board-markers.json"
    action4_markers_path = output / "action4-board-markers.json"
    track_board_markers(
        iphone_video,
        iphone_journal,
        marker_layout,
        iphone_markers_path,
        source_id=iphone_pose.source_id,
        frame_stride=marker_frame_stride,
    )
    track_board_markers(
        action4_video,
        action4_journal,
        marker_layout,
        action4_markers_path,
        source_id="dji-action4",
        frame_stride=marker_frame_stride,
    )

    iphone_marker_frames = load_marker_frames(
        iphone_markers_path,
        clock_model=iphone_clock,
    )
    action4_marker_frames = load_marker_frames(
        action4_markers_path,
        clock_model=action4_clock,
    )
    marker_pairs = pair_marker_frames(
        iphone_marker_frames,
        action4_marker_frames,
        maximum_time_delta_ms=maximum_marker_pair_ms,
    )
    if not marker_pairs:
        raise ValueError(
            "no synchronized board-marker frames survived timing gate"
        )

    board_correspondences = output / "board-correspondences.json"
    write_board_marker_correspondences(
        marker_pairs,
        board_correspondences,
        rig_id=rig_id,
        rig_receipt_path=rig_receipt,
    )
    board_geometry = output / "board-geometry.json"
    triangulate_multiview(
        rig_receipt,
        board_correspondences,
        board_geometry,
    )
    board_pose_series = output / "board-pose-series.json"
    build_board_pose_series(
        board_geometry,
        marker_layout,
        board_pose_series,
        maximum_scale_error_fraction=float(
            thresholds.get(
                "maximum_board_scale_error_fraction",
                0.03,
            )
        ),
    )

    samples, reconstruction = build_indo_board_samples(
        skeleton_geometry,
        skeleton_correspondences,
        board_pose_series,
        maximum_pair_time_delta_ms=float(
            thresholds.get(
                "maximum_skeleton_board_pair_ms",
                20.0,
            )
        ),
        minimum_modeled_mass_coverage=float(
            thresholds.get(
                "minimum_modeled_mass_coverage",
                0.75,
            )
        ),
        maximum_board_fit_residual_m=float(
            thresholds.get(
                "maximum_board_fit_residual_m",
                0.03,
            )
        ),
    )
    reconstruction_path = output / "indo-board-reconstruction.json"
    reconstruction_path.write_text(
        json.dumps(reconstruction, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    metrics = analyze_indo_board(
        samples,
        session_id=manifest.session_id,
        minimum_pose_confidence=float(
            thresholds.get("minimum_pose_confidence", 0.6)
        ),
        maximum_timing_uncertainty_ms=float(
            thresholds.get(
                "maximum_timing_uncertainty_ms",
                20.0,
            )
        ),
        maximum_reprojection_rms_px=float(
            thresholds.get(
                "maximum_reprojection_rms_px",
                3.0,
            )
        ),
    )
    metrics_path = output / "indo-board-report.json"
    metrics_path.write_text(
        json.dumps(metrics.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    profile = update_longitudinal_profile(
        profile_path,
        metrics,
        minimum_confidence=float(
            thresholds.get(
                "minimum_longitudinal_confidence",
                0.6,
            )
        ),
    )

    wrist_path = output / "wrist-acceleration-fusion.json"
    wrist_report = build_wrist_acceleration_fusion(
        skeleton_geometry,
        skeleton_correspondences,
        watch_journal,
        wrist_path,
        watch_acceleration_std_m_s2=float(
            fusion["watch_acceleration_std_m_s2"]
        ),
        vision_acceleration_std_m_s2=float(
            fusion["vision_acceleration_std_m_s2"]
        ),
        maximum_acceleration_rate_m_s3=float(
            fusion["maximum_acceleration_rate_m_s3"]
        ),
        maximum_time_delta_ms=float(
            fusion.get("maximum_time_delta_ms", 20.0)
        ),
    )

    artifacts = [
        external_sync_path,
        clock_bundle_path,
        skeleton_correspondences,
        skeleton_geometry,
        iphone_markers_path,
        action4_markers_path,
        board_correspondences,
        board_geometry,
        board_pose_series,
        reconstruction_path,
        metrics_path,
        wrist_path,
        profile_path,
    ]
    receipt: dict[str, object] = {
        "schema_version": "motionos.indo-board-pipeline-receipt.v1",
        "session_id": manifest.session_id,
        "spec_sha256": sha256_file(spec_source),
        "rig_receipt_sha256": sha256_file(rig_receipt),
        "pose_pair_count": len(pose_pairs),
        "marker_pair_count": len(marker_pairs),
        "metric_count": len(metrics.metrics),
        "longitudinal_metric_count": len(profile.metric_baselines),
        "wrist_fusion_sample_count": wrist_report["sample_count"],
        "artifacts": {
            path.name: {
                "path": str(path),
                "sha256": sha256_file(path),
            }
            for path in artifacts
            if path.is_file()
        },
        "claim_boundary": (
            "This receipt proves deterministic execution and provenance "
            "linkage of the M0-Vision Indo Board pipeline. Physical sensor "
            "accuracy remains bounded by the separately qualified camera "
            "calibration, rig, timing, marker-layout, and measurement models."
        ),
    }
    receipt_path = output / "indo-board-pipeline-receipt.json"
    receipt_path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def validate_indo_board_pipeline_spec(
    spec_path: str | Path,
) -> dict[str, object]:
    spec_source = Path(spec_path).resolve()
    spec = _json_object(spec_source)
    if spec.get("schema_version") != PIPELINE_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported Indo Board pipeline spec schema")

    base = spec_source.parent
    required_paths = {
        "vision_session": _resolve(base, spec["vision_session"]),
        "watch_journal": _resolve(base, spec["watch_journal"]),
        "rig_receipt": _resolve(base, spec["rig_receipt"]),
        "board_marker_layout": _resolve(base, spec["board_marker_layout"]),
    }
    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    required_paths.update(
        {
            "iphone.video": _resolve(base, iphone["video"]),
            "iphone.journal": _resolve(base, iphone["journal"]),
            "action4.video": _resolve(base, action4["video"]),
            "action4.journal": _resolve(base, action4["journal"]),
        }
    )
    missing = [
        label
        for label, path in required_paths.items()
        if not path.is_file()
    ]
    if missing:
        raise FileNotFoundError(
            "pipeline input files are missing: " + ", ".join(missing)
        )

    manifest = VisionSessionManifest.from_dict(
        _json_object(required_paths["vision_session"])
    )
    if manifest.sport != "indo_board":
        raise ValueError(
            "vision session sport must be 'indo_board'"
        )
    if manifest.capture_mode != "multiview_calibration":
        raise ValueError(
            "vision session capture_mode must be 'multiview_calibration'"
        )
    if len(
        [
            landmark
            for landmark in manifest.sync_landmarks
            if landmark.kind == "whole_body_impulse"
        ]
    ) < 3:
        raise ValueError(
            "vision session requires at least three whole-body sync landmarks"
        )

    rig = _json_object(required_paths["rig_receipt"])
    if rig.get("schema_version") != "motionos.camera-rig-receipt.v1":
        raise ValueError("pipeline requires a camera-rig receipt")
    if rig.get("passed") is not True:
        raise ValueError("pipeline requires a passing camera-rig receipt")
    cameras = rig.get("cameras")
    if not isinstance(cameras, list) or len(cameras) < 2:
        raise ValueError(
            "camera-rig receipt must contain at least two cameras"
        )
    rig_camera_ids = {
        str(camera["camera_id"])
        for camera in cameras
        if isinstance(camera, dict) and camera.get("camera_id") is not None
    }
    iphone_source_id = infer_pose2d_source_id(
        required_paths["iphone.journal"]
    )
    action4_source_id = infer_pose2d_source_id(
        required_paths["action4.journal"]
    )
    if iphone_source_id == action4_source_id:
        raise ValueError(
            "iPhone and Action4 journals must have distinct camera IDs"
        )
    missing_camera_ids = {
        iphone_source_id,
        action4_source_id,
    } - rig_camera_ids
    if missing_camera_ids:
        raise ValueError(
            "camera-rig receipt does not contain journal camera IDs: "
            + ", ".join(sorted(missing_camera_ids))
        )

    thresholds = _mapping(spec, "thresholds")
    _positive(
        thresholds,
        "maximum_pose_pair_ms",
        default=10.0,
    )
    _positive(
        thresholds,
        "maximum_marker_pair_ms",
        default=10.0,
    )
    _fraction(
        thresholds,
        "minimum_joint_confidence",
        default=0.6,
    )
    _positive_integer(
        thresholds,
        "marker_frame_stride",
        default=1,
    )
    _positive(
        thresholds,
        "maximum_board_scale_error_fraction",
        default=0.03,
        allow_zero=True,
    )
    _positive(
        thresholds,
        "maximum_skeleton_board_pair_ms",
        default=20.0,
    )
    _fraction(
        thresholds,
        "minimum_modeled_mass_coverage",
        default=0.75,
    )
    _positive(
        thresholds,
        "maximum_board_fit_residual_m",
        default=0.03,
    )
    _fraction(
        thresholds,
        "minimum_pose_confidence",
        default=0.6,
    )
    _positive(
        thresholds,
        "maximum_timing_uncertainty_ms",
        default=20.0,
    )
    _positive(
        thresholds,
        "maximum_reprojection_rms_px",
        default=3.0,
    )
    _fraction(
        thresholds,
        "minimum_longitudinal_confidence",
        default=0.6,
    )

    fusion = _mapping(spec, "wrist_fusion")
    _positive_required(
        fusion,
        "watch_acceleration_std_m_s2",
    )
    _positive_required(
        fusion,
        "vision_acceleration_std_m_s2",
    )
    _positive_required(
        fusion,
        "maximum_acceleration_rate_m_s3",
    )
    _positive(
        fusion,
        "maximum_time_delta_ms",
        default=20.0,
    )

    profile = _resolve(base, spec["longitudinal_profile"])
    if profile.exists() and not profile.is_file():
        raise ValueError(
            "longitudinal_profile must be a file path"
        )
    return spec


def _positive_required(
    mapping: dict[str, object],
    key: str,
) -> float:
    if key not in mapping:
        raise ValueError(f"{key} is required")
    return _positive(mapping, key)


def _positive(
    mapping: dict[str, object],
    key: str,
    *,
    default: float | None = None,
    allow_zero: bool = False,
) -> float:
    raw = mapping.get(key, default)
    if raw is None:
        raise ValueError(f"{key} is required")
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be numeric") from exc
    if not math.isfinite(value):
        raise ValueError(f"{key} must be finite")
    if allow_zero:
        if value < 0:
            raise ValueError(f"{key} must be non-negative")
    elif value <= 0:
        raise ValueError(f"{key} must be positive")
    return value


def _fraction(
    mapping: dict[str, object],
    key: str,
    *,
    default: float,
) -> float:
    value = _positive(mapping, key, default=default, allow_zero=True)
    if value > 1:
        raise ValueError(f"{key} must be between 0 and 1")
    return value


def _positive_integer(
    mapping: dict[str, object],
    key: str,
    *,
    default: int,
) -> int:
    raw = mapping.get(key, default)
    if isinstance(raw, bool):
        raise TypeError(f"{key} must be a positive integer")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"{key} must be a positive integer"
        ) from exc
    if value <= 0 or float(raw) != value:
        raise ValueError(f"{key} must be a positive integer")
    return value


def _mapping(
    source: dict[str, object],
    key: str,
) -> dict[str, object]:
    value = source.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"{key} must be an object")
    return dict(value)


def _resolve(base: Path, value: object) -> Path:
    path = Path(str(value))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _json_object(path: Path) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return dict(raw)
