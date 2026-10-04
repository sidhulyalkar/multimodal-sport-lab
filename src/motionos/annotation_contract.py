from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .video_alignment import (
    file_sha256,
    load_video_alignment,
    validate_video_alignment,
)

ANNOTATION_MANIFEST_SCHEMA_VERSION = "motionos.annotation-manifest.v1"
TEACHER_LABEL_SCHEMA_VERSION = "motionos.teacher-label.v1"

EVIDENCE_CLASSES = {"observed", "derived", "inferred"}
HUMAN_REVIEW_STATES = {
    "unreviewed",
    "reviewed",
    "accepted",
    "rejected",
}


@dataclass(frozen=True)
class TeacherLabelValidation:
    passed: bool
    label_count: int
    first_video_pts_ns: int | None
    last_video_pts_ns: int | None
    first_reference_time_ns: int | None
    last_reference_time_ns: int | None
    max_mapping_error_ns: int
    observed_fields: tuple[str, ...]
    derived_fields: tuple[str, ...]
    inferred_fields: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "passed": self.passed,
            "label_count": self.label_count,
            "first_video_pts_ns": self.first_video_pts_ns,
            "last_video_pts_ns": self.last_video_pts_ns,
            "first_reference_time_ns": self.first_reference_time_ns,
            "last_reference_time_ns": self.last_reference_time_ns,
            "max_mapping_error_ns": self.max_mapping_error_ns,
            "observed_fields": list(self.observed_fields),
            "derived_fields": list(self.derived_fields),
            "inferred_fields": list(self.inferred_fields),
        }


def _resolve_path(raw: str, *, base_dir: Path) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = base_dir / path
    return path.resolve()


def _artifact_record(role: str, path: Path) -> dict[str, object]:
    if not path.is_file():
        raise FileNotFoundError(path)
    digest, byte_count = file_sha256(path)
    return {
        "role": role,
        "path": str(path),
        "filename": path.name,
        "sha256": digest,
        "byte_count": byte_count,
    }


