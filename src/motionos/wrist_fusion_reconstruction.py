from __future__ import annotations

import json
import math
from pathlib import Path

from .indo_board_acquisition import (
    ACQUISITION_PROFILE_ID,
    evaluate_indo_board_acquisition,
    require_indo_board_acquisition,
)
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

RECONSTRUCTION_SPEC_SCHEMA_VERSION = (
    "motionos.wrist-fusion-reconstruction-spec.v1"
)
RECONSTRUCTION_RECEIPT_SCHEMA_VERSION = (
    "motionos.wrist-fusion-reconstruction.v1"
)


def reconstruct_wrist_fusion_calibration(
    spec_path: str | Path,
    output_directory: str | Path,
) -> dict[str, object]:
    source = Path(spec_path).resolve()
    spec = validate_wrist_fusion_reconstruction_spec(source)
    base = source.parent

    vision_session = _resolve(base, spec["vision_session"])
    watch_journal = _resolve(base, spec["watch_journal"])
    rig_receipt = _resolve(base, spec["rig_receipt"])
    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    iphone_journal = _resolve(base, iphone["journal"])
    action4_journal = _resolve(base, action4["journal"])

    thresholds = _mapping(spec, "thresholds")
    maximum_pose_pair_ms = float(
        thresholds["maximum_pose_pair_ms"]
    )
    minimum_joint_confidence = float(
        thresholds["minimum_joint_confidence"]
    )

    rig = _json_object(rig_receipt)
    rig_id = str(rig["rig_id"])
    iphone_source_id = infer_pose2d_source_id(iphone_journal)
    action4_source_id = infer_pose2d_source_id(action4_journal)

    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)

    acquisition_path = output / "indo-board-acquisition-receipt.json"
    acquisition_receipt = evaluate_indo_board_acquisition(
        vision_session,
        _resolve(base, iphone["metadata"]),
        _resolve(base, action4["metadata"]),
        output_path=acquisition_path,
    )
    if acquisition_receipt["passed"] is not True:
        raise ValueError(
            "calibration acquisition profile failed after preflight"
        )

    external_sync_path = output / "action4-clock-sync.json"
    write_external_camera_sync(
        vision_session,
        iphone_journal,
        action4_journal,
        external_sync_path,
        iphone_source_id=iphone_source_id,
        external_source_id=action4_source_id,
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
        source_id=iphone_source_id,
        clock_model=iphone_clock,
    )
    action4_pose = load_pose2d_journal(
        action4_journal,
        source_id=action4_source_id,
        clock_model=action4_clock,
    )
    pairs = pair_pose_observations(
        iphone_pose.observations,
        action4_pose.observations,
        maximum_time_delta_ms=maximum_pose_pair_ms,
    )
    if not pairs:
        raise ValueError(
            "no synchronized calibration pose frames survived timing gate"
        )

    correspondences_path = output / "skeleton-correspondences.json"
    write_skeleton_sequence_correspondences(
        pairs,
        correspondences_path,
        rig_id=rig_id,
        rig_receipt_path=rig_receipt,
        minimum_joint_confidence=minimum_joint_confidence,
        maximum_frame_time_delta_ms=maximum_pose_pair_ms,
    )

    geometry_path = output / "skeleton-geometry.json"
    triangulate_multiview(
        rig_receipt,
        correspondences_path,
        geometry_path,
    )

    input_paths = {
        "vision_session": vision_session,
        "watch_journal": watch_journal,
        "rig_receipt": rig_receipt,
        "iphone_journal": iphone_journal,
        "iphone_metadata": _resolve(base, iphone["metadata"]),
        "action4_journal": action4_journal,
        "action4_metadata": _resolve(base, action4["metadata"]),
        "spec": source,
    }
    artifact_paths = {
        "acquisition_receipt": acquisition_path,
        "external_sync": external_sync_path,
        "clock_bundle": clock_bundle_path,
        "skeleton_correspondences": correspondences_path,
        "skeleton_geometry": geometry_path,
    }

    manifest = VisionSessionManifest.from_dict(
        _json_object(vision_session)
    )
    receipt: dict[str, object] = {
        "schema_version": RECONSTRUCTION_RECEIPT_SCHEMA_VERSION,
        "session_id": manifest.session_id,
        "rig_id": rig_id,
        "acquisition_profile_id": ACQUISITION_PROFILE_ID,
        "acquisition_receipt_sha256": sha256_file(acquisition_path),
        "pose_pair_count": len(pairs),
        "thresholds": dict(thresholds),
        "input_sha256": {
            key: sha256_file(path)
            for key, path in sorted(input_paths.items())
        },
        "artifacts": {
            key: {
                "path": str(path),
                "sha256": sha256_file(path),
            }
            for key, path in sorted(artifact_paths.items())
        },
        "claim_boundary": (
            "This receipt reconstructs synchronized camera-derived 3D "
            "skeleton geometry for a separate Watch/vision calibration run. "
            "It does not compute scored Indo Board metrics or update the "
            "longitudinal profile."
        ),
    }
    receipt_path = output / "wrist-fusion-reconstruction-receipt.json"
    receipt_path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return receipt


