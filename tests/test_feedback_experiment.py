import pytest

from motionos.feedback_experiment import (
    FeedbackSessionResult,
    compare_feedback_conditions,
    generate_balanced_feedback_schedule,
)


def test_feedback_schedule_is_balanced_and_reproducible():
    first = generate_balanced_feedback_schedule(7, seed=42)
    second = generate_balanced_feedback_schedule(7, seed=42)

    assert first == second
    assert abs(
        first.count("feedback_enabled")
        - first.count("feedback_disabled")
    ) <= 1


def test_feedback_comparison_reports_descriptive_delta():
    result = compare_feedback_conditions(
        [
            FeedbackSessionResult(
                session_id="off-1",
                condition="feedback_disabled",
                metrics={"recovery_latency_s": 0.6},
            ),
            FeedbackSessionResult(
                session_id="off-2",
                condition="feedback_disabled",
                metrics={"recovery_latency_s": 0.5},
            ),
            FeedbackSessionResult(
                session_id="on-1",
                condition="feedback_enabled",
                metrics={"recovery_latency_s": 0.4},
            ),
            FeedbackSessionResult(
                session_id="on-2",
                condition="feedback_enabled",
                metrics={"recovery_latency_s": 0.3},
            ),
        ]
    )

    metric = result["metrics"]["recovery_latency_s"]
    assert metric["enabled_minus_disabled_mean"] == pytest.approx(-0.2)
    assert result["condition_counts"] == {
        "feedback_disabled": 2,
        "feedback_enabled": 2,
    }
    assert "not causal estimates" in result["claim_boundary"]