def _nonempty_string(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def _validate_layer(
    raw: object,
    *,
    available_roles: set[str],
    index: int,
) -> dict[str, object]:
    if not isinstance(raw, dict):
        raise TypeError(f"layers[{index}] must be an object")

    layer_id = _nonempty_string(raw.get("id"), field=f"layers[{index}].id")
    display_name = _nonempty_string(
        raw.get("display_name"),
        field=f"layers[{index}].display_name",
    )
    semantic = _nonempty_string(
        raw.get("semantic"),
        field=f"layers[{index}].semantic",
    )
    evidence_class = _nonempty_string(
        raw.get("evidence_class"),
        field=f"layers[{index}].evidence_class",
    )
    if evidence_class not in EVIDENCE_CLASSES:
        raise ValueError(
            f"layers[{index}].evidence_class must be one of "
            + ", ".join(sorted(EVIDENCE_CLASSES))
        )

    raw_roles = raw.get("source_roles", [])
    if not isinstance(raw_roles, list) or not raw_roles:
        raise ValueError(f"layers[{index}].source_roles must be non-empty")
    source_roles = tuple(
        _nonempty_string(
            role,
            field=f"layers[{index}].source_roles",
        )
        for role in raw_roles
    )
    unknown = sorted(set(source_roles) - available_roles)
    if unknown:
        raise ValueError(
            f"layer {layer_id!r} references unknown source roles: {unknown}"
        )

    model_id = raw.get("model_id")
    model_version = raw.get("model_version")
    if model_id is not None:
        model_id = _nonempty_string(
            model_id,
            field=f"layers[{index}].model_id",
        )
    if model_version is not None:
        model_version = _nonempty_string(
            model_version,
            field=f"layers[{index}].model_version",
        )

    if semantic == "estimated_muscle_demand":
        if evidence_class != "inferred":
            raise ValueError(
                "estimated_muscle_demand must be classified as inferred"
            )
        if model_id is None or model_version is None:
            raise ValueError(
                "estimated_muscle_demand requires model_id and model_version"
            )

    if semantic == "measured_muscle_activation":
        if evidence_class != "observed":
            raise ValueError(
                "measured_muscle_activation must be classified as observed"
            )
        if not any(
            role.lower().startswith(("emg", "measured_emg"))
            for role in source_roles
        ):
            raise ValueError(
                "measured_muscle_activation requires an EMG source role"
            )

    if semantic == "coaching":
        if evidence_class != "inferred":
            raise ValueError("coaching layers must be classified as inferred")

    claim_boundary = raw.get("claim_boundary")
    if claim_boundary is not None:
        claim_boundary = _nonempty_string(
            claim_boundary,
            field=f"layers[{index}].claim_boundary",
        )

    return {
        "id": layer_id,
        "display_name": display_name,
        "semantic": semantic,
        "evidence_class": evidence_class,
        "source_roles": list(source_roles),
        "model_id": model_id,
        "model_version": model_version,
        "claim_boundary": claim_boundary,
    }


def build_annotation_manifest(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    spec_file = Path(spec_path).resolve()
    raw = json.loads(spec_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("annotation spec must be a JSON object")

    run_id = _nonempty_string(raw.get("run_id"), field="run_id")
    sport = _nonempty_string(raw.get("sport"), field="sport")

    source_raw = _nonempty_string(
        raw.get("source_video"),
        field="source_video",
    )
    alignment_raw = _nonempty_string(
        raw.get("video_alignment"),
        field="video_alignment",
    )
    source_video = _resolve_path(source_raw, base_dir=spec_file.parent)
    alignment_path = _resolve_path(
        alignment_raw,
        base_dir=spec_file.parent,
    )
    if not source_video.is_file():
        raise FileNotFoundError(source_video)
    if not alignment_path.is_file():
        raise FileNotFoundError(alignment_path)

    alignment = load_video_alignment(alignment_path)
    validate_video_alignment(alignment, source_video)

    source_digest, source_bytes = file_sha256(source_video)
    if source_digest != alignment.source_video_sha256:
        raise ValueError(
            "annotation source video does not match video alignment receipt"
        )

    alignment_digest, alignment_bytes = file_sha256(alignment_path)

    renderer = raw.get("renderer")
    if not isinstance(renderer, dict):
        raise TypeError("renderer must be an object")
    renderer_id = _nonempty_string(
        renderer.get("id"),
        field="renderer.id",
    )
    renderer_version = _nonempty_string(
        renderer.get("version"),
        field="renderer.version",
    )

    timing_tolerance_ns = int(raw.get("timing_tolerance_ns", 20_000_000))
    if timing_tolerance_ns < 0:
        raise ValueError("timing_tolerance_ns cannot be negative")

    artifacts_raw = raw.get("artifacts", [])
    if not isinstance(artifacts_raw, list):
        raise TypeError("artifacts must be a list")
    artifacts: list[dict[str, object]] = []
    artifact_roles: set[str] = set()
    for index, item in enumerate(artifacts_raw):
        if not isinstance(item, dict):
            raise TypeError(f"artifacts[{index}] must be an object")
        role = _nonempty_string(
            item.get("role"),
            field=f"artifacts[{index}].role",
        )
        if role in {"source_video", "video_alignment"}:
            raise ValueError(f"reserved artifact role: {role}")
        if role in artifact_roles:
            raise ValueError(f"duplicate artifact role: {role}")
        artifact_roles.add(role)
        path_raw = _nonempty_string(
            item.get("path"),
            field=f"artifacts[{index}].path",
        )
        artifacts.append(
            _artifact_record(
                role,
                _resolve_path(path_raw, base_dir=spec_file.parent),
            )
        )

    available_roles = {
        "source_video",
        "video_alignment",
        *artifact_roles,
    }
    layers_raw = raw.get("layers")
    if not isinstance(layers_raw, list) or not layers_raw:
        raise ValueError("layers must be a non-empty list")

    layers = [
        _validate_layer(
            layer,
            available_roles=available_roles,
            index=index,
        )
        for index, layer in enumerate(layers_raw)
    ]
    layer_ids = [str(layer["id"]) for layer in layers]
    if len(set(layer_ids)) != len(layer_ids):
        raise ValueError("annotation layer ids must be unique")

    manifest: dict[str, Any] = {
        "schema_version": ANNOTATION_MANIFEST_SCHEMA_VERSION,
        "run_id": run_id,
        "sport": sport,
        "source_video": {
            "path": str(source_video),
            "filename": source_video.name,
            "sha256": source_digest,
            "byte_count": source_bytes,
        },
        "video_alignment": {
            "path": str(alignment_path),
            "schema_version": alignment.schema_version,
            "sha256": alignment_digest,
            "byte_count": alignment_bytes,
            "coverage_passed": alignment.coverage.passed,
            "residual_rms_ns": alignment.clock_model.residual_rms_ns,
            "trim_video_start_ns": alignment.trim_video_start_ns,
            "trim_video_end_ns": alignment.trim_video_end_ns,
            "reference_start_ns": alignment.reference_start_ns,
            "reference_end_ns": alignment.reference_end_ns,
        },
        "renderer": {
            "id": renderer_id,
            "version": renderer_version,
        },
        "timing_tolerance_ns": timing_tolerance_ns,
        "artifacts": artifacts,
        "layers": layers,
        "claim_boundary": (
            "Annotation layers preserve observed, derived, and inferred "
            "semantics. Anatomical rendering does not convert an estimate "
            "into a measurement. Estimated muscle demand is not EMG or "
            "measured muscle activation."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def load_annotation_manifest(
    path: str | Path,
) -> dict[str, Any]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("annotation manifest must be a JSON object")
    if raw.get("schema_version") != ANNOTATION_MANIFEST_SCHEMA_VERSION:
        raise ValueError("unsupported annotation manifest schema")
    return raw


def validate_annotation_manifest(
    path: str | Path,
) -> dict[str, Any]:
    manifest_path = Path(path).resolve()
    manifest = load_annotation_manifest(manifest_path)

    source = manifest.get("source_video")
    alignment_info = manifest.get("video_alignment")
    if not isinstance(source, dict) or not isinstance(alignment_info, dict):
        raise TypeError("annotation manifest source fields are malformed")

    source_path = Path(str(source["path"]))
    alignment_path = Path(str(alignment_info["path"]))
    source_digest, source_bytes = file_sha256(source_path)
    if source_digest != source.get("sha256"):
        raise ValueError("annotation source-video hash mismatch")
    if source_bytes != int(source.get("byte_count", -1)):
        raise ValueError("annotation source-video byte-count mismatch")

    alignment_digest, alignment_bytes = file_sha256(alignment_path)
    if alignment_digest != alignment_info.get("sha256"):
        raise ValueError("annotation video-alignment hash mismatch")
    if alignment_bytes != int(alignment_info.get("byte_count", -1)):
        raise ValueError("annotation video-alignment byte-count mismatch")

    alignment = load_video_alignment(alignment_path)
    validate_video_alignment(alignment, source_path)
    if alignment.source_video_sha256 != source_digest:
        raise ValueError(
            "annotation alignment does not bind the manifest source video"
        )

    artifact_roles: set[str] = set()
    artifacts = manifest.get("artifacts", [])
    if not isinstance(artifacts, list):
        raise TypeError("annotation manifest artifacts must be a list")
    for index, item in enumerate(artifacts):
        if not isinstance(item, dict):
            raise TypeError(f"annotation artifact {index} must be an object")
        role = _nonempty_string(
            item.get("role"),
            field=f"artifacts[{index}].role",
        )
        if role in artifact_roles:
            raise ValueError(f"duplicate annotation artifact role: {role}")
        artifact_roles.add(role)
        artifact_path = Path(str(item["path"]))
        digest, byte_count = file_sha256(artifact_path)
        if digest != item.get("sha256"):
            raise ValueError(f"annotation artifact hash mismatch: {role}")
        if byte_count != int(item.get("byte_count", -1)):
            raise ValueError(
                f"annotation artifact byte-count mismatch: {role}"
            )

    available_roles = {
        "source_video",
        "video_alignment",
        *artifact_roles,
    }
    layers_raw = manifest.get("layers")
    if not isinstance(layers_raw, list) or not layers_raw:
        raise ValueError("annotation manifest requires layers")
    layers = [
        _validate_layer(
            layer,
            available_roles=available_roles,
            index=index,
        )
        for index, layer in enumerate(layers_raw)
    ]
    if len({str(layer["id"]) for layer in layers}) != len(layers):
        raise ValueError("annotation layer ids must be unique")

    return manifest


def _json_object(value: object, *, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise TypeError(f"{field} must be a JSON object")
    return {str(key): item for key, item in value.items()}


def validate_teacher_labels(
    labels_path: str | Path,
    manifest_path: str | Path,
) -> TeacherLabelValidation:
    manifest_file = Path(manifest_path).resolve()
    manifest = validate_annotation_manifest(manifest_file)
    manifest_digest, _ = file_sha256(manifest_file)

    source = manifest["source_video"]
    alignment_info = manifest["video_alignment"]
    source_digest = str(source["sha256"])
    alignment = load_video_alignment(
        Path(str(alignment_info["path"]))
    )
    tolerance = int(manifest.get("timing_tolerance_ns", 20_000_000))

    rows: list[dict[str, Any]] = []
    labels_file = Path(labels_path)
    with labels_file.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"teacher label line {line_number} is invalid JSON"
                ) from exc
            if not isinstance(raw, dict):
                raise TypeError(
                    f"teacher label line {line_number} must be an object"
                )
            rows.append(raw)

    previous_video: int | None = None
    previous_reference: int | None = None
    observed_fields: set[str] = set()
    derived_fields: set[str] = set()
    inferred_fields: set[str] = set()
    max_error = 0

    for index, row in enumerate(rows):
        if row.get("schema_version") != TEACHER_LABEL_SCHEMA_VERSION:
            raise ValueError(
                f"teacher label {index} has unsupported schema version"
            )
        if row.get("annotation_manifest_sha256") != manifest_digest:
            raise ValueError(
                f"teacher label {index} manifest hash mismatch"
            )
        if row.get("run_id") != manifest["run_id"]:
            raise ValueError(f"teacher label {index} run_id mismatch")
        if row.get("sport") != manifest["sport"]:
            raise ValueError(f"teacher label {index} sport mismatch")
        if row.get("source_video_sha256") != source_digest:
            raise ValueError(
                f"teacher label {index} source-video hash mismatch"
            )

        video_pts = int(row["source_frame_pts_ns"])
        reference_time = int(row["reference_time_ns"])
        if (
            video_pts < alignment.trim_video_start_ns
            or video_pts > alignment.trim_video_end_ns
        ):
            raise ValueError(
                f"teacher label {index} lies outside aligned trim window"
            )
        if (
            reference_time < alignment.reference_start_ns
            or reference_time > alignment.reference_end_ns
        ):
            raise ValueError(
                f"teacher label {index} lies outside reference window"
            )
        if previous_video is not None and video_pts <= previous_video:
            raise ValueError(
                "teacher labels must have strictly increasing source PTS"
            )
        if (
            previous_reference is not None
            and reference_time <= previous_reference
        ):
            raise ValueError(
                "teacher labels must have strictly increasing reference time"
            )
        previous_video = video_pts
        previous_reference = reference_time

        mapped = alignment.map_video_pts_to_reference(video_pts)
        error = abs(mapped - reference_time)
        max_error = max(max_error, error)
        if error > tolerance:
            raise ValueError(
                f"teacher label {index} mapping error {error} ns exceeds "
                f"tolerance {tolerance} ns"
            )

        observed = _json_object(
            row.get("observed", {}),
            field=f"teacher label {index}.observed",
        )
        derived = _json_object(
            row.get("derived", {}),
            field=f"teacher label {index}.derived",
        )
        inferred = _json_object(
            row.get("inferred", {}),
            field=f"teacher label {index}.inferred",
        )
        confidence = _json_object(
            row.get("confidence", {}),
            field=f"teacher label {index}.confidence",
        )
        _json_object(
            row.get("model_versions", {}),
            field=f"teacher label {index}.model_versions",
        )

        for name, value in confidence.items():
            try:
                number = float(value)
            except (TypeError, ValueError) as exc:
                raise ValueError(
                    f"teacher label {index} confidence {name!r} is not numeric"
                ) from exc
            if not math.isfinite(number) or not 0 <= number <= 1:
                raise ValueError(
                    f"teacher label {index} confidence {name!r} "
                    "must be within [0, 1]"
                )

        review_state = row.get("human_review_state", "unreviewed")
        if review_state not in HUMAN_REVIEW_STATES:
            raise ValueError(
                f"teacher label {index} has invalid human_review_state"
            )

        observed_fields.update(observed)
        derived_fields.update(derived)
        inferred_fields.update(inferred)

    return TeacherLabelValidation(
        passed=True,
        label_count=len(rows),
        first_video_pts_ns=(
            int(rows[0]["source_frame_pts_ns"]) if rows else None
        ),
        last_video_pts_ns=(
            int(rows[-1]["source_frame_pts_ns"]) if rows else None
        ),
        first_reference_time_ns=(
            int(rows[0]["reference_time_ns"]) if rows else None
        ),
        last_reference_time_ns=(
            int(rows[-1]["reference_time_ns"]) if rows else None
        ),
        max_mapping_error_ns=max_error,
        observed_fields=tuple(sorted(observed_fields)),
        derived_fields=tuple(sorted(derived_fields)),
        inferred_fields=tuple(sorted(inferred_fields)),
    )
