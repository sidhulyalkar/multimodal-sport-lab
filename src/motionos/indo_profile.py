from __future__ import annotations

import copy
import math
from typing import Any

PERSONAL_BALANCE_PROFILE_SCHEMA_VERSION = "motionos.personal-balance-profile.v1"


def new_personal_balance_profile(
    athlete_id: str = "local-athlete",
) -> dict[str, Any]:
    return {
        "schema_version": PERSONAL_BALANCE_PROFILE_SCHEMA_VERSION,
        "athlete_id": athlete_id,
        "skills": {},
        "cue_responses": {},
        "session_ids": [],
    }


def update_personal_balance_profile(
    profile: dict[str, Any],
    *,
    session_id: str,
    skill_id: str,
    metrics: dict[str, float],
    confidence: dict[str, float] | None = None,
) -> dict[str, Any]:
    _validate_profile(profile)
    if not session_id:
        raise ValueError("session_id must be non-empty")
    if not skill_id:
        raise ValueError("skill_id must be non-empty")

    result = copy.deepcopy(profile)
    if session_id not in result["session_ids"]:
        result["session_ids"].append(session_id)

    skills = result["skills"]
    skill = skills.setdefault(
        skill_id,
        {
            "session_ids": [],
            "metrics": {},
        },
    )
    if session_id not in skill["session_ids"]:
        skill["session_ids"].append(session_id)

    confidence = confidence or {}
    for metric, raw_value in metrics.items():
        if not isinstance(raw_value, (int, float)):
            continue
        value = float(raw_value)
        if not math.isfinite(value):
            continue

        weight = _bounded(confidence.get(metric, 0.65))
        if weight <= 0:
            continue

        state = skill["metrics"].setdefault(
            metric,
            {
                "weighted_sum": 0.0,
                "weight_sum": 0.0,
                "observation_count": 0,
                "min": value,
                "max": value,
            },
        )
        state["weighted_sum"] += value * weight
        state["weight_sum"] += weight
        state["observation_count"] += 1
        state["min"] = min(float(state["min"]), value)
        state["max"] = max(float(state["max"]), value)

    return result


def profile_metric_estimate(
    profile: dict[str, Any],
    *,
    skill_id: str,
    metric: str,
) -> dict[str, float] | None:
    _validate_profile(profile)
    skill = profile["skills"].get(skill_id)
    if not isinstance(skill, dict):
        return None
    state = skill.get("metrics", {}).get(metric)
    if not isinstance(state, dict):
        return None

    weight_sum = float(state.get("weight_sum", 0.0))
    if weight_sum <= 0:
        return None

    mean = float(state["weighted_sum"]) / weight_sum
    confidence = 1.0 - math.exp(-weight_sum / 3.0)
    return {
        "mean": mean,
        "confidence": round(_bounded(confidence), 3),
        "effective_weight": weight_sum,
        "observation_count": float(state["observation_count"]),
        "min": float(state["min"]),
        "max": float(state["max"]),
    }


def blend_population_and_personal_reference(
    profile: dict[str, Any],
    *,
    skill_id: str,
    metric: str,
    population_mean: float,
    population_confidence: float = 0.5,
    prior_strength: float = 2.0,
) -> dict[str, float]:
    estimate = profile_metric_estimate(
        profile,
        skill_id=skill_id,
        metric=metric,
    )
    population_weight = max(
        0.0,
        prior_strength * _bounded(population_confidence),
    )

    if estimate is None:
        return {
            "mean": float(population_mean),
            "personal_weight": 0.0,
            "population_weight": population_weight,
            "personal_fraction": 0.0,
        }

    personal_weight = float(estimate["effective_weight"])
    denominator = max(1e-9, personal_weight + population_weight)
    blended = (
        float(estimate["mean"]) * personal_weight
        + float(population_mean) * population_weight
    ) / denominator
    return {
        "mean": blended,
        "personal_weight": personal_weight,
        "population_weight": population_weight,
        "personal_fraction": personal_weight / denominator,
    }


def record_cue_response(
    profile: dict[str, Any],
    *,
    cue_id: str,
    target_metric: str,
    before: float,
    after: float,
    improvement_direction: str,
    confidence: float = 0.7,
) -> dict[str, Any]:
    """Track whether a coaching cue changed the intended metric.

    A positive normalized response means the metric moved in the requested
    direction. This is not a causal proof; it is a rider-specific utility
    signal that can rank future coaching experiments.
    """

    _validate_profile(profile)
    if improvement_direction not in {"increase", "decrease"}:
        raise ValueError(
            "improvement_direction must be increase or decrease"
        )
    if not all(math.isfinite(value) for value in (before, after)):
        raise ValueError("before and after must be finite")

    scale = max(abs(before), abs(after), 1e-6)
    raw_delta = (after - before) / scale
    response = (
        raw_delta
        if improvement_direction == "increase"
        else -raw_delta
    )
    weight = _bounded(confidence)

    result = copy.deepcopy(profile)
    key = f"{cue_id}::{target_metric}"
    state = result["cue_responses"].setdefault(
        key,
        {
            "cue_id": cue_id,
            "target_metric": target_metric,
            "improvement_direction": improvement_direction,
            "weighted_response_sum": 0.0,
            "weight_sum": 0.0,
            "trial_count": 0,
            "positive_count": 0,
        },
    )
    state["weighted_response_sum"] += response * weight
    state["weight_sum"] += weight
    state["trial_count"] += 1
    if response > 0:
        state["positive_count"] += 1

    return result


def cue_utility(
    profile: dict[str, Any],
    *,
    cue_id: str,
    target_metric: str,
) -> dict[str, float] | None:
    _validate_profile(profile)
    key = f"{cue_id}::{target_metric}"
    state = profile["cue_responses"].get(key)
    if not isinstance(state, dict):
        return None

    weight_sum = float(state.get("weight_sum", 0.0))
    if weight_sum <= 0:
        return None

    mean_response = (
        float(state["weighted_response_sum"]) / weight_sum
    )
    trial_count = int(state["trial_count"])
    reliability = 1.0 - math.exp(-trial_count / 3.0)
    return {
        "mean_normalized_response": mean_response,
        "reliability": round(_bounded(reliability), 3),
        "trial_count": float(trial_count),
        "positive_fraction": (
            float(state["positive_count"]) / max(trial_count, 1)
        ),
    }


def _validate_profile(profile: object) -> None:
    if not isinstance(profile, dict):
        raise TypeError("profile must be a JSON object")
    if (
        profile.get("schema_version")
        != PERSONAL_BALANCE_PROFILE_SCHEMA_VERSION
    ):
        raise ValueError("unsupported personal balance profile schema")
    if not isinstance(profile.get("skills"), dict):
        raise TypeError("profile.skills must be an object")
    if not isinstance(profile.get("cue_responses"), dict):
        raise TypeError("profile.cue_responses must be an object")
    if not isinstance(profile.get("session_ids"), list):
        raise TypeError("profile.session_ids must be a list")


def _bounded(value: float) -> float:
    return min(1.0, max(0.0, float(value)))
