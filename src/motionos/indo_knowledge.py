from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

INDO_SKILL_TAXONOMY_SCHEMA_VERSION = "motionos.indo-skill-taxonomy.v1"


@dataclass(frozen=True)
class CoachingSuggestion:
    rule_id: str
    tip: str
    drill_id: str
    confidence: float
    evidence_level: str
    reasons: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "rule_id": self.rule_id,
            "tip": self.tip,
            "drill_id": self.drill_id,
            "confidence": self.confidence,
            "evidence_level": self.evidence_level,
            "reasons": list(self.reasons),
        }


def load_indo_skill_taxonomy(
    path: str | Path,
) -> dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    validate_indo_skill_taxonomy(payload)
    return payload


def validate_indo_skill_taxonomy(payload: object) -> None:
    if not isinstance(payload, dict):
        raise TypeError("taxonomy must be a JSON object")
    if payload.get("schema_version") != INDO_SKILL_TAXONOMY_SCHEMA_VERSION:
        raise ValueError(
            "unsupported INDO BOARD taxonomy schema version"
        )

    source_registry = payload.get("source_registry")
    if not isinstance(source_registry, list):
        raise TypeError("source_registry must be a list")

    source_ids: set[str] = set()
    for index, source in enumerate(source_registry):
        if not isinstance(source, dict):
            raise TypeError(
                f"source_registry[{index}] must be an object"
            )
        source_id = source.get("id")
        if not isinstance(source_id, str) or not source_id:
            raise ValueError(
                f"source_registry[{index}].id must be non-empty"
            )
        if source_id in source_ids:
            raise ValueError(
                f"duplicate source registry id: {source_id}"
            )
        source_ids.add(source_id)

        evidence_level = source.get("evidence_level")
        if evidence_level not in {
            "official_instruction",
            "community_practice",
            "system_hypothesis",
        }:
            raise ValueError(
                f"{source_id} has unsupported evidence_level"
            )

    skills = payload.get("skills")
    if not isinstance(skills, list) or not skills:
        raise ValueError("taxonomy requires a non-empty skills list")

    skill_ids: set[str] = set()
    for index, skill in enumerate(skills):
        if not isinstance(skill, dict):
            raise TypeError(f"skills[{index}] must be an object")

        skill_id = skill.get("id")
        if not isinstance(skill_id, str) or not skill_id:
            raise ValueError(f"skills[{index}].id must be non-empty")
        if skill_id in skill_ids:
            raise ValueError(f"duplicate skill id: {skill_id}")
        skill_ids.add(skill_id)

        level = skill.get("level")
        if not isinstance(level, int) or level < 0:
            raise ValueError(
                f"skills[{index}].level must be a non-negative integer"
            )

        for key in (
            "prerequisites",
            "source_ids",
            "detectable_with",
            "best_with",
            "phase_signature",
            "metrics",
            "coaching_cues",
        ):
            value = skill.get(key)
            if not isinstance(value, list):
                raise TypeError(
                    f"skills[{index}].{key} must be a list"
                )

    for skill in skills:
        for prerequisite in skill["prerequisites"]:
            if prerequisite not in skill_ids:
                raise ValueError(
                    f"{skill['id']} references unknown prerequisite "
                    f"{prerequisite}"
                )

        for source_id in skill["source_ids"]:
            if source_id not in source_ids:
                raise ValueError(
                    f"{skill['id']} references unknown source_id "
                    f"{source_id}"
                )

    rules = payload.get("coaching_rules", [])
    if not isinstance(rules, list):
        raise TypeError("coaching_rules must be a list")
    rule_ids: set[str] = set()
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            raise TypeError(f"coaching_rules[{index}] must be an object")
        rule_id = rule.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise ValueError(
                f"coaching_rules[{index}].id must be non-empty"
            )
        if rule_id in rule_ids:
            raise ValueError(f"duplicate coaching rule id: {rule_id}")
        rule_ids.add(rule_id)
        drill_id = rule.get("drill_id")
        if drill_id not in skill_ids:
            raise ValueError(
                f"{rule_id} references unknown drill_id {drill_id}"
            )


def cold_start_plan(
    taxonomy: dict[str, Any],
    *,
    available_channels: set[str] | None = None,
) -> list[dict[str, Any]]:
    validate_indo_skill_taxonomy(taxonomy)
    available = available_channels or {
        "body_pose_2d",
        "body_pose_3d",
    }
    skill_by_id = {
        skill["id"]: skill for skill in taxonomy["skills"]
    }

    plan: list[dict[str, Any]] = []
    for raw in taxonomy.get("cold_start_plan", []):
        if not isinstance(raw, dict):
            continue
        skill = skill_by_id.get(raw.get("skill_id"))
        if skill is None:
            continue
        minimum = set(skill.get("detectable_with", []))
        if minimum and not minimum.issubset(available):
            continue

        item = dict(raw)
        item["display_name"] = skill["display_name"]
        item["metrics"] = skill["metrics"]
        item["coaching_cues"] = skill["coaching_cues"]
        plan.append(item)
    return plan


