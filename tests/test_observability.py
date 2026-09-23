import json

import pytest

from motionos.observability import load_observability_registry


def _registry():
    return {
        "schema_version": "motionos.observability-registry.v1",
        "registry_id": "test-longboard",
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
                "non_claims": ["not absolute orientation"],
            },
            {
                "variable_id": "joint_torque",
                "label": "joint torque",
                "units": "N*m",
                "coordinate_frame": "anatomical",
                "observability": "unidentifiable",
                "teacher_eligible": False,
                "directly_observed_by": [],
                "indirectly_observed_by": ["video"],
                "required_transforms": [],
                "reference_sources": [],
                "known_ambiguities": ["insufficient force constraints"],
                "non_claims": ["not a MotionOS M1 target"],
            },
        ],
        "notes": [],
    }


def test_load_observability_registry_preserves_non_claims(tmp_path):
    path = tmp_path / "registry.json"
    path.write_text(json.dumps(_registry()), encoding="utf-8")

    registry = load_observability_registry(path)

    assert registry.registry_id == "test-longboard"
    assert registry.by_id()["board_rate"].teacher_eligible is True
    assert registry.by_id()["joint_torque"].observability == "unidentifiable"
    assert "not a MotionOS M1 target" in (
        registry.by_id()["joint_torque"].non_claims
    )


def test_unidentifiable_variable_cannot_be_teacher_target(tmp_path):
    raw = _registry()
    raw["variables"][1]["teacher_eligible"] = True
    path = tmp_path / "registry.json"
    path.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="cannot be teacher_eligible"):
        load_observability_registry(path)


def test_direct_and_indirect_modalities_cannot_overlap(tmp_path):
    raw = _registry()
    raw["variables"][0]["indirectly_observed_by"] = ["pod_gyro"]
    path = tmp_path / "registry.json"
    path.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(ValueError, match="both direct and indirect"):
        load_observability_registry(path)
