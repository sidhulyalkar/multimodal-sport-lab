from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import asdict, dataclass
from pathlib import Path

from .observability import load_observability_registry
from .provenance import session_evidence_sha256, sha256_file
from .session import SessionReader

EXPERIMENT_SCHEMA_VERSION = "motionos.experiment-manifest.v1"
SPLIT_SCHEMA_VERSION = "motionos.grouped-split.v1"
ALLOWED_SOURCE_TYPES = {"artifact", "session"}
ALLOWED_SPLIT_PURPOSES = {"primary", "development"}
PRIMARY_GROUP_FIELDS = {
    "repetition_id",
    "run_id",
    "day_id",
    "remount_id",
    "camera_view",
    "intensity",
    "subject_id",
    "sport",
}


def _portable(path: Path, *, base: Path) -> str:
    return os.path.relpath(path.resolve(), base.resolve())


def _resolve(raw: str, *, base: Path) -> Path:
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def _nonempty(value: object, *, label: str) -> str:
    text = str(value).strip()
    if not text:
        raise ValueError(f"{label} must be non-empty")
    return text


def _repository_commit(value: object) -> str:
    commit = _nonempty(value, label="repository_commit").lower()
    if len(commit) != 40 or any(
        char not in "0123456789abcdef"
        for char in commit
    ):
        raise ValueError(
            "repository_commit must be an exact 40-character Git SHA"
        )
    return commit


def _string_list(value: object, *, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise TypeError(f"{label} must be a list")
    result = tuple(str(item).strip() for item in value)
    if any(not item for item in result):
        raise ValueError(f"{label} entries must be non-empty")
    if len(set(result)) != len(result):
        raise ValueError(f"{label} entries must be unique")
    return result


@dataclass(frozen=True)
class ExperimentSource:
    role: str
    kind: str
    source_type: str
    path: str
    sha256: str
    session_id: str | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class ModelArtifact:
    role: str
    model_name: str
    model_version: str
    weights_path: str | None
    weights_sha256: str | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class AcquisitionIdentity:
    subject_id: str
    day_id: str
    run_id: str
    remount_id: str
    camera_view: str | None
    intensity: str | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class ExperimentManifest:
    experiment_id: str
    sport: str
    protocol_version: str
    repository_commit: str
    observability_registry_path: str
    observability_registry_sha256: str
    targets: tuple[str, ...]
    acquisition: AcquisitionIdentity
    sources: tuple[ExperimentSource, ...]
    models: tuple[ModelArtifact, ...]
    notes: tuple[str, ...]
    schema_version: str = EXPERIMENT_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "experiment_id": self.experiment_id,
            "sport": self.sport,
            "protocol_version": self.protocol_version,
            "repository_commit": self.repository_commit,
            "observability_registry": {
                "path": self.observability_registry_path,
                "sha256": self.observability_registry_sha256,
            },
            "targets": list(self.targets),
            "acquisition": self.acquisition.to_dict(),
            "sources": [item.to_dict() for item in self.sources],
            "models": [item.to_dict() for item in self.models],
            "notes": list(self.notes),
            "claim_boundary": (
                "This manifest binds experiment provenance and acquisition "
                "groups. It does not imply that targets are accurate or that "
                "a split is statistically independent."
            ),
        }


def _source(
    item: dict[str, object],
    *,
    index: int,
    spec_dir: Path,
    output_dir: Path,
) -> ExperimentSource:
    role = _nonempty(item.get("role", ""), label=f"source {index}.role")
    kind = _nonempty(item.get("kind", ""), label=f"source {index}.kind")
    source_type = _nonempty(
        item.get("source_type", ""),
        label=f"source {index}.source_type",
    )
    if source_type not in ALLOWED_SOURCE_TYPES:
        raise ValueError(
            f"source {index}.source_type must be one of "
            + ", ".join(sorted(ALLOWED_SOURCE_TYPES))
        )
    raw_path = _nonempty(item.get("path", ""), label=f"source {index}.path")
    path = _resolve(raw_path, base=spec_dir)

    if source_type == "artifact":
        if not path.is_file():
            raise FileNotFoundError(f"experiment artifact does not exist: {path}")
        digest = sha256_file(path)
        session_id = None
    else:
        if not path.is_dir():
            raise FileNotFoundError(f"experiment session does not exist: {path}")
        reader = SessionReader(path)
        digest = session_evidence_sha256(reader)
        session_id = reader.manifest.session_id

    return ExperimentSource(
        role=role,
        kind=kind,
        source_type=source_type,
        path=_portable(path, base=output_dir),
        sha256=digest,
        session_id=session_id,
    )


