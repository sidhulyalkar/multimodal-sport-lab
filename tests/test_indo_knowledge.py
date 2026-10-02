import json

import pytest

from motionos.indo_knowledge import (
    build_session_learning_targets,
    classify_observable_skills,
    cold_start_plan,
    generate_coaching_suggestions,
    load_indo_skill_taxonomy,
    validate_indo_skill_taxonomy,
)


def _taxonomy(tmp_path):
    source = "configs/indo_skill_taxonomy.v1.json"
    with open(source, encoding="utf-8") as handle:
        payload = json.load(handle)
    path = tmp_path / "taxonomy.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return load_indo_skill_taxonomy(path)


def test_cold_start_plan_works_with_body_pose_only(tmp_path):
    taxonomy = _taxonomy(tmp_path)

    plan = cold_start_plan(
        taxonomy,
        available_channels={"body_pose_2d", "body_pose_3d"},
    )

    assert [item["skill_id"] for item in plan] == [
        "neutral_balance_hold",
        "controlled_side_shift",
        "partial_squat_hold",
        "neutral_balance_hold",
    ]


def test_observability_improves_with_board_and_roller(tmp_path):
    taxonomy = _taxonomy(tmp_path)

    body_only = classify_observable_skills(
        taxonomy,
        {"body_pose_2d", "body_pose_3d"},
    )
    full = classify_observable_skills(
        taxonomy,
        {
            "body_pose_2d",
            "body_pose_3d",
            "board_pose",
            "roller_state",
            "watch_imu",
            "video_event",
        },
    )

    assert len(full["ready"]) > len(body_only["ready"])
    assert "section_balancing" in body_only["blocked"]
    assert "section_balancing" in full["ready"]


def test_coaching_suggestions_fire_on_late_overcorrection(tmp_path):
    taxonomy = _taxonomy(tmp_path)

    suggestions = generate_coaching_suggestions(
        taxonomy,
        {
            "recovery_time_ms": 910,
            "overshoot_ratio": 0.52,
            "secondary_correction_count": 2.3,
        },
        metric_confidence={
            "recovery_time_ms": 0.9,
            "overshoot_ratio": 0.8,
            "secondary_correction_count": 0.85,
        },
        max_suggestions=3,
    )

    rule_ids = {item.rule_id for item in suggestions}
    assert "late_large_corrections" in rule_ids
    assert "secondary_overcorrection" in rule_ids
    assert all(0 <= item.confidence <= 1 for item in suggestions)


def test_learning_targets_use_prerequisites_not_session_count(tmp_path):
    taxonomy = _taxonomy(tmp_path)

    targets = build_session_learning_targets(
        taxonomy,
        completed_skill_ids={"neutral_balance_hold"},
        available_channels={"body_pose_2d", "body_pose_3d"},
        limit=10,
    )

    ids = {item["skill_id"] for item in targets}
    assert "controlled_side_shift" in ids
    assert "partial_squat_hold" in ids
    assert "cross_step" not in ids


def test_taxonomy_rejects_unknown_provenance_source(tmp_path):
    taxonomy = _taxonomy(tmp_path)
    taxonomy["skills"][0]["source_ids"].append("missing-source")

    with pytest.raises(ValueError, match="unknown source_id"):
        validate_indo_skill_taxonomy(taxonomy)
