import json

import pytest

from motionos.indo_rest_pilot import build_indo_rest_pilot_report


def _bout(bout_id, phase, start, value, *, setup="tripod-a", stance="natural", conf=0.95,
          verified=True, tracking="board_roller"):
    return {
        "bout_id": bout_id,
        "phase": phase,
        "start_s": start,
        "end_s": start + 10,
        "context": {
            "skill_id": "neutral_balance_hold",
            "setup_id": setup,
            "stance_id": stance,
            "tracking_mode": tracking,
        },
        "source_verified": verified,
        "source_digest_sha256": "a" * 64,
        "metrics": {
            "center_time_fraction": value,
            "roller_excursion_p90": 1 - value,
        },
        "confidence": {
            "center_time_fraction": conf,
            "roller_excursion_p90": conf,
        },
        "effort_0_10": 4 if phase == "reference" else 7,
    }


def _run(bouts):
    return build_indo_rest_pilot_report(session_id="synthetic-001", bouts=bouts)


def test_median_changes_and_post_rest_are_descriptive_only():
    bouts = [
        _bout("a", "reference", 0, 0.80),
        _bout("b", "reference", 15, 0.84),
        _bout("c", "late", 30, 0.53),
        _bout("d", "late", 45, 0.55),
        _bout("e", "post_rest", 90, 0.70),
        _bout("f", "post_rest", 105, 0.74),
    ]
    report = _run(bouts)
    assert report["status"] == "descriptive_only"
    metrics = report["comparisons"][0]["metrics"]["center_time_fraction"]
    assert metrics["late_minus_reference"] == pytest.approx(-0.28)
    assert metrics["post_rest_minus_late"] == pytest.approx(0.18)
    assert report["comparisons"][0]["interpretation"] == (
        "descriptive_only_not_a_fatigue_diagnosis"
    )
    json.dumps(report)


def test_asymmetric_stances_never_pooled():
    bouts = [
        _bout("a", "reference", 0, 0.8, stance="natural"),
        _bout("b", "reference", 15, 0.8, stance="natural"),
        _bout("c", "late", 30, 0.5, stance="switch"),
        _bout("d", "late", 45, 0.5, stance="switch"),
    ]
    assert _run(bouts)["status"] == "insufficient_comparable_evidence"


def test_camera_setup_changes_not_pooled():
    bouts = [_bout("a", "reference", 0, .8), _bout("b", "reference", 15, .8),
             _bout("c", "late", 30, .5, setup="tripod-b"),
             _bout("d", "late", 45, .5, setup="tripod-b")]
    assert _run(bouts)["comparisons"] == []


def test_missing_evidence_or_low_quality_cannot_create_comparison():
    bouts = [_bout("a", "reference", 0, .8), _bout("b", "reference", 15, .8),
             _bout("c", "late", 30, .5, verified=False),
             _bout("d", "late", 45, .5, conf=.2)]
    report = _run(bouts)
    assert report["status"] == "insufficient_comparable_evidence"
    assert {item["reason"] for item in report["excluded_bouts"]} == {
        "source_not_verified", "no_qualified_board_metrics"
    }


def test_body_only_mode_has_no_equipment_claim():
    bouts = [_bout(str(i), "reference" if i < 2 else "late", i * 15, .8,
                   tracking="body_only") for i in range(4)]
    report = _run(bouts)
    assert report["comparisons"] == []
    assert len(report["excluded_bouts"]) == 4


@pytest.mark.parametrize("mutation", [
    lambda x: x.append(dict(x[0])),
    lambda x: x[1].update(start_s=5),
    lambda x: x[1].update(effort_0_10=11),
    lambda x: x[1].update(end_s=15),
])
def test_invalid_inputs_rejected(mutation):
    bouts = [_bout("a", "reference", 0, .8), _bout("b", "late", 15, .5)]
    mutation(bouts)
    with pytest.raises(ValueError):
        _run(bouts)
