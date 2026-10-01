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
from .indo_board_qualification import (
    build_indo_board_qualification_receipt,
    validate_qualification_contract,
)
from .indo_board_quality import build_indo_board_quality_report
from .indo_board_reconstruction import build_indo_board_samples
from .longitudinal import update_longitudinal_profile_if_qualified
from .multiview_pose import write_skeleton_sequence_correspondences
from .pose2d_io import (
    infer_pose2d_source_id,
    load_pose2d_journal,
    pair_pose_observations,
)
from .provenance import sha256_file
from .schema import SensorEvent
from .vision_clock import build_vision_clock_bundle, load_clock_from_bundle
from .vision_contract import VisionSessionManifest
from .vision_sync import write_external_camera_sync
from .world_geometry import triangulate_multiview
from .wrist_fusion import build_wrist_acceleration_fusion

PIPELINE_SPEC_SCHEMA_VERSION = "motionos.indo-board-pipeline-spec.v1"
PIPELINE_STATE_SCHEMA_VERSION = "motionos.indo-board-pipeline-state.v1"
PIPELINE_IMPLEMENTATION_VERSION = "motionos.indo-board-pipeline.impl.v1"


def process_indo_board_pipeline(
    spec_path: str | Path,
    output_directory: str | Path,
    *,
    resume: bool = False,
) -> dict[str, object]:
    spec_source = Path(spec_path).resolve()
    spec = validate_indo_board_pipeline_spec(spec_source)

    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = spec_source.parent
    state_path = output / "pipeline-state.json"
    state = _initialize_pipeline_state(
        state_path,
        spec_source=spec_source,
        spec=spec,
        resume=resume,
    )
    reused_stages: list[str] = []

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
    fusion_calibration_receipt = _resolve(
        base,
        spec["wrist_fusion_calibration_receipt"],
    )
    thresholds = _mapping(spec, "thresholds")
    fusion = _mapping(spec, "wrist_fusion")
    qualification = _mapping(spec, "qualification")

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
    iphone_source_id = infer_pose2d_source_id(iphone_journal)
    action4_source_id = infer_pose2d_source_id(action4_journal)

    external_sync_path = output / "action4-clock-sync.json"
    if resume and _stage_reusable(
        state,
        "external_clock_sync",
        external_sync_path,
    ):
        reused_stages.append("external_clock_sync")
    else:
        write_external_camera_sync(
            vision_session,
            iphone_journal,
            action4_journal,
            external_sync_path,
        )
        _record_stage(
            state,
            state_path,
            "external_clock_sync",
            external_sync_path,
        )

    clock_bundle_path = output / "vision-clock-bundle.json"
    if resume and _stage_reusable(
        state,
        "vision_clock_bundle",
        clock_bundle_path,
    ):
        reused_stages.append("vision_clock_bundle")
    else:
        build_vision_clock_bundle(
            vision_session,
            watch_journal,
            iphone_journal,
            external_sync_path,
            clock_bundle_path,
        )
        _record_stage(
            state,
            state_path,
            "vision_clock_bundle",
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

    skeleton_correspondences = output / "skeleton-correspondences.json"
    if resume and _stage_reusable(
        state,
        "skeleton_correspondences",
        skeleton_correspondences,
    ):
        reused_stages.append("skeleton_correspondences")
        skeleton_document = _json_object(skeleton_correspondences)
        pose_pair_count = int(skeleton_document.get("pair_count", 0))
        if pose_pair_count <= 0:
            raise ValueError(
                "reused skeleton correspondences lack a positive pair_count"
            )
    else:
        iphone_pose = load_pose2d_journal(
            iphone_journal,
            source_id=iphone_source_id,
            clock_model=iphone_clock,
        )
        action4_pose = load_pose2d_journal(
            action4_journal,
            source_id=action4_source_id,
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
        write_skeleton_sequence_correspondences(
            pose_pairs,
            skeleton_correspondences,
            rig_id=rig_id,
            rig_receipt_path=rig_receipt,
            minimum_joint_confidence=minimum_joint_confidence,
            maximum_frame_time_delta_ms=maximum_pose_pair_ms,
        )
        pose_pair_count = len(pose_pairs)
        _record_stage(
            state,
            state_path,
            "skeleton_correspondences",
            skeleton_correspondences,
        )

    skeleton_geometry = output / "skeleton-geometry.json"
    if resume and _stage_reusable(
        state,
        "skeleton_geometry",
        skeleton_geometry,
    ):
        reused_stages.append("skeleton_geometry")
    else:
        triangulate_multiview(
            rig_receipt,
            skeleton_correspondences,
            skeleton_geometry,
        )
        _record_stage(
            state,
            state_path,
            "skeleton_geometry",
            skeleton_geometry,
        )

    iphone_markers_path = output / "iphone-board-markers.json"
    action4_markers_path = output / "action4-board-markers.json"
    if resume and _stage_reusable(
        state,
        "iphone_board_markers",
        iphone_markers_path,
    ):
        reused_stages.append("iphone_board_markers")
    else:
        track_board_markers(
            iphone_video,
            iphone_journal,
            marker_layout,
            iphone_markers_path,
            source_id=iphone_source_id,
            frame_stride=marker_frame_stride,
        )
        _record_stage(
            state,
            state_path,
            "iphone_board_markers",
            iphone_markers_path,
        )

    if resume and _stage_reusable(
        state,
        "action4_board_markers",
        action4_markers_path,
    ):
        reused_stages.append("action4_board_markers")
    else:
        track_board_markers(
            action4_video,
            action4_journal,
            marker_layout,
            action4_markers_path,
            source_id=action4_source_id,
            frame_stride=marker_frame_stride,
        )
        _record_stage(
            state,
            state_path,
            "action4_board_markers",
            action4_markers_path,
        )

    iphone_marker_frames = load_marker_frames(
        iphone_markers_path,
        clock_model=iphone_clock,
    )
    action4_marker_frames = load_marker_frames(
        action4_markers_path,
        clock_model=action4_clock,
    )
    board_correspondences = output / "board-correspondences.json"
    if resume and _stage_reusable(
        state,
        "board_correspondences",
        board_correspondences,
    ):
        reused_stages.append("board_correspondences")
        board_document = _json_object(board_correspondences)
        marker_pair_count = int(board_document.get("pair_count", 0))
        if marker_pair_count <= 0:
            raise ValueError(
                "reused board correspondences lack a positive pair_count"
            )
    else:
        marker_pairs = pair_marker_frames(
            iphone_marker_frames,
            action4_marker_frames,
            maximum_time_delta_ms=maximum_marker_pair_ms,
        )
        if not marker_pairs:
            raise ValueError(
                "no synchronized board-marker frames survived timing gate"
            )
        write_board_marker_correspondences(
            marker_pairs,
            board_correspondences,
            rig_id=rig_id,
            rig_receipt_path=rig_receipt,
        )
        marker_pair_count = len(marker_pairs)
        _record_stage(
            state,
            state_path,
            "board_correspondences",
            board_correspondences,
        )

    board_geometry = output / "board-geometry.json"
    if resume and _stage_reusable(
        state,
        "board_geometry",
        board_geometry,
    ):
        reused_stages.append("board_geometry")
    else:
        triangulate_multiview(
            rig_receipt,
            board_correspondences,
            board_geometry,
        )
        _record_stage(
            state,
            state_path,
            "board_geometry",
            board_geometry,
        )

    board_pose_series = output / "board-pose-series.json"
    if resume and _stage_reusable(
        state,
        "board_pose_series",
        board_pose_series,
    ):
        reused_stages.append("board_pose_series")
    else:
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
        _record_stage(
            state,
            state_path,
            "board_pose_series",
            board_pose_series,
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
    _record_stage(
        state,
        state_path,
        "indo_board_reconstruction",
        reconstruction_path,
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
    _record_stage(
        state,
        state_path,
        "indo_board_metrics",
        metrics_path,
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
    _record_stage(
        state,
        state_path,
        "wrist_acceleration_fusion",
        wrist_path,
    )
    quality_path = output / "indo-board-quality-report.json"
    quality_report = build_indo_board_quality_report(
        external_sync_path=external_sync_path,
        clock_bundle_path=clock_bundle_path,
        skeleton_correspondences_path=skeleton_correspondences,
        skeleton_geometry_path=skeleton_geometry,
        board_correspondences_path=board_correspondences,
        board_geometry_path=board_geometry,
        board_pose_series_path=board_pose_series,
        reconstruction_path=reconstruction_path,
        metrics_path=metrics_path,
        wrist_fusion_path=wrist_path,
        output_path=quality_path,
    )
    _record_stage(
        state,
        state_path,
        "indo_board_quality_report",
        quality_path,
    )

    qualification_path = output / "indo-board-qualification-receipt.json"
    qualification_receipt = build_indo_board_qualification_receipt(
        quality_path,
        qualification,
        qualification_path,
    )
    _record_stage(
        state,
        state_path,
        "indo_board_qualification",
        qualification_path,
    )

    profile, longitudinal_updated = (
        update_longitudinal_profile_if_qualified(
            profile_path,
            metrics,
            qualification_passed=bool(
                qualification_receipt["passed"]
            ),
            minimum_confidence=float(
                thresholds.get(
                    "minimum_longitudinal_confidence",
                    0.6,
                )
            ),
        )
    )
    if longitudinal_updated and profile_path.is_file():
        _record_stage(
            state,
            state_path,
            "longitudinal_profile",
            profile_path,
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
        quality_path,
        qualification_path,
        profile_path,
        state_path,
    ]
    receipt: dict[str, object] = {
        "schema_version": "motionos.indo-board-pipeline-receipt.v1",
        "session_id": manifest.session_id,
        "spec_sha256": sha256_file(spec_source),
        "rig_receipt_sha256": sha256_file(rig_receipt),
        "wrist_fusion_calibration_receipt_sha256":
            sha256_file(fusion_calibration_receipt),
        "pose_pair_count": pose_pair_count,
        "marker_pair_count": marker_pair_count,
        "metric_count": len(metrics.metrics),
        "longitudinal_metric_count": len(profile.metric_baselines),
        "longitudinal_updated": longitudinal_updated,
        "qualification_passed": qualification_receipt["passed"],
        "qualification_failed_gate_ids":
            qualification_receipt["failed_gate_ids"],
        "wrist_fusion_sample_count": wrist_report["sample_count"],
        "quality_summary": quality_report["summary"],
        "attention_flags": quality_report["attention_flags"],
        "execution": {
            "resume_requested": resume,
            "reused_stages": sorted(reused_stages),
            "pipeline_implementation_version":
                PIPELINE_IMPLEMENTATION_VERSION,
        },
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
        "board_marker_asset_receipt": _resolve(
            base,
            spec["board_marker_asset_receipt"],
        ),
        "wrist_fusion_calibration_receipt": _resolve(
            base,
            spec["wrist_fusion_calibration_receipt"],
        ),
    }
    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    required_paths.update(
        {
            "iphone.video": _resolve(base, iphone["video"]),
            "iphone.journal": _resolve(base, iphone["journal"]),
            "iphone.metadata": _resolve(base, iphone["metadata"]),
            "action4.video": _resolve(base, action4["video"]),
            "action4.journal": _resolve(base, action4["journal"]),
            "action4.metadata": _resolve(base, action4["metadata"]),
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

    _validate_board_marker_asset_chain(
        layout_path=required_paths["board_marker_layout"],
        receipt_path=required_paths["board_marker_asset_receipt"],
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
    sealed_sync_landmarks = [
        landmark
        for landmark in manifest.sync_landmarks
        if landmark.kind == "whole_body_impulse"
    ]
    if len(sealed_sync_landmarks) < 3:
        raise ValueError(
            "vision session requires at least three whole-body sync landmarks"
        )
    landmark_ids = [
        landmark.landmark_id
        for landmark in sealed_sync_landmarks
    ]
    if len(set(landmark_ids)) != len(landmark_ids):
        raise ValueError(
            "vision session sync landmark IDs must be unique"
        )
    _validate_watch_sync_receipts(
        required_paths["watch_journal"],
        vision_session_id=manifest.session_id,
        landmark_ids=landmark_ids,
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
    expected_iphone_source_id = _validate_iphone_evidence_chain(
        manifest,
        video_path=required_paths["iphone.video"],
        journal_path=required_paths["iphone.journal"],
        metadata_path=required_paths["iphone.metadata"],
    )
    expected_action4_source_id = _validate_action4_evidence_chain(
        manifest,
        video_path=required_paths["action4.video"],
        journal_path=required_paths["action4.journal"],
        metadata_path=required_paths["action4.metadata"],
    )

    iphone_source_id = infer_pose2d_source_id(
        required_paths["iphone.journal"]
    )
    action4_source_id = infer_pose2d_source_id(
        required_paths["action4.journal"]
    )
    if iphone_source_id != expected_iphone_source_id:
        raise ValueError(
            "iPhone pose journal camera ID does not match sealed metadata"
        )
    if action4_source_id != expected_action4_source_id:
        raise ValueError(
            "Action4 pose journal camera ID does not match sealed metadata"
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
    _positive_required(
        fusion,
        "maximum_time_delta_ms",
    )
    _validate_wrist_fusion_calibration_chain(
        receipt_path=required_paths[
            "wrist_fusion_calibration_receipt"
        ],
        fusion=fusion,
    )

    qualification = _mapping(spec, "qualification")
    validate_qualification_contract(qualification)

    profile = _resolve(base, spec["longitudinal_profile"])
    if profile.exists() and not profile.is_file():
        raise ValueError(
            "longitudinal_profile must be a file path"
        )
    return spec


def _validate_board_marker_asset_chain(
    *,
    layout_path: Path,
    receipt_path: Path,
) -> None:
    layout = _json_object(layout_path)
    if layout.get("schema_version") != "motionos.board-marker-layout.v1":
        raise ValueError("unsupported board marker layout schema")

    receipt = _json_object(receipt_path)
    if receipt.get("schema_version") != (
        "motionos.aruco-marker-build-receipt.v1"
    ):
        raise ValueError("unsupported ArUco marker build receipt schema")

    receipt_hash = sha256_file(receipt_path)
    if layout.get("marker_asset_receipt_sha256") != receipt_hash:
        raise ValueError(
            "board marker layout is not bound to this ArUco build receipt"
        )

    layout_id = str(layout.get("layout_id", ""))
    if not layout_id or str(receipt.get("asset_id", "")) != layout_id:
        raise ValueError(
            "board marker layout_id must match ArUco asset_id"
        )

    dictionary = str(layout.get("marker_dictionary", ""))
    if not dictionary or str(receipt.get("dictionary", "")) != dictionary:
        raise ValueError(
            "board marker dictionary does not match ArUco build receipt"
        )

    try:
        layout_marker_size = float(layout["marker_size_m"])
        receipt_marker_size = float(receipt["marker_size_m"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(
            "board marker layout and receipt require marker_size_m"
        ) from exc
    if (
        not math.isfinite(layout_marker_size)
        or layout_marker_size <= 0
        or not math.isclose(
            layout_marker_size,
            receipt_marker_size,
            rel_tol=1e-12,
            abs_tol=1e-12,
        )
    ):
        raise ValueError(
            "board marker size does not match ArUco build receipt"
        )

    markers = layout.get("markers_m")
    if not isinstance(markers, dict) or len(markers) < 3:
        raise ValueError(
            "board marker layout requires at least three measured markers"
        )
    try:
        layout_ids = {int(marker_id) for marker_id in markers}
    except ValueError as exc:
        raise ValueError(
            "board marker layout IDs must be numeric ArUco IDs"
        ) from exc

    receipt_markers = receipt.get("markers")
    if not isinstance(receipt_markers, list):
        raise TypeError("ArUco build receipt markers must be a list")
    receipt_ids: set[int] = set()
    for item in receipt_markers:
        if not isinstance(item, dict):
            raise TypeError(
                "ArUco build receipt marker entries must be objects"
            )
        marker_id = int(item["marker_id"])
        receipt_ids.add(marker_id)
        if not math.isclose(
            float(item["physical_size_m"]),
            layout_marker_size,
            rel_tol=1e-12,
            abs_tol=1e-12,
        ):
            raise ValueError(
                "ArUco build receipt contains inconsistent marker size"
            )

    if layout_ids != receipt_ids:
        raise ValueError(
            "board marker layout IDs do not match ArUco build receipt"
        )


def _validate_watch_sync_receipts(
    watch_journal_path: Path,
    *,
    vision_session_id: str,
    landmark_ids: list[str],
) -> None:
    receipt_counts = {
        landmark_id: 0
        for landmark_id in landmark_ids
    }

    for line_number, line in enumerate(
        watch_journal_path.read_text(
            encoding="utf-8"
        ).splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        try:
            event = SensorEvent.from_json(line)
        except Exception as exc:
            raise ValueError(
                f"invalid Watch sensor event at line {line_number}"
            ) from exc
        if event.stream != "/sync/vision_cue":
            continue
        if str(event.payload.get("vision_session_id", "")) != (
            vision_session_id
        ):
            continue
        landmark_id = str(
            event.payload.get("landmark_id", "")
        )
        if landmark_id in receipt_counts:
            receipt_counts[landmark_id] += 1

    missing = sorted(
        landmark_id
        for landmark_id, count in receipt_counts.items()
        if count == 0
    )
    if missing:
        raise ValueError(
            "Watch journal is missing sealed SYNC receipts: "
            + ", ".join(missing)
        )

    duplicates = sorted(
        landmark_id
        for landmark_id, count in receipt_counts.items()
        if count > 1
    )
    if duplicates:
        raise ValueError(
            "Watch journal contains duplicate sealed SYNC receipts: "
            + ", ".join(duplicates)
        )


def _initialize_pipeline_state(
    state_path: Path,
    *,
    spec_source: Path,
    spec: dict[str, object],
    resume: bool,
) -> dict[str, object]:
    expected = {
        "schema_version": PIPELINE_STATE_SCHEMA_VERSION,
        "pipeline_implementation_version":
            PIPELINE_IMPLEMENTATION_VERSION,
        "spec_sha256": sha256_file(spec_source),
        "input_sha256": _pipeline_state_input_hashes(
            spec_source.parent,
            spec,
        ),
        "stages": {},
    }
    if resume and state_path.is_file():
        raw = _json_object(state_path)
        if (
            raw.get("schema_version")
            == expected["schema_version"]
            and raw.get("pipeline_implementation_version")
            == expected["pipeline_implementation_version"]
            and raw.get("spec_sha256") == expected["spec_sha256"]
            and raw.get("input_sha256") == expected["input_sha256"]
            and isinstance(raw.get("stages"), dict)
        ):
            return raw

    _write_pipeline_state(state_path, expected)
    return expected


def _pipeline_state_input_hashes(
    base: Path,
    spec: dict[str, object],
) -> dict[str, str]:
    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    paths = {
        "vision_session": _resolve(base, spec["vision_session"]),
        "watch_journal": _resolve(base, spec["watch_journal"]),
        "rig_receipt": _resolve(base, spec["rig_receipt"]),
        "board_marker_layout": _resolve(
            base,
            spec["board_marker_layout"],
        ),
        "board_marker_asset_receipt": _resolve(
            base,
            spec["board_marker_asset_receipt"],
        ),
        "iphone_metadata": _resolve(base, iphone["metadata"]),
        "action4_metadata": _resolve(base, action4["metadata"]),
        "wrist_fusion_calibration_receipt": _resolve(
            base,
            spec["wrist_fusion_calibration_receipt"],
        ),
    }
    return {
        label: sha256_file(path)
        for label, path in sorted(paths.items())
    }


def _stage_reusable(
    state: dict[str, object],
    stage_name: str,
    *artifacts: Path,
) -> bool:
    stages = state.get("stages")
    if not isinstance(stages, dict):
        return False
    stage = stages.get(stage_name)
    if not isinstance(stage, dict):
        return False
    recorded = stage.get("artifacts")
    if not isinstance(recorded, dict):
        return False

    for path in artifacts:
        expected = recorded.get(path.name)
        if not isinstance(expected, dict):
            return False
        if not path.is_file():
            return False
        if expected.get("sha256") != sha256_file(path):
            return False
    return True


def _record_stage(
    state: dict[str, object],
    state_path: Path,
    stage_name: str,
    *artifacts: Path,
) -> None:
    stages = state.setdefault("stages", {})
    if not isinstance(stages, dict):
        raise TypeError("pipeline state stages must be an object")
    stages[stage_name] = {
        "artifacts": {
            path.name: {
                "path": str(path),
                "sha256": sha256_file(path),
            }
            for path in artifacts
            if path.is_file()
        }
    }
    _write_pipeline_state(state_path, state)


def _write_pipeline_state(
    state_path: Path,
    state: dict[str, object],
) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_path.with_suffix(state_path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(state_path)


def _validate_iphone_evidence_chain(
    manifest: VisionSessionManifest,
    *,
    video_path: Path,
    journal_path: Path,
    metadata_path: Path,
) -> str:
    metadata = _json_object(metadata_path)
    if metadata.get("schema_version") != "motionos.camera.v1":
        raise ValueError("unsupported iPhone camera metadata schema")
    if str(metadata.get("session_id", "")) != manifest.session_id:
        raise ValueError(
            "iPhone camera metadata session_id does not match vision session"
        )

    camera = metadata.get("camera")
    if not isinstance(camera, dict):
        raise TypeError("iPhone camera metadata.camera must be an object")
    source_id = str(camera.get("unique_id", ""))
    if not source_id:
        raise ValueError(
            "iPhone camera metadata requires a non-empty unique_id"
        )

    provenance = metadata.get("provenance")
    if not isinstance(provenance, dict):
        raise TypeError(
            "iPhone camera metadata.provenance must be an object"
        )
    expected_video = str(provenance.get("camera_mov_sha256", ""))
    expected_journal = str(
        provenance.get("camera_frames_jsonl_sha256", "")
    )
    if expected_video != sha256_file(video_path):
        raise ValueError(
            "iPhone video hash does not match sealed camera metadata"
        )
    if expected_journal != sha256_file(journal_path):
        raise ValueError(
            "iPhone journal hash does not match sealed camera metadata"
        )
    return source_id


def _validate_action4_evidence_chain(
    manifest: VisionSessionManifest,
    *,
    video_path: Path,
    journal_path: Path,
    metadata_path: Path,
) -> str:
    metadata = _json_object(metadata_path)
    if metadata.get("schema_version") != (
        "motionos.external-video-pose2d.v1"
    ):
        raise ValueError("unsupported Action4 derived metadata schema")
    if str(metadata.get("session_id", "")) != manifest.session_id:
        raise ValueError(
            "Action4 metadata session_id does not match vision session"
        )
    source_id = str(metadata.get("source_id", ""))
    if not source_id:
        raise ValueError(
            "Action4 metadata requires a non-empty source_id"
        )

    source_video = metadata.get("source_video")
    if not isinstance(source_video, dict):
        raise TypeError(
            "Action4 metadata.source_video must be an object"
        )
    video_hash = sha256_file(video_path)
    journal_hash = sha256_file(journal_path)
    metadata_hash = sha256_file(metadata_path)
    if str(source_video.get("sha256", "")) != video_hash:
        raise ValueError(
            "Action4 video hash does not match derived pose metadata"
        )

    media_matches = [
        artifact
        for artifact in manifest.media_artifacts
        if artifact.source_id == source_id
        and artifact.sha256 == video_hash
    ]
    if not media_matches:
        raise ValueError(
            "Action4 video is not bound to the sealed vision session"
        )

    journal_matches = [
        artifact
        for artifact in manifest.derived_artifacts
        if artifact.source_id == source_id
        and artifact.kind == "pose2d_journal"
        and artifact.sha256 == journal_hash
        and artifact.source_media_sha256 == video_hash
    ]
    if not journal_matches:
        raise ValueError(
            "Action4 pose journal is not bound to the sealed vision session"
        )

    metadata_matches = [
        artifact
        for artifact in manifest.derived_artifacts
        if artifact.source_id == source_id
        and artifact.kind == "pose2d_metadata"
        and artifact.sha256 == metadata_hash
        and artifact.source_media_sha256 == video_hash
    ]
    if not metadata_matches:
        raise ValueError(
            "Action4 pose metadata is not bound to the sealed vision session"
        )
    return source_id


def _validate_wrist_fusion_calibration_chain(
    *,
    receipt_path: Path,
    fusion: dict[str, object],
) -> None:
    receipt = _json_object(receipt_path)
    if receipt.get("schema_version") != (
        "motionos.wrist-fusion-calibration.v1"
    ):
        raise ValueError(
            "unsupported wrist-fusion calibration receipt schema"
        )
    recommended = receipt.get("recommended_wrist_fusion")
    if not isinstance(recommended, dict):
        raise TypeError(
            "wrist-fusion calibration receipt requires "
            "recommended_wrist_fusion"
        )

    keys = (
        "watch_acceleration_std_m_s2",
        "vision_acceleration_std_m_s2",
        "maximum_acceleration_rate_m_s3",
        "maximum_time_delta_ms",
    )
    for key in keys:
        if key not in fusion:
            raise ValueError(
                f"wrist_fusion.{key} is required"
            )
        if key not in recommended:
            raise ValueError(
                f"calibration receipt is missing {key}"
            )
        try:
            configured = float(fusion[key])
            calibrated = float(recommended[key])
        except (TypeError, ValueError) as exc:
            raise ValueError(
                f"wrist-fusion calibration value {key} must be numeric"
            ) from exc
        if (
            not math.isfinite(configured)
            or not math.isfinite(calibrated)
            or not math.isclose(
                configured,
                calibrated,
                rel_tol=1e-12,
                abs_tol=1e-12,
            )
        ):
            raise ValueError(
                "wrist_fusion parameters do not match the exact "
                f"calibration receipt for {key}"
            )


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
