from __future__ import annotations

import json
import math
import statistics
from pathlib import Path
from typing import Any

from .annotation_contract import (
    validate_annotation_manifest,
    validate_teacher_labels,
)
from .personal_baseline import PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION
from .reviewed_labels import REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
from .video_alignment import file_sha256

PERSONAL_SESSION_DELTA_SPEC_SCHEMA_VERSION = (
    "motionos.personal-session-delta-spec.v1"
)
PERSONAL_SESSION_DELTA_SCHEMA_VERSION = (
    "motionos.personal-session-delta.v1"
)

_EVIDENCE_CLASSES = {"observed", "derived", "inferred"}


def _load_object(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def _load_jsonl(path: str | Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            text = raw.strip()
            if not text:
                continue
            try:
                value = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"{path}:{line_number} is invalid JSON"
                ) from exc
            if not isinstance(value, dict):
                raise TypeError(
                    f"{path}:{line_number} must contain a JSON object"
                )
            rows.append(value)
    return rows


def _required_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _resolve(raw: str, *, base: Path) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def _context(value: object, *, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise TypeError(f"{field} must be an object")

    result: dict[str, object] = {}
    for key, item in value.items():
        name = _required_string(key, field=f"{field}.key")
        if isinstance(item, (dict, list)):
            raise TypeError(
                f"{field}.{name} must be a scalar JSON value"
            )
        result[name] = item
    return result


def _quantile(values: list[float], probability: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("cannot compute quantile of empty values")
    if len(ordered) == 1:
        return ordered[0]

    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (
        ordered[upper] - ordered[lower]
    ) * fraction


def _distribution(values: list[float]) -> dict[str, float | int]:
    if not values:
        raise ValueError("cannot summarize an empty distribution")

    median = statistics.median(values)
    return {
        "sample_count": len(values),
        "median": median,
        "median_absolute_deviation": statistics.median(
            [abs(value - median) for value in values]
        ),
        "q10": _quantile(values, 0.10),
        "q25": _quantile(values, 0.25),
        "q75": _quantile(values, 0.75),
        "q90": _quantile(values, 0.90),
        "minimum": min(values),
        "maximum": max(values),
    }


def _selector_value(row: dict[str, Any], path: str) -> object:
    parts = path.split(".")
    if len(parts) != 2:
        raise ValueError(
            "session-delta selector paths must use evidence_class.field"
        )
    evidence_class, field = parts
    if evidence_class not in _EVIDENCE_CLASSES:
        raise ValueError(
            f"unsupported selector evidence class: {evidence_class}"
        )
    layer = row.get(evidence_class)
    if not isinstance(layer, dict):
        return None
    return layer.get(field)


def _matches_selectors(
    row: dict[str, Any],
    selectors: dict[str, object],
) -> bool:
    return all(
        _selector_value(row, path) == expected
        for path, expected in selectors.items()
    )


def _load_current_source(
    raw: object,
    *,
    base: Path,
    expected_sport: str,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise TypeError("source must be an object")

    labels = _resolve(
        _required_string(
            raw.get("reviewed_labels"),
            field="source.reviewed_labels",
        ),
        base=base,
    )
    receipt = _resolve(
        _required_string(
            raw.get("reviewed_labels_receipt"),
            field="source.reviewed_labels_receipt",
        ),
        base=base,
    )
    manifest = _resolve(
        _required_string(
            raw.get("annotation_manifest"),
            field="source.annotation_manifest",
        ),
        base=base,
    )
    context = _context(
        raw.get("context", {}),
        field="source.context",
    )

    for path in (labels, receipt, manifest):
        if not path.is_file():
            raise FileNotFoundError(path)

    receipt_payload = _load_object(receipt)
    if (
        receipt_payload.get("schema_version")
        != REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
    ):
        raise ValueError("unsupported reviewed-label receipt schema")

    bindings = receipt_payload.get("bindings")
    if not isinstance(bindings, dict):
        raise TypeError("reviewed-label receipt bindings malformed")

    labels_binding = bindings.get("reviewed_labels")
    manifest_binding = bindings.get("annotation_manifest")
    if not isinstance(labels_binding, dict):
        raise TypeError("reviewed_labels binding malformed")
    if not isinstance(manifest_binding, dict):
        raise TypeError("annotation_manifest binding malformed")

    labels_sha, labels_bytes = file_sha256(labels)
    if labels_sha != _required_string(
        labels_binding.get("sha256"),
        field="source.receipt.reviewed_labels.sha256",
    ):
        raise ValueError("current reviewed-label hash mismatch")

    manifest_sha, manifest_bytes = file_sha256(manifest)
    if manifest_sha != _required_string(
        manifest_binding.get("sha256"),
        field="source.receipt.annotation_manifest.sha256",
    ):
        raise ValueError("current annotation-manifest hash mismatch")

    manifest_payload = validate_annotation_manifest(manifest)
    validation = validate_teacher_labels(labels, manifest)
    run_id = _required_string(
        manifest_payload.get("run_id"),
        field="source.manifest.run_id",
    )
    if receipt_payload.get("run_id") != run_id:
        raise ValueError("current receipt/manifest run_id mismatch")
    if manifest_payload.get("sport") != expected_sport:
        raise ValueError("current session sport does not match baseline")

    rows = _load_jsonl(labels)
    if len(rows) != validation.label_count:
        raise ValueError("current label count changed during validation")

    receipt_sha, receipt_bytes = file_sha256(receipt)
    return {
        "run_id": run_id,
        "context": context,
        "rows": rows,
        "binding": {
            "run_id": run_id,
            "context": context,
            "reviewed_labels": {
                "path": str(labels),
                "sha256": labels_sha,
                "byte_count": labels_bytes,
            },
            "reviewed_labels_receipt": {
                "path": str(receipt),
                "sha256": receipt_sha,
                "byte_count": receipt_bytes,
            },
            "annotation_manifest": {
                "path": str(manifest),
                "sha256": manifest_sha,
                "byte_count": manifest_bytes,
            },
        },
    }


def _baseline_run_ids(baseline: dict[str, Any]) -> set[str]:
    bindings = baseline.get("bindings")
    if not isinstance(bindings, dict):
        raise TypeError("baseline bindings must be an object")
    sources = bindings.get("sources")
    if not isinstance(sources, list):
        raise TypeError("baseline source bindings must be a list")

    result: set[str] = set()
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise TypeError(
                f"baseline bindings.sources[{index}] must be an object"
            )
        run_id = _required_string(
            source.get("run_id"),
            field=f"baseline.bindings.sources[{index}].run_id",
        )
        if run_id in result:
            raise ValueError("baseline contains duplicate source run_id")
        result.add(run_id)
    return result


def _metric_values(
    rows: list[dict[str, Any]],
    *,
    evidence_class: str,
    field: str,
    selectors: dict[str, object],
) -> tuple[list[float], int]:
    values: list[float] = []
    corrected_count = 0
    target = f"{evidence_class}.{field}"

    for row in rows:
        if row.get("human_review_state") != "accepted":
            continue
        if not _matches_selectors(row, selectors):
            continue

        layer = row.get(evidence_class)
        if not isinstance(layer, dict):
            continue
        raw_value = layer.get(field)
        if raw_value is None:
            continue
        if isinstance(raw_value, bool):
            raise TypeError(f"metric {target!r} encountered boolean value")
        try:
            value = float(raw_value)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"metric {target!r} must be numeric") from exc
        if not math.isfinite(value):
            raise ValueError(f"metric {target!r} must be finite")
        values.append(value)

        provenance = row.get("human_review_provenance")
        if isinstance(provenance, dict):
            corrected_fields = provenance.get("corrected_fields", [])
            if (
                isinstance(corrected_fields, list)
                and target in corrected_fields
            ):
                corrected_count += 1

    return values, corrected_count


def _interval_membership(
    current_median: float,
    baseline_distribution: dict[str, Any],
) -> str:
    q10 = float(baseline_distribution["q10"])
    q90 = float(baseline_distribution["q90"])
    if current_median < q10:
        return "below_baseline_q10"
    if current_median > q90:
        return "above_baseline_q90"
    return "within_baseline_q10_q90"


def build_personal_session_delta(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    """Compare one new reviewed session with an exact-context baseline.

    This layer reports descriptive deltas only. It does not assign technique
    quality, improvement, deterioration, or coaching recommendations.
    """

    spec_file = Path(spec_path).resolve()
    spec = _load_object(spec_file)
    if spec.get("schema_version") != PERSONAL_SESSION_DELTA_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported personal session delta spec schema")

    baseline = _resolve(
        _required_string(
            spec.get("baseline"),
            field="baseline",
        ),
        base=spec_file.parent,
    )
    if not baseline.is_file():
        raise FileNotFoundError(baseline)

    baseline_sha, baseline_bytes = file_sha256(baseline)
    expected_baseline_sha = _required_string(
        spec.get("baseline_sha256"),
        field="baseline_sha256",
    )
    if baseline_sha != expected_baseline_sha:
        raise ValueError("personal baseline hash mismatch")

    baseline_payload = _load_object(baseline)
    if (
        baseline_payload.get("schema_version")
        != PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION
    ):
        raise ValueError("unsupported personal movement baseline schema")

    profile_id = _required_string(
        baseline_payload.get("profile_id"),
        field="baseline.profile_id",
    )
    sport = _required_string(
        baseline_payload.get("sport"),
        field="baseline.sport",
    )
    baseline_runs = _baseline_run_ids(baseline_payload)

    current = _load_current_source(
        spec.get("source"),
        base=spec_file.parent,
        expected_sport=sport,
    )
    if current["run_id"] in baseline_runs:
        raise ValueError(
            "current session is already included in the personal baseline"
        )

    groups_raw = baseline_payload.get("groups")
    if not isinstance(groups_raw, list):
        raise TypeError("baseline groups must be a list")

    seen_group_ids: set[str] = set()
    comparisons: list[dict[str, Any]] = []
    matching_group_count = 0
    no_sample_count = 0

    for index, group in enumerate(groups_raw):
        if not isinstance(group, dict):
            raise TypeError(f"baseline.groups[{index}] must be an object")

        group_id = _required_string(
            group.get("group_id"),
            field=f"baseline.groups[{index}].group_id",
        )
        if group_id in seen_group_ids:
            raise ValueError(f"duplicate baseline group_id: {group_id}")
        seen_group_ids.add(group_id)

        group_context = _context(
            group.get("context", {}),
            field=f"baseline.groups[{index}].context",
        )
        if group_context != current["context"]:
            continue
        matching_group_count += 1

        evidence_class = _required_string(
            group.get("evidence_class"),
            field=f"baseline.groups[{index}].evidence_class",
        )
        if evidence_class not in _EVIDENCE_CLASSES:
            raise ValueError("baseline group has unsupported evidence class")
        field = _required_string(
            group.get("field"),
            field=f"baseline.groups[{index}].field",
        )
        metric_id = _required_string(
            group.get("metric_id"),
            field=f"baseline.groups[{index}].metric_id",
        )
        unit = _required_string(
            group.get("unit"),
            field=f"baseline.groups[{index}].unit",
        )

        selectors_raw = group.get("selectors", {})
        if not isinstance(selectors_raw, dict):
            raise TypeError("baseline group selectors must be an object")
        selectors = {
            _required_string(key, field="baseline selector key"): value
            for key, value in selectors_raw.items()
        }

        values, corrected_count = _metric_values(
            current["rows"],
            evidence_class=evidence_class,
            field=field,
            selectors=selectors,
        )
        if not values:
            no_sample_count += 1
            comparisons.append(
                {
                    "baseline_group_id": group_id,
                    "metric_id": metric_id,
                    "evidence_class": evidence_class,
                    "field": field,
                    "unit": unit,
                    "context": current["context"],
                    "status": "no_current_accepted_samples",
                    "current": {
                        "accepted_sample_count": 0,
                        "human_corrected_sample_count": 0,
                    },
                }
            )
            continue

        baseline_distribution = group.get("distribution")
        repeatability = group.get("repeatability")
        if not isinstance(baseline_distribution, dict):
            raise TypeError("baseline group distribution must be an object")
        if not isinstance(repeatability, dict):
            raise TypeError("baseline group repeatability must be an object")

        current_distribution = _distribution(values)
        current_median = float(current_distribution["median"])
        baseline_median = float(baseline_distribution["median"])
        delta = current_median - baseline_median

        pooled_mad = float(
            baseline_distribution["median_absolute_deviation"]
        )
        session_count = int(repeatability["session_count"])
        session_mad = float(
            repeatability["session_median_absolute_deviation"]
        )

        comparisons.append(
            {
                "baseline_group_id": group_id,
                "metric_id": metric_id,
                "evidence_class": evidence_class,
                "field": field,
                "unit": unit,
                "context": current["context"],
                "status": (
                    "descriptive_against_multi_session_baseline"
                    if session_count >= 2
                    else "descriptive_against_single_session_baseline"
                ),
                "baseline": {
                    "median": baseline_median,
                    "pooled_median_absolute_deviation": pooled_mad,
                    "session_count": session_count,
                    "session_median_absolute_deviation": session_mad,
                    "q10": float(baseline_distribution["q10"]),
                    "q90": float(baseline_distribution["q90"]),
                },
                "current": {
                    "distribution": current_distribution,
                    "accepted_sample_count": len(values),
                    "human_corrected_sample_count": corrected_count,
                },
                "delta": {
                    "current_median_minus_baseline_median": delta,
                    "in_baseline_pooled_mad_units": (
                        delta / pooled_mad
                        if pooled_mad > 0
                        else None
                    ),
                    "in_baseline_session_mad_units": (
                        delta / session_mad
                        if session_count >= 2 and session_mad > 0
                        else None
                    ),
                    "baseline_interval_membership": _interval_membership(
                        current_median,
                        baseline_distribution,
                    ),
                },
            }
        )

    spec_sha, spec_bytes = file_sha256(spec_file)
    payload: dict[str, Any] = {
        "schema_version": PERSONAL_SESSION_DELTA_SCHEMA_VERSION,
        "profile_id": profile_id,
        "sport": sport,
        "current_run_id": current["run_id"],
        "context": current["context"],
        "bindings": {
            "delta_spec": {
                "path": str(spec_file),
                "sha256": spec_sha,
                "byte_count": spec_bytes,
            },
            "personal_movement_baseline": {
                "path": str(baseline),
                "sha256": baseline_sha,
                "byte_count": baseline_bytes,
            },
            "current_source": current["binding"],
        },
        "summary": {
            "matching_baseline_group_count": matching_group_count,
            "comparison_count": len(comparisons),
            "no_current_sample_count": no_sample_count,
            "context_match": matching_group_count > 0,
        },
        "comparisons": comparisons,
        "claim_boundary": (
            "This artifact describes how one explicitly reviewed session "
            "differs from an exact-context personal baseline. A numerical "
            "delta is not automatically improvement or deterioration. MAD "
            "units describe spread, not measurement accuracy or clinical "
            "significance. No coaching recommendation is authorized by this "
            "artifact alone."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
