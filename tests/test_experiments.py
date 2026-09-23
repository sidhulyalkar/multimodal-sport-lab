import json

import pytest

from motionos.experiments import (
    build_experiment_manifest,
    build_grouped_split,
)
from motionos.provenance import session_evidence_sha256, sha256_file
from motionos.session import SessionReader
from motionos.simulate import simulate_session


def _write_registry(path):
    path.write_text(
        json.dumps(
            {
                "schema_version": "motionos.observability-registry.v1",
                "registry_id": "registry-1",
                "sport": "longboard",
                "variables": [
                    {
                        "variable_id": "board_rate",
                        "label": "board angular velocity",
                        "units": "rad/s",
                        "coordinate_frame": "equipment",
                        "observability": "observable",
                        "teacher_eligible": True,
                        "directly_observed_by": ["pod_gyro"],
                        "indirectly_observed_by": ["video"],
                        "required_transforms": ["sensor_to_equipment"],
                        "reference_sources": ["pod_gyro"],
                        "known_ambiguities": [],
                        "non_claims": [],
                    },
                    {
                        "variable_id": "torque",
                        "label": "joint torque",
                        "units": "N*m",
                        "coordinate_frame": "anatomical",
                        "observability": "unidentifiable",
                        "teacher_eligible": False,
                        "directly_observed_by": [],
                        "indirectly_observed_by": ["video"],
                        "required_transforms": [],
                        "reference_sources": [],
                        "known_ambiguities": ["insufficient constraints"],
                        "non_claims": ["not estimated"],
                    },
                ],
                "notes": [],
            }
        ),
        encoding="utf-8",
    )


def test_experiment_manifest_binds_registry_session_and_artifact(tmp_path):
    registry = tmp_path / "registry.json"
    _write_registry(registry)
    session = simulate_session(tmp_path / "data", duration_s=2.0)
    note = tmp_path / "notes.json"
    note.write_text('{"operator":"fixture"}\n', encoding="utf-8")

    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "schema_version": "motionos.experiment-spec.v1",
                "experiment_id": "exp-1",
                "sport": "longboard",
                "protocol_version": "motionos.longboard-calibration.v1",
                "repository_commit": "a" * 40,
                "observability_registry": "registry.json",
                "targets": ["board_rate"],
                "acquisition": {
                    "subject_id": "p001",
                    "day_id": "d1",
                    "run_id": "r1",
                    "remount_id": "m1",
                    "camera_view": "a",
                    "intensity": "slow",
                },
                "sources": [
                    {
                        "role": "session",
                        "kind": "motionos_session",
                        "source_type": "session",
                        "path": str(session),
                    },
                    {
                        "role": "notes",
                        "kind": "operator_notes",
                        "source_type": "artifact",
                        "path": "notes.json",
                    },
                ],
                "models": [],
                "notes": [],
            }
        ),
        encoding="utf-8",
    )

    output = tmp_path / "out" / "experiment.json"
    manifest = build_experiment_manifest(spec, output)

    source_by_role = {item.role: item for item in manifest.sources}
    assert manifest.targets == ("board_rate",)
    assert manifest.observability_registry_sha256 == sha256_file(registry)
    assert source_by_role["notes"].sha256 == sha256_file(note)
    assert source_by_role["session"].sha256 == session_evidence_sha256(
        SessionReader(session)
    )
    assert source_by_role["session"].session_id == (
        SessionReader(session).manifest.session_id
    )


def test_experiment_manifest_rejects_ineligible_target(tmp_path):
    registry = tmp_path / "registry.json"
    _write_registry(registry)
    artifact = tmp_path / "artifact.txt"
    artifact.write_text("fixture", encoding="utf-8")
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "experiment_id": "exp-1",
                "sport": "longboard",
                "protocol_version": "v1",
                "repository_commit": "a" * 40,
                "observability_registry": "registry.json",
                "targets": ["torque"],
                "acquisition": {
                    "subject_id": "p1",
                    "day_id": "d1",
                    "run_id": "r1",
                    "remount_id": "m1",
                },
                "sources": [
                    {
                        "role": "fixture",
                        "kind": "artifact",
                        "source_type": "artifact",
                        "path": "artifact.txt",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="not teacher-eligible"):
        build_experiment_manifest(spec, tmp_path / "out.json")


def _write_index(path):
    samples = []
    for day in range(1, 5):
        for repetition in range(2):
            samples.append(
                {
                    "sample_id": f"d{day}-rep{repetition}",
                    "day_id": f"d{day}",
                    "run_id": f"r{day}",
                    "remount_id": f"m{day}",
                    "repetition_id": f"rep{repetition}",
                }
            )
    path.write_text(json.dumps({"samples": samples}), encoding="utf-8")


def test_grouped_split_is_deterministic_and_run_leakage_safe(tmp_path):
    index = tmp_path / "index.json"
    _write_index(index)

    first = build_grouped_split(
        index,
        tmp_path / "split-a.json",
        group_by=("run_id",),
        seed="frozen-v1",
    )
    second = build_grouped_split(
        index,
        tmp_path / "split-b.json",
        group_by=("run_id",),
        seed="frozen-v1",
    )

    assert first.assignments == second.assignments
    assert first.group_assignments == second.group_assignments
    assert first.source_index_sha256 == sha256_file(index)
    assert first.leakage_check_passed is True

    sample_split = {
        sample_id: split
        for split, sample_ids in first.assignments.items()
        for sample_id in sample_ids
    }
    assert sample_split["d1-rep0"] == sample_split["d1-rep1"]
    assert sample_split["d2-rep0"] == sample_split["d2-rep1"]


def test_primary_split_rejects_window_only_grouping(tmp_path):
    index = tmp_path / "index.json"
    index.write_text(
        json.dumps(
            {
                "samples": [
                    {"sample_id": "a", "window_id": "w1"},
                    {"sample_id": "b", "window_id": "w2"},
                ]
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="acquisition-level"):
        build_grouped_split(
            index,
            tmp_path / "split.json",
            group_by=("window_id",),
            seed="frozen-v1",
            purpose="primary",
        )
