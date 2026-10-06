from __future__ import annotations

import hashlib
import json
import math
import statistics
from pathlib import Path
from typing import Any

from .annotation_contract import (
    validate_annotation_manifest,
    validate_teacher_labels,
)
from .reviewed_labels import REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
from .video_alignment import file_sha256

PERSONAL_BASELINE_SPEC_SCHEMA_VERSION = (
    "motionos.personal-movement-baseline-spec.v1"
)
PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION = (
    "motionos.personal-movement-baseline.v1"
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


def _canonical_hash(value: object, *, size: int = 16) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:size]


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
    if not values:
        raise ValueError("cannot compute quantile of empty values")
    if not 0 <= probability <= 1:
        raise ValueError("quantile probability must be within [0, 1]")

    ordered = sorted(values)
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
    absolute_deviations = [
        abs(value - median)
        for value in values
    ]
    return {
        "sample_count": len(values),
        "median": median,
        "median_absolute_deviation": statistics.median(
            absolute_deviations
        ),
        "q10": _quantile(values, 0.10),
        "q25": _quantile(values, 0.25),
        "q75": _quantile(values, 0.75),
        "q90": _quantile(values, 0.90),
        "minimum": min(values),
        "maximum": max(values),
    }


def _selector_value(
    row: dict[str, Any],
    path: str,
) -> object:
    parts = path.split(".")
    if len(parts) != 2:
        raise ValueError(
            "baseline selector paths must use evidence_class.field"
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


def _metric_definition(
    raw: object,
    *,
    index: int,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise TypeError(f"metrics[{index}] must be an object")

    metric_id = _required_string(
        raw.get("id"),
        field=f"metrics[{index}].id",
    )
    evidence_class = _required_string(
        raw.get("evidence_class"),
        field=f"metrics[{index}].evidence_class",
    )
    if evidence_class not in _EVIDENCE_CLASSES:
        raise ValueError(
            f"metrics[{index}] has unsupported evidence_class"
        )
    field = _required_string(
        raw.get("field"),
        field=f"metrics[{index}].field",
    )
    unit = _required_string(
        raw.get("unit"),
        field=f"metrics[{index}].unit",
    )

    selectors_raw = raw.get("selectors", {})
    if not isinstance(selectors_raw, dict):
        raise TypeError(f"metrics[{index}].selectors must be an object")
    selectors: dict[str, object] = {}
    for selector_path, expected in selectors_raw.items():
        path = _required_string(
            selector_path,
            field=f"metrics[{index}].selectors.key",
        )
        if isinstance(expected, (dict, list)):
            raise TypeError(
                f"metrics[{index}].selectors.{path} must be scalar"
            )
        _selector_value(
            {
                path.split(".")[0]: {},
            },
            path,
        )
        selectors[path] = expected

    return {
        "id": metric_id,
        "evidence_class": evidence_class,
        "field": field,
        "unit": unit,
        "selectors": selectors,
    }


def _reviewed_source(
    raw: object,
    *,
    index: int,
    base: Path,
    expected_sport: str,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise TypeError(f"sources[{index}] must be an object")

    labels = _resolve(
        _required_string(
            raw.get("reviewed_labels"),
            field=f"sources[{index}].reviewed_labels",
        ),
        base=base,
    )
    receipt = _resolve(
        _required_string(
            raw.get("reviewed_labels_receipt"),
            field=f"sources[{index}].reviewed_labels_receipt",
        ),
        base=base,
    )
    manifest = _resolve(
        _required_string(
            raw.get("annotation_manifest"),
            field=f"sources[{index}].annotation_manifest",
        ),
        base=base,
    )
    context = _context(
        raw.get("context", {}),
        field=f"sources[{index}].context",
    )

    for path in (labels, receipt, manifest):
        if not path.is_file():
            raise FileNotFoundError(path)

    receipt_payload = _load_object(receipt)
    if (
        receipt_payload.get("schema_version")
        != REVIEWED_LABELS_RECEIPT_SCHEMA_VERSION
    ):
        raise ValueError(
            f"sources[{index}] has unsupported reviewed-label receipt"
        )
    bindings = receipt_payload.get("bindings")
    if not isinstance(bindings, dict):
        raise TypeError(
            f"sources[{index}] reviewed-label receipt bindings malformed"
        )

    reviewed_binding = bindings.get("reviewed_labels")
    manifest_binding = bindings.get("annotation_manifest")
    if not isinstance(reviewed_binding, dict):
        raise TypeError(
            f"sources[{index}] reviewed_labels binding malformed"
        )
    if not isinstance(manifest_binding, dict):
        raise TypeError(
            f"sources[{index}] annotation_manifest binding malformed"
        )

    labels_sha, labels_bytes = file_sha256(labels)
    expected_labels_sha = _required_string(
        reviewed_binding.get("sha256"),
        field=(
            f"sources[{index}].receipt.bindings."
            "reviewed_labels.sha256"
        ),
    )
    if labels_sha != expected_labels_sha:
        raise ValueError(
            f"sources[{index}] reviewed-label hash mismatch"
        )

    manifest_sha, manifest_bytes = file_sha256(manifest)
    expected_manifest_sha = _required_string(
        manifest_binding.get("sha256"),
        field=(
            f"sources[{index}].receipt.bindings."
            "annotation_manifest.sha256"
        ),
    )
    if manifest_sha != expected_manifest_sha:
        raise ValueError(
            f"sources[{index}] annotation-manifest hash mismatch"
        )

    manifest_payload = validate_annotation_manifest(manifest)
    validation = validate_teacher_labels(labels, manifest)
    run_id = _required_string(
        manifest_payload.get("run_id"),
        field=f"sources[{index}].manifest.run_id",
    )
    if receipt_payload.get("run_id") != run_id:
        raise ValueError(
            f"sources[{index}] receipt/manifest run_id mismatch"
        )
    if manifest_payload.get("sport") != expected_sport:
        raise ValueError(
            f"sources[{index}] sport does not match baseline spec"
        )

    rows = _load_jsonl(labels)
    if len(rows) != validation.label_count:
        raise ValueError(
            f"sources[{index}] label count changed during validation"
        )

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


def build_personal_movement_baseline(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    """Build descriptive per-context personal movement distributions.

    Only explicitly accepted reviewed labels contribute. Frame count never
    substitutes for repeated-session evidence: repeatability is summarized
    separately across session medians.
    """

    spec_file = Path(spec_path).resolve()
    spec = _load_object(spec_file)
    if spec.get("schema_version") != PERSONAL_BASELINE_SPEC_SCHEMA_VERSION:
        raise ValueError("unsupported personal baseline spec schema")

    profile_id = _required_string(
        spec.get("profile_id"),
        field="profile_id",
    )
    sport = _required_string(
        spec.get("sport"),
        field="sport",
    )

    raw_metrics = spec.get("metrics")
    if not isinstance(raw_metrics, list) or not raw_metrics:
        raise ValueError("baseline spec requires at least one metric")
    metrics = [
        _metric_definition(raw, index=index)
        for index, raw in enumerate(raw_metrics)
    ]
    metric_ids = [str(metric["id"]) for metric in metrics]
    if len(set(metric_ids)) != len(metric_ids):
        raise ValueError("baseline metric ids must be unique")

    raw_sources = spec.get("sources")
    if not isinstance(raw_sources, list) or not raw_sources:
        raise ValueError("baseline spec requires at least one source")
    sources = [
        _reviewed_source(
            raw,
            index=index,
            base=spec_file.parent,
            expected_sport=sport,
        )
        for index, raw in enumerate(raw_sources)
    ]
    run_ids = [str(source["run_id"]) for source in sources]
    if len(set(run_ids)) != len(run_ids):
        raise ValueError("baseline sources must have unique run_id values")

    groups: list[dict[str, Any]] = []
    for metric in metrics:
        contexts: dict[str, dict[str, Any]] = {}

        for source in sources:
            context = source["context"]
            context_key = json.dumps(
                context,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            )
            bucket = contexts.setdefault(
                context_key,
                {
                    "context": context,
                    "sessions": {},
                },
            )
            values: list[float] = []
            corrected_sample_count = 0

            for row in source["rows"]:
                if row.get("human_review_state") != "accepted":
                    continue
                if not _matches_selectors(
                    row,
                    metric["selectors"],
                ):
                    continue

                layer = row.get(metric["evidence_class"])
                if not isinstance(layer, dict):
                    continue
                raw_value = layer.get(metric["field"])
                if raw_value is None:
                    continue
                if isinstance(raw_value, bool):
                    raise TypeError(
                        f"metric {metric['id']!r} encountered boolean value"
                    )
                try:
                    value = float(raw_value)
                except (TypeError, ValueError) as exc:
                    raise ValueError(
                        f"metric {metric['id']!r} must be numeric"
                    ) from exc
                if not math.isfinite(value):
                    raise ValueError(
                        f"metric {metric['id']!r} must be finite"
                    )
                values.append(value)

                provenance = row.get("human_review_provenance")
                if isinstance(provenance, dict):
                    corrected_fields = provenance.get(
                        "corrected_fields",
                        [],
                    )
                    target = (
                        f"{metric['evidence_class']}."
                        f"{metric['field']}"
                    )
                    if (
                        isinstance(corrected_fields, list)
                        and target in corrected_fields
                    ):
                        corrected_sample_count += 1

            if values:
                bucket["sessions"][source["run_id"]] = {
                    "values": values,
                    "corrected_sample_count": corrected_sample_count,
                }

        for context_key, bucket in sorted(contexts.items()):
            sessions = bucket["sessions"]
            if not sessions:
                continue

            pooled: list[float] = []
            corrected_total = 0
            session_summaries: list[dict[str, Any]] = []
            session_medians: list[float] = []

            for run_id, session in sorted(sessions.items()):
                values = session["values"]
                distribution = _distribution(values)
                session_median = float(distribution["median"])
                session_medians.append(session_median)
                pooled.extend(values)
                corrected_total += int(
                    session["corrected_sample_count"]
                )
                session_summaries.append(
                    {
                        "run_id": run_id,
                        "sample_count": len(values),
                        "median": session_median,
                    }
                )

            pooled_distribution = _distribution(pooled)
            median_of_session_medians = statistics.median(
                session_medians
            )
            session_median_mad = statistics.median(
                [
                    abs(value - median_of_session_medians)
                    for value in session_medians
                ]
            )

            groups.append(
                {
                    "group_id": (
                        f"personal-baseline/{metric['id']}/"
                        f"{_canonical_hash(json.loads(context_key))}"
                    ),
                    "metric_id": metric["id"],
                    "evidence_class": metric["evidence_class"],
                    "field": metric["field"],
                    "unit": metric["unit"],
                    "selectors": metric["selectors"],
                    "context": bucket["context"],
                    "distribution": pooled_distribution,
                    "review": {
                        "accepted_sample_count": len(pooled),
                        "human_corrected_sample_count": corrected_total,
                    },
                    "repeatability": {
                        "session_count": len(session_summaries),
                        "status": (
                            "multi_session_descriptive"
                            if len(session_summaries) >= 2
                            else "single_session_only"
                        ),
                        "median_of_session_medians":
                            median_of_session_medians,
                        "session_median_absolute_deviation":
                            session_median_mad,
                        "sessions": session_summaries,
                    },
                }
            )

    if not groups:
        raise ValueError(
            "baseline spec produced no accepted numeric metric samples"
        )

    spec_sha, spec_bytes = file_sha256(spec_file)
    payload: dict[str, Any] = {
        "schema_version": PERSONAL_MOVEMENT_BASELINE_SCHEMA_VERSION,
        "profile_id": profile_id,
        "sport": sport,
        "bindings": {
            "baseline_spec": {
                "path": str(spec_file),
                "sha256": spec_sha,
                "byte_count": spec_bytes,
            },
            "sources": [
                source["binding"]
                for source in sources
            ],
        },
        "summary": {
            "source_session_count": len(sources),
            "metric_count": len(metrics),
            "baseline_group_count": len(groups),
            "accepted_sample_count": sum(
                int(group["distribution"]["sample_count"])
                for group in groups
            ),
        },
        "groups": groups,
        "claim_boundary": (
            "This baseline is a descriptive summary of explicitly accepted "
            "reviewed labels for one local profile, sport, metric, and exact "
            "context. Multiple frames from one session do not establish "
            "longitudinal repeatability. Multi-session repeatability does not "
            "establish measurement accuracy, ideal technique, injury risk, or "
            "causal coaching benefit."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
