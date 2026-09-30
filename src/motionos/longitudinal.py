from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .indo_board import IndoBoardReport, LongitudinalBaseline


@dataclass
class LongitudinalProfile:
    sport: str
    metric_baselines: dict[str, LongitudinalBaseline] = field(
        default_factory=dict
    )
    processed_session_ids: list[str] = field(default_factory=list)
    schema_version: str = "motionos.longitudinal-profile.v1"

    def update(
        self,
        report: IndoBoardReport,
        *,
        minimum_confidence: float = 0.6,
    ) -> bool:
        if report.session_id in self.processed_session_ids:
            return False

        for metric in report.metrics:
            if metric.value is None or metric.confidence < minimum_confidence:
                continue

            baseline = self.metric_baselines.get(metric.metric_id)
            if baseline is None:
                baseline = LongitudinalBaseline(
                    metric_id=metric.metric_id,
                    direction=metric.direction,
                )
                self.metric_baselines[metric.metric_id] = baseline
            elif baseline.direction != metric.direction:
                raise ValueError(
                    "metric direction changed for "
                    f"{metric.metric_id}: {baseline.direction} -> "
                    f"{metric.direction}"
                )
            baseline.observe(metric.value)

        self.processed_session_ids.append(report.session_id)
        return True

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "sport": self.sport,
            "processed_session_ids": list(self.processed_session_ids),
            "metric_baselines": {
                metric_id: asdict(baseline)
                for metric_id, baseline in sorted(
                    self.metric_baselines.items()
                )
            },
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "LongitudinalProfile":
        raw_baselines = data.get("metric_baselines", {})
        if not isinstance(raw_baselines, dict):
            raise TypeError("metric_baselines must be an object")

        baselines: dict[str, LongitudinalBaseline] = {}
        for metric_id, raw in raw_baselines.items():
            if not isinstance(raw, dict):
                raise TypeError(
                    f"baseline for {metric_id!r} must be an object"
                )
            baselines[str(metric_id)] = LongitudinalBaseline(
                metric_id=str(raw["metric_id"]),
                direction=str(raw["direction"]),
                sample_count=int(raw.get("sample_count", 0)),
                mean=float(raw.get("mean", 0.0)),
                m2=float(raw.get("m2", 0.0)),
                best_value=(
                    float(raw["best_value"])
                    if raw.get("best_value") is not None
                    else None
                ),
                latest_value=(
                    float(raw["latest_value"])
                    if raw.get("latest_value") is not None
                    else None
                ),
            )

        return cls(
            sport=str(data["sport"]),
            metric_baselines=baselines,
            processed_session_ids=[
                str(value)
                for value in data.get("processed_session_ids", [])
            ],
            schema_version=str(
                data.get(
                    "schema_version",
                    "motionos.longitudinal-profile.v1",
                )
            ),
        )


def load_longitudinal_profile(
    path: str | Path,
    *,
    sport: str = "indo_board",
) -> LongitudinalProfile:
    source = Path(path)
    if not source.exists():
        return LongitudinalProfile(sport=sport)

    raw = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("longitudinal profile must contain a JSON object")
    profile = LongitudinalProfile.from_dict(raw)
    if profile.sport != sport:
        raise ValueError(
            f"profile sport mismatch: expected {sport}, got {profile.sport}"
        )
    return profile


def save_longitudinal_profile(
    profile: LongitudinalProfile,
    path: str | Path,
) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(
        json.dumps(profile.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(destination)


def update_longitudinal_profile(
    path: str | Path,
    report: IndoBoardReport,
    *,
    sport: str = "indo_board",
    minimum_confidence: float = 0.6,
) -> LongitudinalProfile:
    profile = load_longitudinal_profile(path, sport=sport)
    changed = profile.update(
        report,
        minimum_confidence=minimum_confidence,
    )
    if changed:
        save_longitudinal_profile(profile, path)
    return profile
