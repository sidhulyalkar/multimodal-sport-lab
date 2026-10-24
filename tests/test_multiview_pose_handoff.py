from __future__ import annotations

import json
from pathlib import Path

import pytest

# Reuse the physically meaningful two-camera synthetic geometry fixture.
from test_world_geometry import _fixture

from motionos.multiview_pose_handoff import build_multiview_pose_correspondences
from motionos.provenance import sha256_file
from motionos.world_geometry import (
    _project_world_point,
    build_camera_rig_receipt,
    load_camera_calibration,
    triangulate_multiview,
)


def _write(path: Path, data: dict) -> Path:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def _dataset(tmp_path: Path) -> tuple[Path, dict[str, Path]]:
    paths = _fixture(tmp_path)
    rig_path = tmp_path / "rig.json"
    rig = build_camera_rig_receipt(paths["rig_spec"], rig_path)
    assert rig["passed"] is True
    refs = []
    for cam in rig["cameras"]:
        cid = cam["camera_id"]
        movie = tmp_path / f"{cid}.mov"
        movie.write_bytes(b"original video bytes for " + cid.encode())
        video_sha = sha256_file(movie)
        calibration = load_camera_calibration(paths[f"calibration_{cid[-1]}"])
        px = _project_world_point(calibration, (0.0, 0.1, 5.0))
        frames = []
        for index, pts in enumerate((1_000_000_000, 1_100_000_000)):
            if cid == "cam-a":
                # Same normalized lower-left convention as Action 4 Vision.
                x, y = px[0] / 1919, 1 - px[1] / 1079
                mode = "source_image_normalized_origin_lower_left_after_orientation"
            else:
                x, y = px
                mode = "source_image_pixels_origin_upper_left_after_orientation"
            frames.append({
                "source_frame_sequence": index * 3,
                "source_frame_pts_ns": pts,
                "subject_id": "participant-01",
                "joints": [
                    {"id": "leftWrist", "x": x, "y": y, "confidence": 0.95},
                    {"id": "leftAnkle", "x": x, "y": y, "confidence": 0.20},
                ],
            })
        track = _write(tmp_path / f"{cid}.json", {
            "schema_version": "motionos.camera-pose-observations.v1",
            "camera_id": cid,
            "session_id": cam["session_id"],
            "session_bundle_sha256": cam["session_bundle_sha256"],
            "source_video_sha256": video_sha,
            "subject_id": "participant-01",
            "image_size_px": [1920, 1080],
            "coordinate_frame": mode,
            "frames": frames,
        })
        refs.append({
            "camera_id": cid,
            "track": {"path": str(track), "sha256": sha256_file(track)},
            "original_video": {"path": str(movie), "sha256": video_sha},
        })
        paths[f"{cid}_track"] = track
        paths[f"{cid}_movie"] = movie
    spec = _write(tmp_path / "pose-handoff-spec.json", {
        "schema_version": "motionos.multiview-pose-handoff-spec.v1",
        "subject_id": "participant-01",
        "anchor_camera_id": "cam-a",
        "operator_confirmed_single_person_identity": True,
        "min_joint_confidence": 0.50,
        "min_matched_points": 2,
        "min_matched_anchor_fraction": 1.0,
        "rig_receipt": {"path": str(rig_path), "sha256": sha256_file(rig_path)},
        "camera_tracks": refs,
    })
    return spec, paths


def _run(spec: Path, tmp_path: Path) -> dict:
    return build_multiview_pose_correspondences(
        spec, tmp_path / "correspondences.json", audit_path=tmp_path / "audit.json"
    )


def test_normalized_and_pixel_paths_triangulate_without_interpolation(tmp_path: Path) -> None:
    spec, paths = _dataset(tmp_path)
    audit = _run(spec, tmp_path)
    assert audit["point_count"] == 2
    assert audit["matched_anchor_fraction"] == 1.0
    result = json.loads((tmp_path / "correspondences.json").read_text())
    assert len(result["points"]) == 2
    assert all(p["joint_name"] == "leftWrist" for p in result["points"])
    assert all(len(p["observations"]) == 2 for p in result["points"])
    assert result["points"][1]["observations"]["cam-b"]["source_frame_sequence"] == 3
    geometry = triangulate_multiview(
        tmp_path / "rig.json",
        tmp_path / "correspondences.json",
        tmp_path / "geometry.json",
    )
    assert geometry["point_count"] == 2
    for point in geometry["points"]:
        assert point["world_position_m"] == pytest.approx([0, 0.1, 5], abs=0.00001)
    assert paths["cam-a_movie"].exists()


def _update_track(spec_path: Path, camera_id: str, modifier) -> None:
    spec = json.loads(spec_path.read_text())
    entry = next(v for v in spec["camera_tracks"] if v["camera_id"] == camera_id)
    path = Path(entry["track"]["path"])
    value = json.loads(path.read_text())
    modifier(value)
    _write(path, value)
    entry["track"]["sha256"] = sha256_file(path)
    _write(spec_path, spec)


def test_wrong_camera_session_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    _update_track(spec, "cam-a", lambda t: t.update(session_id="unrelated-session"))
    with pytest.raises(ValueError, match="camera/session mismatch"):
        _run(spec, tmp_path)


def test_tampered_original_source_rejected(tmp_path: Path) -> None:
    spec, paths = _dataset(tmp_path)
    paths["cam-a_movie"].write_bytes(b"replacement clip")
    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        _run(spec, tmp_path)


def test_unsupported_orientation_fails_closed(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    _update_track(spec, "cam-a", lambda t: t.update(coordinate_frame="unknown"))
    with pytest.raises(ValueError, match="explicit supported oriented"):
        _run(spec, tmp_path)


def test_no_phantom_frame_sequence_for_action4_native_track(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    def remove_frame_sequence(track):
        for frame in track["frames"]:
            del frame["source_frame_sequence"]
    _update_track(spec, "cam-b", remove_frame_sequence)
    with pytest.raises(ValueError, match="source_frame_sequence"):
        _run(spec, tmp_path)


def test_low_confidence_joint_filtered_and_gated(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    def low_confidence(track):
        for frame in track["frames"]:
            frame["joints"][0]["confidence"] = 0.10
    _update_track(spec, "cam-b", low_confidence)
    with pytest.raises(ValueError, match="insufficient time-matched"):
        _run(spec, tmp_path)
    assert not (tmp_path / "correspondences.json").exists()


def test_outside_clock_support_does_not_extrapolate(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    def shift_time(track):
        for frame in track["frames"]:
            frame["source_frame_pts_ns"] += 3_000_000_000
    _update_track(spec, "cam-b", shift_time)
    with pytest.raises(ValueError, match="insufficient time-matched"):
        _run(spec, tmp_path)


def test_mismatched_person_identity_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    _update_track(spec, "cam-b", lambda t: t["frames"][0].update(subject_id="another"))
    with pytest.raises(ValueError, match="unverified or different person"):
        _run(spec, tmp_path)


def test_unconfirmed_cross_view_identity_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    value = json.loads(spec.read_text())
    value["operator_confirmed_single_person_identity"] = False
    _write(spec, value)
    with pytest.raises(ValueError, match="operator confirmation"):
        _run(spec, tmp_path)


def test_nonpassing_camera_rig_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    raw = json.loads((tmp_path / "rig.json").read_text())
    raw["passed"] = False
    rig_path = tmp_path / "rig.json"
    _write(rig_path, raw)
    value = json.loads(spec.read_text())
    value["rig_receipt"]["sha256"] = sha256_file(rig_path)
    _write(spec, value)
    with pytest.raises(ValueError, match="passing calibrated camera rig"):
        _run(spec, tmp_path)


def test_reused_nonmonotonic_source_frames_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    _update_track(
        spec,
        "cam-a",
        lambda t: t["frames"][1].update(source_frame_sequence=0),
    )
    with pytest.raises(ValueError, match="non-monotonic source frames"):
        _run(spec, tmp_path)


def test_missing_joint_poses_do_not_repeat_across_frames(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    def occlude(track):
        track["frames"][1]["joints"] = []
    _update_track(spec, "cam-b", occlude)
    with pytest.raises(ValueError, match="insufficient time-matched"):
        _run(spec, tmp_path)


def test_unqualified_output_cannot_overwrite_evidence(tmp_path: Path) -> None:
    spec, paths = _dataset(tmp_path)
    with pytest.raises(ValueError, match="overwrite immutable"):
        build_multiview_pose_correspondences(spec, paths["cam-a_track"])


def test_ambiguous_nearest_sample_rejected(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)
    # Arrange two target frames equidistant from the anchor (5ms either side)
    # within the rig's 10ms threshold. The anchor has two frames 100ms apart.
    def shift(track):
        track["frames"][0]["source_frame_pts_ns"] = 995_000_000
        track["frames"][1]["source_frame_pts_ns"] = 1_005_000_000
    _update_track(spec, "cam-b", shift)
    value = json.loads(spec.read_text())
    value["min_matched_points"] = 1
    value["min_matched_anchor_fraction"] = 0.5
    _write(spec, value)
    with pytest.raises(ValueError, match="insufficient time-matched"):
        _run(spec, tmp_path)


def test_unqualified_anchor_frames_count_against_coverage(tmp_path: Path) -> None:
    spec, _ = _dataset(tmp_path)

    def push_one_frame_past_clock_support(track):
        track["frames"][1]["source_frame_pts_ns"] = 2_100_000_000

    _update_track(spec, "cam-a", push_one_frame_past_clock_support)
    with pytest.raises(ValueError, match="insufficient time-matched"):
        _run(spec, tmp_path)
    assert not (tmp_path / "correspondences.json").exists()
