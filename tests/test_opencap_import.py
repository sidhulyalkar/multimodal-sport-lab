"""Synthetic parser tests. These do not validate biomechanics."""
from __future__ import annotations

import json

import pytest

from motionos.opencap_import import (
    SCHEMA_VERSION,
    build_simulation_artifact,
    read_storage_table,
    write_simulation_artifact,
)


def _mot(tmp_path, rows=None, header=""):
    path = tmp_path / "kinematics_activations_squat_0.mot"
    if rows is None:
        rows = ["0.0 12.0 0.2 0.6", "0.1 16.0 0.3 0.7"]
    path.write_text(
        "synthetic_fixture\n" + header + "inDegrees=yes\n"
        + "nRows=" + str(len(rows)) + "\nnColumns=4\nendheader\n"
        + "time knee_angle_r vasmed_r/activation glmax1_l/activation\n"
        + "\n".join(rows) + "\n",
        encoding="utf-8",
    )
    return path


def test_import_preserves_model_semantics_and_source_hash(tmp_path):
    source = _mot(tmp_path)
    artifact = build_simulation_artifact(
        source, model_name="LaiUhlrich2022", trial_name="squat"
    )
    assert artifact["schema_version"] == SCHEMA_VERSION
    assert artifact["evidence_kind"] == "model_inferred"
    assert artifact["channels"]["rotation_units"] == "degrees"
    assert artifact["channels"]["estimated_activations"] == [
        "vasmed_r", "glmax1_l"
    ]
    assert artifact["frames"][1]["estimated_activations"]["glmax1_l"] == 0.7
    assert artifact["source"]["solver_convergence_verified"] is False
    assert artifact["source"]["muscle_channel_identity_verified"] is False
    assert len(artifact["source"]["table_sha256"]) == 64


def test_writer_preserves_inputs_and_refuses_overwrite(tmp_path):
    source = _mot(tmp_path)
    original = source.read_bytes()
    target = tmp_path / "derived.json"
    write_simulation_artifact(
        source, target, model_name="Demo", trial_name="squat"
    )
    assert json.loads(target.read_text())["frames"]
    assert source.read_bytes() == original
    with pytest.raises(FileExistsError):
        write_simulation_artifact(
            source, target, model_name="Demo", trial_name="squat"
        )
    with pytest.raises(ValueError):
        write_simulation_artifact(
            source, source, model_name="Demo", trial_name="squat"
        )


@pytest.mark.parametrize("rows", [
    ["0.0 1 0.2 0.1", "0.0 2 0.2 0.1"],
    ["0.1 1 0.2 0.1", "0.0 2 0.2 0.1"],
    ["0.0 1 0.2 nan", "0.1 2 0.2 0.1"],
    ["0.0 1 0.2 0.1", "0.1 2 0.2"],
])
def test_bad_time_nonfinite_malformed_rows_fail_closed(tmp_path, rows):
    source = _mot(tmp_path, rows=rows)
    with pytest.raises(ValueError):
        read_storage_table(source)


@pytest.mark.parametrize("value", ["-0.1", "1.01"])
def test_out_of_bounds_simulated_activation_rejected(tmp_path, value):
    source = _mot(
        tmp_path, rows=["0.0 1 0.2 0.1", f"0.1 2 {value} 0.1"]
    )
    with pytest.raises(ValueError, match="activation"):
        build_simulation_artifact(
            source, model_name="Demo", trial_name="squat"
        )


def test_mismatched_header_shape_rejected(tmp_path):
    source = _mot(tmp_path, header="nColumns=3\n")
    with pytest.raises(ValueError):
        read_storage_table(source)


def test_model_file_fingerprinted(tmp_path):
    source = _mot(tmp_path)
    model = tmp_path / "scaled.osim"
    model.write_text("<OpenSimDocument/>")
    artifact = build_simulation_artifact(
        source, model_name="Custom", trial_name="squat", model_path=model
    )
    assert len(artifact["source"]["model_file"]["sha256"]) == 64


def test_model_and_trial_identity_required(tmp_path):
    with pytest.raises(ValueError):
        build_simulation_artifact(
            _mot(tmp_path), model_name="", trial_name="squat"
        )
