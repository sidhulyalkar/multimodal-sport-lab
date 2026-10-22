"""Private, hash-bound catalog of video-only and sensor-teacher capture candidates.

This indexes evidence without copying media or granting training eligibility.
See docs/video-teacher-dataset-v1.md before using for research.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .data_governance import validate_participant_id
from .observability import load_observability_registry
from .provenance import sha256_file

SPEC_VERSION = "motionos.video-teacher-spec.v1"
INDEX_VERSION = "motionos.video-teacher-index.v1"
LABEL_KINDS = {"sensor_measured", "biomechanical_simulation", "model_inferred"}
TIME_AXES = {"reference_ns", "native_ns"}


def _text(value: object, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value.strip()


def _path(value: object, *, base: Path, name: str) -> Path:
    raw = _text(value, name)
    result = (base / raw).resolve()
    if not result.is_file():
        raise FileNotFoundError(f"{name} does not exist: {result}")
    return result


def _artifact(value: object, *, base: Path, out: Path, name: str) -> dict[str, object]:
    path = _path(value, base=base, name=name)
    return {
        "path": os.path.relpath(path, start=out),
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
    }


def _catalog(spec_path: Path, output_path: Path) -> dict[str, Any]:
    raw = json.loads(spec_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("schema_version") != SPEC_VERSION:
        raise ValueError("unsupported video-teacher spec schema")
    dataset_id = _text(raw.get("dataset_id"), "dataset_id")
    registry_path = _path(
        raw.get("observability_registry"),
        base=spec_path.parent,
        name="observability_registry",
    )
    registry = load_observability_registry(registry_path)
    variables = registry.by_id()

    captures = raw.get("captures")
    if not isinstance(captures, list) or not captures:
        raise ValueError("video-teacher spec requires non-empty captures")

    result: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for i, record in enumerate(captures):
        if not isinstance(record, dict):
            raise TypeError(f"captures[{i}] must be an object")
        sample_id = _text(record.get("sample_id"), f"captures[{i}].sample_id")
        if sample_id in seen_ids:
            raise ValueError(f"duplicate sample_id: {sample_id}")
        seen_ids.add(sample_id)

        participant_id = validate_participant_id(
            _text(record.get("subject_id"), f"captures[{i}].subject_id")
        )
        consent = record.get("consent")
        if not isinstance(consent, dict) or consent.get("training_and_evaluation") is not True:
            raise ValueError(
                f"captures[{i}] requires explicit training/evaluation authorization; "
                "ordinary app recording does not grant it"
            )
        consent_ref = _text(
            consent.get("consent_reference"),
            f"captures[{i}].consent.consent_reference",
        )
        # Consent references are opaque, never paths to the private consent form.
        if "/" in consent_ref or "\\" in consent_ref or len(consent_ref) > 96:
            raise ValueError("consent_reference must be a compact opaque ID")

        identity = {
            key: _text(record.get(key), f"captures[{i}].{key}")
            for key in (
                "run_id", "day_id", "remount_id", "camera_view",
                "sport", "task_id", "protocol_version",
            )
        }
        if identity["sport"] != registry.sport:
            raise ValueError(f"captures[{i}].sport differs from registry sport")

        video = _artifact(
            record.get("video"),
            base=spec_path.parent,
            out=output_path.parent,
            name=f"captures[{i}].video",
        )
        label_specs = record.get("labels", [])
        if not isinstance(label_specs, list):
            raise TypeError(f"captures[{i}].labels must be a list")
        labels: list[dict[str, Any]] = []
        seen_targets: set[tuple[str, str]] = set()

        for j, label in enumerate(label_specs):
            if not isinstance(label, dict):
                raise TypeError(f"captures[{i}].labels[{j}] must be an object")
            prefix = f"captures[{i}].labels[{j}]"
            target = _text(label.get("target_id"), prefix + ".target_id")
            kind = _text(label.get("kind"), prefix + ".kind")
            modality = _text(label.get("modality"), prefix + ".modality")
            time_axis = _text(label.get("time_axis"), prefix + ".time_axis")
            if kind not in LABEL_KINDS:
                raise ValueError(f"{prefix}.kind is unsupported")
            if time_axis not in TIME_AXES:
                raise ValueError(f"{prefix}.time_axis is unsupported")
            if target not in variables:
                raise ValueError(f"{prefix}.target_id missing from observability registry")
            variable = variables[target]
            if kind == "sensor_measured":
                if not variable.teacher_eligible:
                    raise ValueError(f"{target} cannot be a supervised teacher target")
                permitted = set(variable.directly_observed_by) | set(variable.reference_sources)
                if modality not in permitted or "video" in modality.lower():
                    raise ValueError(
                        f"{prefix}.modality is not an independent measured reference for {target}"
                    )
            key = (target, modality)
            if key in seen_targets:
                raise ValueError(f"duplicate target/modality pair: {key}")
            seen_targets.add(key)

            source = _artifact(
                label.get("path"),
                base=spec_path.parent,
                out=output_path.parent,
                name=prefix + ".path",
            )
            alignment = None
            if label.get("alignment_receipt") is not None:
                alignment = _artifact(
                    label["alignment_receipt"],
                    base=spec_path.parent,
                    out=output_path.parent,
                    name=prefix + ".alignment_receipt",
                )
            if kind == "sensor_measured" and alignment is None:
                raise ValueError(f"{prefix} measured labels need a time-alignment receipt")
            if kind == "sensor_measured" and source["sha256"] == video["sha256"]:
                raise ValueError("video bytes cannot be their own measured teacher")
            labels.append({
                "target_id": target,
                "kind": kind,
                "modality": modality,
                "time_axis": time_axis,
                "source": source,
                "alignment_receipt": alignment,
                "teacher_eligibility": (
                    "candidate_requires_physical_sync_review"
                    if kind == "sensor_measured"
                    else "not_measured_ground_truth"
                ),
            })

        result.append({
            "sample_id": sample_id,
            "subject_id": participant_id,
            **identity,
            "consent_reference": consent_ref,
            "video": video,
            "labels": labels,
            "candidate_status": (
                "paired_requires_independent_qualification"
                if any(l["kind"] == "sensor_measured" for l in labels)
                else "video_only_or_weak_labels"
            ),
        })

    return {
        "schema_version": INDEX_VERSION,
        "dataset_id": dataset_id,
        "spec": _artifact(
            str(spec_path), base=spec_path.parent, out=output_path.parent, name="spec"
        ),
        "observability_registry": _artifact(
            str(registry_path),
            base=spec_path.parent,
            out=output_path.parent,
            name="observability_registry",
        ),
        "samples": sorted(result, key=lambda row: row["sample_id"]),
        "sample_count": len(result),
        "measured_candidate_count": sum(
            row["candidate_status"] == "paired_requires_independent_qualification"
            for row in result
        ),
        "training_ready": False,
        "claim_boundary": (
            "Private candidate index only. A consent reference is not a verified consent "
            "receipt; alignment file existence is not validated clock accuracy. "
            "No row is approved as physical ground truth or train/eval ready."
        ),
    }


def build_video_teacher_index(spec_path: str | Path, output_path: str | Path) -> dict[str, Any]:
    spec = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    if spec == output:
        raise ValueError("output must not overwrite the source spec")
    payload = _catalog(spec, output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def verify_video_teacher_index(index_path: str | Path) -> dict[str, object]:
    index = Path(index_path).resolve()
    existing = json.loads(index.read_text(encoding="utf-8"))
    if not isinstance(existing, dict) or existing.get("schema_version") != INDEX_VERSION:
        raise ValueError("unsupported video-teacher index schema")
    spec = existing.get("spec")
    if not isinstance(spec, dict):
        raise TypeError("index missing spec reference")
    source = (index.parent / _text(spec.get("path"), "spec.path")).resolve()
    regenerated = _catalog(source, index)
    if existing != regenerated:
        raise ValueError("video-teacher index differs from source or artifact evidence")
    return {
        "schema_version": INDEX_VERSION,
        "passed": True,
        "sample_count": len(existing["samples"]),
        "training_ready": False,
        "index_sha256": sha256_file(index),
    }
