from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from .indo_board_state import analyze_board_observations
from .indo_knowledge import (
    build_session_learning_targets,
    generate_coaching_suggestions,
    load_indo_skill_taxonomy,
)
from .indo_profile import (
    new_personal_balance_profile,
    update_personal_balance_profile,
)

INDO_SESSION_REPORT_SCHEMA_VERSION = "motionos.indo-session-report.v1"


def build_indo_session_report(
    *,
    session_id: str,
    taxonomy_path: str | Path,
    body_metrics: dict[str, Any] | None = None,
    board_observations: dict[str, Any] | None = None,
    profile: dict[str, Any] | None = None,
    completed_skill_ids: set[str] | None = None,
) -> dict[str, Any]:
    """Merge first-session evidence into one conservative coaching report."""

    if not session_id:
        raise ValueError("session_id must be non-empty")

    taxonomy = load_indo_skill_taxonomy(taxonomy_path)
    metrics: dict[str, float] = {}
    confidence: dict[str, float] = {}
    evidence: list[dict[str, Any]] = []
    channels: set[str] = set()

    if body_metrics is not None:
        body_values = _numeric_map(body_metrics.get("metrics"))
        body_confidence = _numeric_map(
            body_metrics.get("confidence")
        )
        metrics.update(body_values)
        confidence.update(body_confidence)
        if body_values:
            channels.update({"body_pose_2d", "body_pose_3d"})
        evidence.append(
            {
                "source": "camera_body_pose",
                "metrics": sorted(body_values),
                "claim_boundary": body_metrics.get(
                    "claim_boundary"
                ),
            }
        )

    board_report: dict[str, Any] | None = None
    if board_observations is not None:
        board_report = analyze_board_observations(
            board_observations
        )
        board_values = _numeric_map(board_report.get("metrics"))
        board_confidence = _numeric_map(
            board_report.get("confidence")
        )
        metrics.update(board_values)
        confidence.update(board_confidence)
        if board_values:
            channels.update({"board_pose", "roller_state"})
        evidence.append(
            {
                "source": "deck_roller_geometry",
                "metrics": sorted(board_values),
                "claim_boundary": board_report.get(
                    "claim_boundary"
                ),
            }
        )

    suggestions = generate_coaching_suggestions(
        taxonomy,
        metrics,
        metric_confidence=confidence,
        max_suggestions=2,
    )

    completed = set(completed_skill_ids or set())
    if metrics:
        completed.add("neutral_balance_hold")
    if (
        "recovery_time_ms" in metrics
        or "roller_excursion_p90" in metrics
    ):
        completed.add("controlled_side_shift")
    if "median_knee_flexion_deg" in metrics:
        completed.add("partial_squat_hold")

    next_skills = build_session_learning_targets(
        taxonomy,
        completed_skill_ids=completed,
        available_channels=channels,
        limit=4,
    )

    skill_by_id = {
        skill["id"]: skill for skill in taxonomy["skills"]
    }
    primary = suggestions[0] if suggestions else None
    primary_drill = (
        skill_by_id.get(primary.drill_id)
        if primary is not None
        else None
    )

    updated_profile = copy.deepcopy(
        profile
        if profile is not None
        else new_personal_balance_profile()
    )
    if metrics:
        updated_profile = update_personal_balance_profile(
            updated_profile,
            session_id=session_id,
            skill_id="neutral_balance_hold",
            metrics=metrics,
            confidence=confidence,
        )

    report = {
        "schema_version": INDO_SESSION_REPORT_SCHEMA_VERSION,
        "session_id": session_id,
        "available_channels": sorted(channels),
        "metrics": metrics,
        "confidence": confidence,
        "evidence": evidence,
        "primary_coaching": (
            {
                **primary.to_dict(),
                "drill_display_name": (
                    primary_drill.get("display_name")
                    if isinstance(primary_drill, dict)
                    else primary.drill_id
                ),
                "drill_cues": (
                    primary_drill.get("coaching_cues", [])
                    if isinstance(primary_drill, dict)
                    else []
                ),
            }
            if primary is not None
            else None
        ),
        "alternate_coaching": [
            suggestion.to_dict()
            for suggestion in suggestions[1:]
        ],
        "next_skills": next_skills,
        "board_report": board_report,
        "updated_profile": updated_profile,
        "claim_boundary": (
            "This report separates observations from coaching hypotheses. "
            "Camera-only posture metrics are not full balance-state metrics. "
            "Board/roller coaching requires qualified equipment tracking, "
            "and no output is a diagnosis or injury-risk assessment."
        ),
    }

    if primary is None:
        report["primary_coaching"] = {
            "rule_id": "collect_comparable_baseline",
            "tip": (
                "Repeat the controlled baseline so MotionOS can compare "
                "clean and unstable moments before making a stronger claim."
            ),
            "drill_id": "controlled_side_shift",
            "drill_display_name": "Controlled Side-to-Side Shift",
            "drill_cues": [
                "Move slowly enough to identify center.",
                "Pause briefly before changing direction.",
            ],
            "confidence": 0.35,
            "evidence_level": "system_hypothesis",
            "reasons": [
                "No conservative coaching rule met its evidence threshold."
            ],
        }

    return report


def write_indo_session_report(
    output_path: str | Path,
    report: dict[str, Any],
) -> None:
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_json_object(
    path: str | Path,
) -> dict[str, Any]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return raw


def _numeric_map(
    raw: object,
) -> dict[str, float]:
    if not isinstance(raw, dict):
        return {}

    result: dict[str, float] = {}
    for key, value in raw.items():
        if isinstance(value, (int, float)):
            result[str(key)] = float(value)
    return result
