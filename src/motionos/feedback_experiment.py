from __future__ import annotations

import random
import statistics
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class FeedbackSessionResult:
    session_id: str
    condition: str
    metrics: dict[str, float]

    def __post_init__(self) -> None:
        if self.condition not in {
            "feedback_disabled",
            "feedback_enabled",
        }:
            raise ValueError("unsupported feedback condition")


def generate_balanced_feedback_schedule(
    session_count: int,
    *,
    seed: int,
) -> tuple[str, ...]:
    if session_count <= 0:
        raise ValueError("session_count must be positive")

    rng = random.Random(seed)
    schedule: list[str] = []
    while len(schedule) < session_count:
        block = ["feedback_disabled", "feedback_enabled"]
        rng.shuffle(block)
        schedule.extend(block)
    return tuple(schedule[:session_count])


def compare_feedback_conditions(
    sessions: Iterable[FeedbackSessionResult],
) -> dict[str, object]:
    items = tuple(sessions)
    if not items:
        raise ValueError("at least one feedback session is required")
    if len({item.session_id for item in items}) != len(items):
        raise ValueError("feedback comparison session IDs must be unique")

    by_condition = {
        "feedback_disabled": [
            item for item in items
            if item.condition == "feedback_disabled"
        ],
        "feedback_enabled": [
            item for item in items
            if item.condition == "feedback_enabled"
        ],
    }
    metric_ids = sorted(
        set().union(*(item.metrics.keys() for item in items))
    )

    metric_results: dict[str, object] = {}
    for metric_id in metric_ids:
        disabled = [
            item.metrics[metric_id]
            for item in by_condition["feedback_disabled"]
            if metric_id in item.metrics
        ]
        enabled = [
            item.metrics[metric_id]
            for item in by_condition["feedback_enabled"]
            if metric_id in item.metrics
        ]

        metric_results[metric_id] = {
            "feedback_disabled": _summary(disabled),
            "feedback_enabled": _summary(enabled),
            "enabled_minus_disabled_mean": (
                statistics.mean(enabled) - statistics.mean(disabled)
                if enabled and disabled
                else None
            ),
            "enabled_minus_disabled_median": (
                statistics.median(enabled) - statistics.median(disabled)
                if enabled and disabled
                else None
            ),
        }

    return {
        "schema_version": "motionos.feedback-comparison.v1",
        "session_count": len(items),
        "condition_counts": {
            condition: len(values)
            for condition, values in by_condition.items()
        },
        "metrics": metric_results,
        "claim_boundary": (
            "Condition deltas are descriptive within-athlete observations. "
            "They are not causal estimates unless the collection protocol "
            "independently supports that interpretation."
        ),
    }


def _summary(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "sample_std": None,
        }
    return {
        "count": len(values),
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "sample_std": (
            statistics.stdev(values)
            if len(values) > 1
            else None
        ),
    }