def classify_observable_skills(
    taxonomy: dict[str, Any],
    available_channels: set[str],
) -> dict[str, list[str]]:
    validate_indo_skill_taxonomy(taxonomy)

    ready: list[str] = []
    partial: list[str] = []
    blocked: list[str] = []

    for skill in taxonomy["skills"]:
        minimum = set(skill.get("detectable_with", []))
        recommended = set(skill.get("best_with", []))
        if not minimum.issubset(available_channels):
            blocked.append(skill["id"])
        elif recommended.issubset(available_channels):
            ready.append(skill["id"])
        else:
            partial.append(skill["id"])

    return {
        "ready": ready,
        "partial": partial,
        "blocked": blocked,
    }


def generate_coaching_suggestions(
    taxonomy: dict[str, Any],
    metrics: dict[str, float],
    *,
    metric_confidence: dict[str, float] | None = None,
    max_suggestions: int = 2,
) -> list[CoachingSuggestion]:
    """Apply population-prior coaching rules to one session.

    This is deliberately deterministic and conservative. A rule only fires
    when all required metrics are present and its trigger is satisfied.
    Confidence is bounded by the weakest metric confidence supporting it.
    """

    validate_indo_skill_taxonomy(taxonomy)
    confidences = metric_confidence or {}
    suggestions: list[CoachingSuggestion] = []

    for rule in taxonomy.get("coaching_rules", []):
        required = rule.get("requires_metrics", [])
        if not all(
            metric in metrics
            and isinstance(metrics[metric], (int, float))
            and math.isfinite(float(metrics[metric]))
            for metric in required
        ):
            continue

        matched, reasons = _rule_matches(rule, metrics)
        if not matched:
            continue

        supporting_confidence = min(
            (
                _bounded_confidence(confidences.get(metric, 0.65))
                for metric in required
            ),
            default=0.65,
        )

        evidence_level = str(
            rule.get("evidence_level", "system_hypothesis")
        )
        evidence_multiplier = {
            "official_instruction": 0.90,
            "community_practice": 0.75,
            "system_hypothesis": 0.70,
        }.get(evidence_level, 0.65)

        suggestions.append(
            CoachingSuggestion(
                rule_id=str(rule["id"]),
                tip=str(rule["tip"]),
                drill_id=str(rule["drill_id"]),
                confidence=round(
                    supporting_confidence * evidence_multiplier,
                    3,
                ),
                evidence_level=evidence_level,
                reasons=tuple(reasons),
            )
        )

    suggestions.sort(
        key=lambda item: (-item.confidence, item.rule_id)
    )
    return suggestions[:max(0, max_suggestions)]


def build_session_learning_targets(
    taxonomy: dict[str, Any],
    *,
    completed_skill_ids: set[str],
    available_channels: set[str],
    limit: int = 4,
) -> list[dict[str, Any]]:
    """Choose the next measurable skills without requiring long user history."""

    validate_indo_skill_taxonomy(taxonomy)
    candidates: list[dict[str, Any]] = []

    for skill in taxonomy["skills"]:
        skill_id = skill["id"]
        if skill_id in completed_skill_ids:
            continue

        prerequisites = set(skill.get("prerequisites", []))
        if not prerequisites.issubset(completed_skill_ids):
            continue

        minimum = set(skill.get("detectable_with", []))
        if not minimum.issubset(available_channels):
            continue

        candidates.append(
            {
                "skill_id": skill_id,
                "display_name": skill["display_name"],
                "level": skill["level"],
                "priority": skill.get(
                    "cold_start_priority",
                    999,
                ),
                "metrics": skill["metrics"],
                "coaching_cues": skill["coaching_cues"],
                "measurement_quality": (
                    "full"
                    if set(skill.get("best_with", [])).issubset(
                        available_channels
                    )
                    else "partial"
                ),
            }
        )

    candidates.sort(
        key=lambda item: (
            item["level"],
            item["priority"],
            item["skill_id"],
        )
    )
    return candidates[:max(0, limit)]


def _rule_matches(
    rule: dict[str, Any],
    metrics: dict[str, float],
) -> tuple[bool, list[str]]:
    trigger = rule.get("trigger")
    if not isinstance(trigger, dict):
        return False, []

    reasons: list[str] = []
    for key, threshold in trigger.items():
        if not isinstance(threshold, (int, float)):
            return False, []

        if key.endswith("_gt"):
            metric = key.removesuffix("_gt")
            value = metrics.get(metric)
            if value is None or float(value) <= float(threshold):
                return False, []
            reasons.append(
                f"{metric}={float(value):.3g} > {float(threshold):.3g}"
            )
            continue

        if key.endswith("_lt"):
            metric = key.removesuffix("_lt")
            value = metrics.get(metric)
            if value is None or float(value) >= float(threshold):
                return False, []
            reasons.append(
                f"{metric}={float(value):.3g} < {float(threshold):.3g}"
            )
            continue

        if key == "relative_side_difference_gt":
            left = metrics.get("left_recovery_ms")
            right = metrics.get("right_recovery_ms")
            if left is None or right is None:
                return False, []
            denominator = max(abs(float(left)), abs(float(right)), 1e-9)
            difference = abs(float(left) - float(right)) / denominator
            if difference <= float(threshold):
                return False, []
            reasons.append(
                f"relative_side_difference={difference:.3g} "
                f"> {float(threshold):.3g}"
            )
            continue

        return False, []

    return bool(reasons), reasons


def _bounded_confidence(value: float) -> float:
    return min(1.0, max(0.0, float(value)))