def _model(
    item: dict[str, object],
    *,
    index: int,
    spec_dir: Path,
    output_dir: Path,
) -> ModelArtifact:
    role = _nonempty(item.get("role", ""), label=f"model {index}.role")
    model_name = _nonempty(
        item.get("model_name", ""),
        label=f"model {index}.model_name",
    )
    model_version = _nonempty(
        item.get("model_version", ""),
        label=f"model {index}.model_version",
    )
    raw_weights = item.get("weights")
    if raw_weights is None:
        return ModelArtifact(
            role=role,
            model_name=model_name,
            model_version=model_version,
            weights_path=None,
            weights_sha256=None,
        )
    weights = _resolve(str(raw_weights), base=spec_dir)
    if not weights.is_file():
        raise FileNotFoundError(f"model weights do not exist: {weights}")
    return ModelArtifact(
        role=role,
        model_name=model_name,
        model_version=model_version,
        weights_path=_portable(weights, base=output_dir),
        weights_sha256=sha256_file(weights),
    )


def build_experiment_manifest(
    spec_path: str | Path,
    output_path: str | Path,
) -> ExperimentManifest:
    spec = Path(spec_path).resolve()
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    raw = json.loads(spec.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("experiment spec must contain a JSON object")
    if raw.get("schema_version") not in {
        None,
        "motionos.experiment-spec.v1",
    }:
        raise ValueError("unsupported experiment spec schema")

    registry_path = _resolve(
        _nonempty(
            raw.get("observability_registry", ""),
            label="observability_registry",
        ),
        base=spec.parent,
    )
    registry = load_observability_registry(registry_path)
    targets = _string_list(raw.get("targets", []), label="targets")
    if not targets:
        raise ValueError("experiment spec requires at least one target")

    registry_variables = registry.by_id()
    unknown = sorted(set(targets) - set(registry_variables))
    if unknown:
        raise ValueError(
            "experiment targets are absent from observability registry: "
            + ", ".join(unknown)
        )
    ineligible = [
        target
        for target in targets
        if not registry_variables[target].teacher_eligible
    ]
    if ineligible:
        raise ValueError(
            "experiment targets are not teacher-eligible: "
            + ", ".join(ineligible)
        )

    acquisition_raw = raw.get("acquisition")
    if not isinstance(acquisition_raw, dict):
        raise TypeError("experiment acquisition must be an object")
    acquisition = AcquisitionIdentity(
        subject_id=_nonempty(
            acquisition_raw.get("subject_id", ""),
            label="acquisition.subject_id",
        ),
        day_id=_nonempty(
            acquisition_raw.get("day_id", ""),
            label="acquisition.day_id",
        ),
        run_id=_nonempty(
            acquisition_raw.get("run_id", ""),
            label="acquisition.run_id",
        ),
        remount_id=_nonempty(
            acquisition_raw.get("remount_id", ""),
            label="acquisition.remount_id",
        ),
        camera_view=(
            str(acquisition_raw["camera_view"]).strip()
            if acquisition_raw.get("camera_view") is not None
            else None
        ),
        intensity=(
            str(acquisition_raw["intensity"]).strip()
            if acquisition_raw.get("intensity") is not None
            else None
        ),
    )

    sources_raw = raw.get("sources")
    if not isinstance(sources_raw, list) or not sources_raw:
        raise ValueError("experiment spec requires non-empty sources")
    sources = tuple(
        _source(
            dict(item),
            index=index,
            spec_dir=spec.parent,
            output_dir=output.parent,
        )
        for index, item in enumerate(sources_raw)
        if isinstance(item, dict)
    )
    if len(sources) != len(sources_raw):
        raise TypeError("experiment source entries must be objects")
    source_roles = [item.role for item in sources]
    if len(set(source_roles)) != len(source_roles):
        raise ValueError("experiment source roles must be unique")

    models_raw = raw.get("models", [])
    if not isinstance(models_raw, list):
        raise TypeError("experiment models must be a list")
    models = tuple(
        _model(
            dict(item),
            index=index,
            spec_dir=spec.parent,
            output_dir=output.parent,
        )
        for index, item in enumerate(models_raw)
        if isinstance(item, dict)
    )
    if len(models) != len(models_raw):
        raise TypeError("experiment model entries must be objects")
    model_roles = [item.role for item in models]
    if len(set(model_roles)) != len(model_roles):
        raise ValueError("experiment model roles must be unique")

    manifest = ExperimentManifest(
        experiment_id=_nonempty(
            raw.get("experiment_id", ""),
            label="experiment_id",
        ),
        sport=_nonempty(raw.get("sport", ""), label="sport"),
        protocol_version=_nonempty(
            raw.get("protocol_version", ""),
            label="protocol_version",
        ),
        repository_commit=_repository_commit(
            raw.get("repository_commit", ""),
        ),
        observability_registry_path=_portable(
            registry_path,
            base=output.parent,
        ),
        observability_registry_sha256=sha256_file(registry_path),
        targets=targets,
        acquisition=acquisition,
        sources=sources,
        models=models,
        notes=_string_list(raw.get("notes", []), label="notes"),
    )
    output.write_text(
        json.dumps(manifest.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def verify_experiment_manifest(
    manifest_path: str | Path,
) -> dict[str, object]:
    manifest = Path(manifest_path).resolve()
    raw = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("experiment manifest must contain a JSON object")
    if raw.get("schema_version") != EXPERIMENT_SCHEMA_VERSION:
        raise ValueError("unsupported experiment manifest schema")
    _repository_commit(raw.get("repository_commit", ""))

    registry_raw = raw.get("observability_registry")
    if not isinstance(registry_raw, dict):
        raise TypeError("experiment observability_registry must be an object")
    registry_path = _resolve(
        _nonempty(
            registry_raw.get("path", ""),
            label="observability_registry.path",
        ),
        base=manifest.parent,
    )
    expected_registry_hash = _nonempty(
        registry_raw.get("sha256", ""),
        label="observability_registry.sha256",
    )
    if sha256_file(registry_path) != expected_registry_hash:
        raise ValueError("observability registry hash mismatch")
    registry = load_observability_registry(registry_path)
    variables = registry.by_id()

    targets = _string_list(raw.get("targets", []), label="targets")
    for target in targets:
        variable = variables.get(target)
        if variable is None:
            raise ValueError(
                f"experiment target missing from registry: {target}"
            )
        if not variable.teacher_eligible:
            raise ValueError(
                f"experiment target is not teacher-eligible: {target}"
            )

    sources_raw = raw.get("sources")
    if not isinstance(sources_raw, list) or not sources_raw:
        raise ValueError("experiment manifest requires sources")
    for index, item in enumerate(sources_raw):
        if not isinstance(item, dict):
            raise TypeError(f"experiment source {index} must be an object")
        path = _resolve(
            _nonempty(item.get("path", ""), label=f"source {index}.path"),
            base=manifest.parent,
        )
        expected = _nonempty(
            item.get("sha256", ""),
            label=f"source {index}.sha256",
        )
        source_type = _nonempty(
            item.get("source_type", ""),
            label=f"source {index}.source_type",
        )
        if source_type == "session":
            reader = SessionReader(path)
            actual = session_evidence_sha256(reader)
            if str(item.get("session_id", "")) != reader.manifest.session_id:
                raise ValueError(
                    f"experiment source {index} session ID mismatch"
                )
        elif source_type == "artifact":
            actual = sha256_file(path)
        else:
            raise ValueError(
                f"unsupported experiment source_type: {source_type}"
            )
        if actual != expected:
            raise ValueError(
                f"experiment source hash mismatch at index {index}"
            )

    models_raw = raw.get("models", [])
    if not isinstance(models_raw, list):
        raise TypeError("experiment models must be a list")
    for index, item in enumerate(models_raw):
        if not isinstance(item, dict):
            raise TypeError(f"experiment model {index} must be an object")
        weights_path = item.get("weights_path")
        weights_hash = item.get("weights_sha256")
        if weights_path is None and weights_hash is None:
            continue
        if not isinstance(weights_path, str) or not isinstance(
            weights_hash,
            str,
        ):
            raise TypeError(
                f"experiment model {index} weights path/hash must coexist"
            )
        resolved = _resolve(weights_path, base=manifest.parent)
        if sha256_file(resolved) != weights_hash:
            raise ValueError(
                f"experiment model weights hash mismatch at index {index}"
            )

    return {
        "schema_version": EXPERIMENT_SCHEMA_VERSION,
        "experiment_id": raw.get("experiment_id"),
        "passed": True,
        "source_count": len(sources_raw),
        "target_count": len(targets),
        "model_count": len(models_raw),
        "manifest_sha256": sha256_file(manifest),
    }


@dataclass(frozen=True)
class GroupedSplit:
    purpose: str
    seed: str
    group_by: tuple[str, ...]
    fractions: dict[str, float]
    source_index_sha256: str
    assignments: dict[str, tuple[str, ...]]
    group_assignments: dict[str, str]
    sample_count: int
    group_count: int
    leakage_check_passed: bool
    schema_version: str = SPLIT_SCHEMA_VERSION

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "purpose": self.purpose,
            "policy": "sha256_group_order_apportioned_partition_v1",
            "seed": self.seed,
            "group_by": list(self.group_by),
            "fractions": dict(self.fractions),
            "source_index_sha256": self.source_index_sha256,
            "sample_count": self.sample_count,
            "group_count": self.group_count,
            "assignments": {
                key: list(values)
                for key, values in self.assignments.items()
            },
            "group_assignments": dict(sorted(self.group_assignments.items())),
            "leakage_check": {
                "passed": self.leakage_check_passed,
                "definition": (
                    "no group key appears in more than one split"
                ),
            },
        }


def _fraction(value: float, *, label: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number < 0 or number > 1:
        raise ValueError(f"{label} must be between 0 and 1")
    return number


def _sample_index(path: str | Path) -> list[dict[str, object]]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    samples = raw.get("samples") if isinstance(raw, dict) else raw
    if not isinstance(samples, list):
        raise TypeError("sample index must be a list or object with samples")
    result: list[dict[str, object]] = []
    ids: set[str] = set()
    for index, item in enumerate(samples):
        if not isinstance(item, dict):
            raise TypeError(f"sample {index} must be an object")
        sample = dict(item)
        sample_id = _nonempty(
            sample.get("sample_id", ""),
            label=f"sample {index}.sample_id",
        )
        if sample_id in ids:
            raise ValueError(f"duplicate sample_id: {sample_id}")
        ids.add(sample_id)
        result.append(sample)
    if not result:
        raise ValueError("sample index must not be empty")
    return result


def _group_key(sample: dict[str, object], fields: tuple[str, ...]) -> str:
    values: list[str] = []
    for field in fields:
        if field not in sample:
            raise ValueError(
                f"sample {sample['sample_id']!r} missing group field {field!r}"
            )
        value = str(sample[field]).strip()
        if not value:
            raise ValueError(
                f"sample {sample['sample_id']!r} has empty group field {field!r}"
            )
        values.append(value)
    return json.dumps(values, separators=(",", ":"), ensure_ascii=True)


def build_grouped_split(
    index_path: str | Path,
    output_path: str | Path,
    *,
    group_by: tuple[str, ...],
    seed: str,
    train_fraction: float = 0.7,
    validation_fraction: float = 0.15,
    purpose: str = "primary",
) -> GroupedSplit:
    if purpose not in ALLOWED_SPLIT_PURPOSES:
        raise ValueError(
            "split purpose must be one of "
            + ", ".join(sorted(ALLOWED_SPLIT_PURPOSES))
        )
    if not group_by:
        raise ValueError("group_by must contain at least one field")
    if len(set(group_by)) != len(group_by):
        raise ValueError("group_by fields must be unique")
    if purpose == "primary" and not (set(group_by) & PRIMARY_GROUP_FIELDS):
        raise ValueError(
            "primary split must group by an acquisition-level field such as "
            "run_id, day_id, remount_id, repetition_id, camera_view, "
            "subject_id, sport, or intensity"
        )
    seed = _nonempty(seed, label="seed")
    train = _fraction(train_fraction, label="train_fraction")
    validation = _fraction(
        validation_fraction,
        label="validation_fraction",
    )
    if train + validation >= 1.0:
        raise ValueError(
            "train_fraction + validation_fraction must be < 1"
        )
    test = 1.0 - train - validation

    samples = _sample_index(index_path)
    groups: dict[str, list[str]] = {}
    for sample in samples:
        key = _group_key(sample, group_by)
        groups.setdefault(key, []).append(str(sample["sample_id"]))

    assignments: dict[str, list[str]] = {
        "train": [],
        "validation": [],
        "test": [],
    }
    fractions = {
        "train": train,
        "validation": validation,
        "test": test,
    }
    positive_splits = [
        name for name, fraction in fractions.items() if fraction > 0
    ]
    if len(groups) < len(positive_splits):
        raise ValueError(
            "not enough independent groups to populate every requested split"
        )

    ordered_groups = sorted(
        groups,
        key=lambda key: hashlib.sha256(
            (seed + "\0" + key).encode("utf-8")
        ).digest(),
    )
    raw_counts = {
        name: fractions[name] * len(ordered_groups)
        for name in fractions
    }
    counts = {
        name: math.floor(raw_counts[name])
        for name in fractions
    }
    remainder = len(ordered_groups) - sum(counts.values())
    remainder_order = sorted(
        fractions,
        key=lambda name: (
            raw_counts[name] - counts[name],
            fractions[name],
            name,
        ),
        reverse=True,
    )
    for index in range(remainder):
        counts[remainder_order[index % len(remainder_order)]] += 1

    for name in positive_splits:
        if counts[name] > 0:
            continue
        donors = sorted(
            (
                donor
                for donor in positive_splits
                if counts[donor] > 1
            ),
            key=lambda donor: (
                counts[donor],
                fractions[donor],
                donor,
            ),
            reverse=True,
        )
        if not donors:
            raise ValueError(
                "unable to allocate a non-empty requested split"
            )
        counts[donors[0]] -= 1
        counts[name] += 1

    group_split: dict[str, str] = {}
    cursor = 0
    for split in ("train", "validation", "test"):
        stop = cursor + counts[split]
        for key in ordered_groups[cursor:stop]:
            group_split[key] = split
            assignments[split].extend(sorted(groups[key]))
        cursor = stop

    seen_groups: dict[str, str] = {}
    leakage = False
    for key, split in group_split.items():
        prior = seen_groups.setdefault(key, split)
        if prior != split:
            leakage = True

    result = GroupedSplit(
        purpose=purpose,
        seed=seed,
        group_by=group_by,
        fractions={
            "train": train,
            "validation": validation,
            "test": test,
        },
        source_index_sha256=sha256_file(Path(index_path)),
        assignments={
            name: tuple(sorted(values))
            for name, values in assignments.items()
        },
        group_assignments=dict(group_split),
        sample_count=len(samples),
        group_count=len(groups),
        leakage_check_passed=not leakage,
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(result.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def verify_grouped_split(
    split_path: str | Path,
    index_path: str | Path,
) -> dict[str, object]:
    split_file = Path(split_path)
    index_file = Path(index_path)
    raw = json.loads(split_file.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("grouped split must contain a JSON object")
    if raw.get("schema_version") != SPLIT_SCHEMA_VERSION:
        raise ValueError("unsupported grouped split schema")
    if raw.get("source_index_sha256") != sha256_file(index_file):
        raise ValueError("grouped split source index hash mismatch")

    group_by = _string_list(raw.get("group_by", []), label="group_by")
    if not group_by:
        raise ValueError("grouped split group_by must not be empty")
    samples = _sample_index(index_file)
    sample_by_id = {
        str(sample["sample_id"]): sample
        for sample in samples
    }

    assignments_raw = raw.get("assignments")
    if not isinstance(assignments_raw, dict):
        raise TypeError("grouped split assignments must be an object")
    group_assignments = raw.get("group_assignments")
    if not isinstance(group_assignments, dict):
        raise TypeError("grouped split group_assignments must be an object")

    seen: dict[str, str] = {}
    for split in ("train", "validation", "test"):
        sample_ids = assignments_raw.get(split)
        if not isinstance(sample_ids, list):
            raise TypeError(
                f"grouped split assignments.{split} must be a list"
            )
        for sample_id_raw in sample_ids:
            sample_id = str(sample_id_raw)
            if sample_id not in sample_by_id:
                raise ValueError(
                    f"grouped split references unknown sample: {sample_id}"
                )
            if sample_id in seen:
                raise ValueError(
                    f"sample appears in multiple splits: {sample_id}"
                )
            seen[sample_id] = split

            key = _group_key(sample_by_id[sample_id], group_by)
            expected_split = group_assignments.get(key)
            if expected_split != split:
                raise ValueError(
                    f"group leakage or stale group assignment: {key}"
                )

    missing = sorted(set(sample_by_id) - set(seen))
    if missing:
        raise ValueError(
            "grouped split omits samples: " + ", ".join(missing)
        )

    expected_groups = {
        _group_key(sample, group_by)
        for sample in samples
    }
    if set(group_assignments) != expected_groups:
        raise ValueError(
            "grouped split group assignment set does not match source index"
        )

    return {
        "schema_version": SPLIT_SCHEMA_VERSION,
        "passed": True,
        "sample_count": len(samples),
        "group_count": len(expected_groups),
        "split_sha256": sha256_file(split_file),
        "source_index_sha256": sha256_file(index_file),
    }