def validate_wrist_fusion_reconstruction_spec(
    spec_path: str | Path,
) -> dict[str, object]:
    source = Path(spec_path).resolve()
    spec = _json_object(source)
    if spec.get("schema_version") != RECONSTRUCTION_SPEC_SCHEMA_VERSION:
        raise ValueError(
            "unsupported wrist-fusion reconstruction spec schema"
        )
    base = source.parent

    iphone = _mapping(spec, "iphone")
    action4 = _mapping(spec, "action4")
    required = {
        "vision_session": _resolve(base, spec["vision_session"]),
        "watch_journal": _resolve(base, spec["watch_journal"]),
        "rig_receipt": _resolve(base, spec["rig_receipt"]),
        "iphone.journal": _resolve(base, iphone["journal"]),
        "iphone.metadata": _resolve(base, iphone["metadata"]),
        "action4.journal": _resolve(base, action4["journal"]),
        "action4.metadata": _resolve(base, action4["metadata"]),
    }
    missing = [
        label
        for label, path in required.items()
        if not path.is_file()
    ]
    if missing:
        raise FileNotFoundError(
            "calibration reconstruction inputs are missing: "
            + ", ".join(missing)
        )

    require_indo_board_acquisition(
        required["vision_session"],
        required["iphone.metadata"],
        required["action4.metadata"],
    )

    manifest = VisionSessionManifest.from_dict(
        _json_object(required["vision_session"])
    )
    if manifest.capture_mode != "multiview_calibration":
        raise ValueError(
            "calibration reconstruction requires multiview_calibration mode"
        )
    landmarks = [
        landmark
        for landmark in manifest.sync_landmarks
        if landmark.kind == "whole_body_impulse"
    ]
    if len(landmarks) < 3:
        raise ValueError(
            "calibration reconstruction requires at least three sync landmarks"
        )
    landmark_ids = [item.landmark_id for item in landmarks]
    if len(landmark_ids) != len(set(landmark_ids)):
        raise ValueError("sync landmark IDs must be unique")
    _validate_watch_receipts(
        required["watch_journal"],
        session_id=manifest.session_id,
        landmark_ids=landmark_ids,
    )

    rig = _json_object(required["rig_receipt"])
    if rig.get("schema_version") != "motionos.camera-rig-receipt.v1":
        raise ValueError(
            "calibration reconstruction requires a camera-rig receipt"
        )
    if rig.get("passed") is not True:
        raise ValueError(
            "calibration reconstruction requires a passing camera rig"
        )
    cameras = rig.get("cameras")
    if not isinstance(cameras, list):
        raise TypeError("camera-rig receipt cameras must be a list")
    rig_camera_ids = {
        str(item.get("camera_id"))
        for item in cameras
        if isinstance(item, dict)
    }

    expected_iphone_source_id = _validate_iphone_journal_binding(
        manifest,
        journal_path=required["iphone.journal"],
        metadata_path=required["iphone.metadata"],
    )
    expected_action4_source_id = _validate_action4_journal_binding(
        manifest,
        journal_path=required["action4.journal"],
        metadata_path=required["action4.metadata"],
    )

    iphone_source_id = infer_pose2d_source_id(
        required["iphone.journal"]
    )
    action4_source_id = infer_pose2d_source_id(
        required["action4.journal"]
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
        raise ValueError("camera journals must use distinct source IDs")
    if {iphone_source_id, action4_source_id} - rig_camera_ids:
        raise ValueError(
            "calibration camera journal IDs are absent from the rig receipt"
        )

    thresholds = _mapping(spec, "thresholds")
    _positive_float(thresholds, "maximum_pose_pair_ms")
    _fraction(thresholds, "minimum_joint_confidence")
    return spec


def _validate_iphone_journal_binding(
    manifest: VisionSessionManifest,
    *,
    journal_path: Path,
    metadata_path: Path,
) -> str:
    metadata = _json_object(metadata_path)
    if metadata.get("schema_version") != "motionos.camera.v1":
        raise ValueError("unsupported iPhone camera metadata schema")
    if str(metadata.get("session_id", "")) != manifest.session_id:
        raise ValueError(
            "iPhone metadata session_id does not match calibration session"
        )
    camera = metadata.get("camera")
    provenance = metadata.get("provenance")
    if not isinstance(camera, dict) or not isinstance(provenance, dict):
        raise TypeError(
            "iPhone metadata requires camera and provenance objects"
        )
    source_id = str(camera.get("unique_id", "")).strip()
    if not source_id:
        raise ValueError("iPhone metadata requires a camera unique_id")
    if str(
        provenance.get("camera_frames_jsonl_sha256", "")
    ) != sha256_file(journal_path):
        raise ValueError(
            "iPhone calibration journal hash does not match sealed metadata"
        )
    return source_id


def _validate_action4_journal_binding(
    manifest: VisionSessionManifest,
    *,
    journal_path: Path,
    metadata_path: Path,
) -> str:
    metadata = _json_object(metadata_path)
    if metadata.get("schema_version") != (
        "motionos.external-video-pose2d.v1"
    ):
        raise ValueError("unsupported Action4 metadata schema")
    if str(metadata.get("session_id", "")) != manifest.session_id:
        raise ValueError(
            "Action4 metadata session_id does not match calibration session"
        )
    source_id = str(metadata.get("source_id", "")).strip()
    if not source_id:
        raise ValueError("Action4 metadata requires source_id")
    source_video = metadata.get("source_video")
    if not isinstance(source_video, dict):
        raise TypeError("Action4 metadata.source_video must be an object")
    video_hash = str(source_video.get("sha256", ""))
    journal_hash = sha256_file(journal_path)
    matches = [
        artifact
        for artifact in manifest.derived_artifacts
        if artifact.source_id == source_id
        and artifact.kind == "pose2d_journal"
        and artifact.sha256 == journal_hash
        and artifact.source_media_sha256 == video_hash
    ]
    if not matches:
        raise ValueError(
            "Action4 calibration journal is not bound to the sealed session"
        )
    return source_id


def _validate_watch_receipts(
    path: Path,
    *,
    session_id: str,
    landmark_ids: list[str],
) -> None:
    counts = {landmark_id: 0 for landmark_id in landmark_ids}
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
                f"invalid Watch event at line {line_number}"
            ) from exc
        if event.stream != "/sync/vision_cue":
            continue
        if str(event.payload.get("vision_session_id", "")) != session_id:
            continue
        landmark_id = str(event.payload.get("landmark_id", ""))
        if landmark_id in counts:
            counts[landmark_id] += 1

    bad = [
        landmark_id
        for landmark_id, count in counts.items()
        if count != 1
    ]
    if bad:
        raise ValueError(
            "calibration Watch journal requires exactly one receipt "
            "for each sealed sync landmark"
        )


def _mapping(
    source: dict[str, object],
    key: str,
) -> dict[str, object]:
    value = source.get(key)
    if not isinstance(value, dict):
        raise TypeError(f"{key} must be an object")
    return dict(value)


def _positive_float(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), key=key)
    if value <= 0:
        raise ValueError(f"{key} must be positive")
    return value


def _fraction(
    source: dict[str, object],
    key: str,
) -> float:
    value = _finite_float(source.get(key), key=key)
    if not 0 <= value <= 1:
        raise ValueError(f"{key} must be between 0 and 1")
    return value


def _finite_float(
    raw: object,
    *,
    key: str,
) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} must be numeric") from exc
    if not math.isfinite(value):
        raise ValueError(f"{key} must be finite")
    return value


def _resolve(base: Path, raw: object) -> Path:
    path = Path(str(raw))
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _json_object(path: str | Path) -> dict[str, object]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw
