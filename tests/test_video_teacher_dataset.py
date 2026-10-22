import json
from pathlib import Path

import pytest

from motionos.cli import main
from motionos.experiments import build_grouped_split, verify_grouped_split
from motionos.video_teacher_dataset import (
    build_video_teacher_index,
    verify_video_teacher_index,
)


def _spec(tmp_path, *, subjects=("p-abc12345",), measured=True):
    registry = json.loads(
        (Path(__file__).resolve().parents[1] / "examples"
         / "longboard-observability.example.json").read_text(encoding="utf-8")
    )
    registry["sport"] = "indo_board"
    (tmp_path / "registry.json").write_text(json.dumps(registry), encoding="utf-8")
    captures = []
    for i, subject_id in enumerate(subjects):
        (tmp_path / f"video-{i}.mp4").write_bytes(f"test-video-{i}".encode())
        (tmp_path / f"pressure-{i}.jsonl").write_text("{}", encoding="utf-8")
        (tmp_path / f"sync-{i}.json").write_text(
            json.dumps({"status": "unqualified_test_fixture"}), encoding="utf-8"
        )
        captures.append({
            "sample_id": f"example-{i}",
            "subject_id": subject_id,
            "run_id": f"run-{i}",
            "day_id": f"day-{i}",
            "remount_id": f"mount-{i}",
            "camera_view": "side",
            "sport": "indo_board",
            "task_id": "free-balance",
            "protocol_version": "motionos.indo-board-product-session.v2",
            "consent": {
                "training_and_evaluation": True,
                "consent_reference": f"private-consent-{i}",
            },
            "video": f"video-{i}.mp4",
            "labels": ([{
                "target_id": "left_load_fraction",
                "kind": "sensor_measured",
                "modality": "bilateral_pressure",
                "time_axis": "reference_ns",
                "path": f"pressure-{i}.jsonl",
                "alignment_receipt": f"sync-{i}.json",
            }] if measured else []),
        })
    spec = tmp_path / "video-teacher-spec.json"
    spec.write_text(json.dumps({
        "schema_version": "motionos.video-teacher-spec.v1",
        "dataset_id": "indo-teacher-pilot",
        "observability_registry": "registry.json",
        "captures": captures,
    }), encoding="utf-8")
    return spec


def test_build_and_verify_measured_candidates_do_not_claim_ground_truth(tmp_path):
    spec = _spec(tmp_path)
    target = tmp_path / "private" / "candidate-index.json"
    index = build_video_teacher_index(spec, target)
    assert index["sample_count"] == 1
    assert index["training_ready"] is False
    assert index["measured_candidate_count"] == 1
    label = index["samples"][0]["labels"][0]
    assert label["teacher_eligibility"] == "candidate_requires_physical_sync_review"
    assert not Path(label["source"]["path"]).is_absolute()
    assert (target.parent / label["source"]["path"]).is_file()
    assert verify_video_teacher_index(target)["passed"] is True


def test_video_only_data_has_no_invented_teacher_labels(tmp_path):
    spec = _spec(tmp_path, measured=False)
    index = build_video_teacher_index(spec, tmp_path / "index.json")
    assert index["measured_candidate_count"] == 0
    assert index["samples"][0]["candidate_status"] == "video_only_or_weak_labels"
    assert index["samples"][0]["labels"] == []


def test_mutating_video_invalidates_existing_index(tmp_path):
    spec = _spec(tmp_path)
    out = tmp_path / "index.json"
    build_video_teacher_index(spec, out)
    (tmp_path / "video-0.mp4").write_bytes(b"changed video")
    with pytest.raises(ValueError, match="differs"):
        verify_video_teacher_index(out)


def test_mutating_alignment_receipt_invalidates_existing_index(tmp_path):
    spec = _spec(tmp_path)
    out = tmp_path / "index.json"
    build_video_teacher_index(spec, out)
    (tmp_path / "sync-0.json").write_text('{"altered": true}', encoding="utf-8")
    with pytest.raises(ValueError, match="differs"):
        verify_video_teacher_index(out)


def test_training_requires_explicit_authorization(tmp_path):
    spec = _spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["captures"][0]["consent"]["training_and_evaluation"] = False
    spec.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(ValueError, match="authorization"):
        build_video_teacher_index(spec, tmp_path / "index.json")


def test_measured_teacher_needs_independent_modality_and_alignment(tmp_path):
    spec = _spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["captures"][0]["labels"][0]["modality"] = "calibrated_video_pose"
    spec.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(ValueError, match="independent measured reference"):
        build_video_teacher_index(spec, tmp_path / "index.json")

    raw["captures"][0]["labels"][0]["modality"] = "bilateral_pressure"
    raw["captures"][0]["labels"][0].pop("alignment_receipt")
    spec.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(ValueError, match="time-alignment receipt"):
        build_video_teacher_index(spec, tmp_path / "index.json")


def test_unidentifiable_registry_target_cannot_be_promoted_to_teacher(tmp_path):
    spec = _spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["captures"][0]["labels"][0]["target_id"] = "full_3d_ground_reaction_force"
    spec.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(ValueError, match="cannot be a supervised teacher"):
        build_video_teacher_index(spec, tmp_path / "index.json")


def test_duplicate_samples_rejected(tmp_path):
    spec = _spec(tmp_path)
    raw = json.loads(spec.read_text(encoding="utf-8"))
    raw["captures"].append(dict(raw["captures"][0]))
    spec.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate sample_id"):
        build_video_teacher_index(spec, tmp_path / "index.json")


def test_cli_and_participant_held_out_split(tmp_path, capsys):
    spec = _spec(
        tmp_path,
        subjects=("p-aaa11111", "p-bbb22222", "p-ccc33333"),
    )
    index = tmp_path / "index.json"
    assert main(["build-video-teacher-index", str(spec), str(index)]) == 0
    assert main(["verify-video-teacher-index", str(index)]) == 0
    split = tmp_path / "split.json"
    built = build_grouped_split(
        index, split, group_by=("subject_id",), seed="video-teacher-pilot"
    )
    assert built.leakage_check_passed is True
    assert built.group_count == 3
    assert verify_grouped_split(split, index)["passed"] is True
