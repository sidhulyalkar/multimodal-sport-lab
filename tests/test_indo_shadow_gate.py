import json

import pytest

from motionos.indo_shadow_gate import (
    assess_markerless_shadow_gate,
)


def _evaluation():
    return {
        "schema_version":
            "motionos.indo-shadow-equipment-eval.v1",
        "groups": [
            {
                "reference_detector_id": "vision_qr",
                "candidate_detector_id": "markerless",
                "candidate_model_id": "indo-equipment-v1",
                "comparison_count": 120,
                "metrics": {
                    "roller_center_error_p90": 0.03,
                    "roller_along_reference_deck_abs_error_p90":
                        0.05,
                    "center_zone_agreement_fraction": 0.96,
                    "edge_zone_agreement_fraction": 0.94,
                },
            }
        ],
        "detector_execution_groups": [
            {
                "detector_id": "markerless",
                "execution_count": 140,
                "observation_fraction": 0.93,
                "error_fraction": 0.01,
                "duration_ms_mean": 18.0,
                "duration_ms_p90": 27.0,
            }
        ],
    }


def _spec():
    return {
        "schema_version":
            "motionos.indo-markerless-shadow-gate-spec.v1",
        "model_id": "indo-equipment-v1",
        "candidate_detector_id": "markerless",
        "reference_detector_id": "vision_qr",
        "thresholds": {
            "minimum_comparison_count": 100,
            "maximum_roller_center_error_p90": 0.04,
            "maximum_roller_along_reference_deck_abs_error_p90":
                0.07,
            "minimum_center_zone_agreement_fraction": 0.95,
            "minimum_edge_zone_agreement_fraction": 0.90,
            "minimum_detector_observation_fraction": 0.90,
            "maximum_detector_error_fraction": 0.02,
            "maximum_detector_duration_ms_p90": 50.0,
        },
    }


def test_shadow_gate_passes_without_authorizing_model(
    tmp_path,
):
    evaluation = tmp_path / "evaluation.json"
    spec = tmp_path / "gate.json"
    output = tmp_path / "report.json"
    evaluation.write_text(
        json.dumps(_evaluation()),
        encoding="utf-8",
    )
    spec.write_text(
        json.dumps(_spec()),
        encoding="utf-8",
    )

    report = assess_markerless_shadow_gate(
        evaluation,
        spec,
        output,
    )

    assert report["passed"] is True
    assert report["authorization_effect"] == "none"
    assert all(
        criterion["passed"]
        for criterion in report["criteria"]
    )
    assert output.is_file()


def test_shadow_gate_reports_failed_criterion(tmp_path):
    evaluation_payload = _evaluation()
    evaluation_payload["groups"][0]["metrics"][
        "roller_center_error_p90"
    ] = 0.08

    evaluation = tmp_path / "evaluation.json"
    spec = tmp_path / "gate.json"
    evaluation.write_text(
        json.dumps(evaluation_payload),
        encoding="utf-8",
    )
    spec.write_text(
        json.dumps(_spec()),
        encoding="utf-8",
    )

    report = assess_markerless_shadow_gate(
        evaluation,
        spec,
    )

    assert report["passed"] is False
    failed = [
        criterion["criterion"]
        for criterion in report["criteria"]
        if not criterion["passed"]
    ]
    assert failed == [
        "maximum_roller_center_error_p90"
    ]


def test_shadow_gate_requires_all_explicit_thresholds(
    tmp_path,
):
    spec_payload = _spec()
    del spec_payload["thresholds"][
        "maximum_detector_duration_ms_p90"
    ]
    evaluation = tmp_path / "evaluation.json"
    spec = tmp_path / "gate.json"
    evaluation.write_text(
        json.dumps(_evaluation()),
        encoding="utf-8",
    )
    spec.write_text(
        json.dumps(spec_payload),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="missing shadow gate thresholds",
    ):
        assess_markerless_shadow_gate(
            evaluation,
            spec,
        )


def test_shadow_gate_rejects_ambiguous_model_groups(
    tmp_path,
):
    evaluation_payload = _evaluation()
    evaluation_payload["groups"].append(
        dict(evaluation_payload["groups"][0])
    )
    evaluation = tmp_path / "evaluation.json"
    spec = tmp_path / "gate.json"
    evaluation.write_text(
        json.dumps(evaluation_payload),
        encoding="utf-8",
    )
    spec.write_text(
        json.dumps(_spec()),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="exactly one matching",
    ):
        assess_markerless_shadow_gate(
            evaluation,
            spec,
        )
