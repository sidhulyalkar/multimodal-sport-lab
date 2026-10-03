import hashlib
import json

import pytest

from motionos.indo_model_qualification import (
    build_equipment_model_qualification_registry,
)


def _evaluation():
    return {
        "schema_version":
            "motionos.indo-runtime-equipment-eval.v1",
        "reference_count": 100,
        "prediction_count": 98,
        "matched_count": 96,
        "reference_coverage_fraction": 0.96,
        "metrics": {
            "roller_center_error_p90": 0.035,
            "deck_endpoint_mean_error_p90": 0.028,
            "center_zone_correct_fraction": 0.94,
        },
    }


def test_builds_swift_compatible_evaluation_only_registry(
    tmp_path,
):
    evaluation_path = tmp_path / "evaluation.json"
    evaluation_path.write_text(
        json.dumps(_evaluation(), sort_keys=True),
        encoding="utf-8",
    )
    output = tmp_path / "qualification.json"

    registry = build_equipment_model_qualification_registry(
        evaluation_path,
        output,
        model_id="indo-equipment-v1",
    )

    qualification = registry["qualifications"][0]
    assert (
        registry["schema_version"]
        == "motionos.indo-equipment-model-qualification-registry.v1"
    )
    assert qualification["model_id"] == "indo-equipment-v1"
    assert qualification["status"] == "evaluation_only"
    assert qualification["authorization_note"] is None
    assert (
        qualification["metrics"][
            "reference_coverage_fraction"
        ]
        == 0.96
    )
    assert qualification["metrics"]["matched_count"] == 96

    expected_hash = hashlib.sha256(
        evaluation_path.read_bytes()
    ).hexdigest()
    assert (
        qualification["evaluation_report_sha256"]
        == expected_hash
    )
    assert output.is_file()


def test_runtime_authorization_requires_explicit_note(
    tmp_path,
):
    evaluation_path = tmp_path / "evaluation.json"
    evaluation_path.write_text(
        json.dumps(_evaluation()),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="authorization_note",
    ):
        build_equipment_model_qualification_registry(
            evaluation_path,
            tmp_path / "qualification.json",
            model_id="indo-equipment-v1",
            status="qualified_for_beta_tracking",
        )


def test_runtime_authorization_preserves_human_note(
    tmp_path,
):
    evaluation_path = tmp_path / "evaluation.json"
    evaluation_path.write_text(
        json.dumps(_evaluation()),
        encoding="utf-8",
    )

    registry = build_equipment_model_qualification_registry(
        evaluation_path,
        tmp_path / "qualification.json",
        model_id="indo-equipment-v1",
        status="qualified_for_beta_coaching",
        evaluation_dataset_id="indo-heldout-2026-10",
        authorization_note=(
            "Approved after held-out geometry and physical beta review."
        ),
    )

    qualification = registry["qualifications"][0]
    assert (
        qualification["status"]
        == "qualified_for_beta_coaching"
    )
    assert (
        qualification["evaluation_dataset_id"]
        == "indo-heldout-2026-10"
    )
    assert "physical beta" in (
        qualification["authorization_note"]
    )


def test_unsupported_evaluation_schema_fails_closed(
    tmp_path,
):
    evaluation_path = tmp_path / "evaluation.json"
    evaluation_path.write_text(
        json.dumps(
            {
                "schema_version": "unknown",
                "metrics": {},
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="unsupported",
    ):
        build_equipment_model_qualification_registry(
            evaluation_path,
            tmp_path / "qualification.json",
            model_id="indo-equipment-v1",
        )
