from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

from .provenance import sha256_file

PUBLIC_EXPORT_SCHEMA_VERSION = "motionos.public-export.v1"
DATASET_REGISTRY_SCHEMA_VERSION = "motionos.external-dataset-registry.v1"

CLASSIFICATIONS = {
    "raw_identifying",
    "pseudonymized_sensitive",
    "derived_restricted",
    "publishable",
    "synthetic",
}
PUBLIC_CLASSIFICATIONS = {"publishable", "synthetic"}
RELEASE_BASES = {
    "synthetic",
    "self_authorized",
    "participant_consent",
    "external_dataset_license",
}
_PARTICIPANT_ID = re.compile(r"^p-[a-z0-9]{8,32}$")


def validate_participant_id(value: str) -> str:
    participant_id = value.strip().lower()
    if not _PARTICIPANT_ID.fullmatch(participant_id):
        raise ValueError(
            "participant IDs must use p- followed by 8-32 lowercase "
            "alphanumeric characters and contain no identifying semantics"
        )
    return participant_id


@dataclass(frozen=True)
class PublicExportArtifact:
    path: str
    sha256: str
    classification: str
    release_basis: str
    participant_id: str | None
    consent_reference: str | None
    license_id: str | None
    transformation: str | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def _text(value: object, *, label: str) -> str:
    result = str(value).strip()
    if not result:
        raise ValueError(f"{label} must be non-empty")
    return result


def _optional_text(value: object) -> str | None:
    if value is None:
        return None
    result = str(value).strip()
    return result or None


def _artifact(
    item: dict[str, object],
    *,
    index: int,
    manifest_dir: Path,
) -> PublicExportArtifact:
    raw_path = _text(item.get("path", ""), label=f"artifact {index}.path")
    path = Path(raw_path)
    if not path.is_absolute():
        path = (manifest_dir / path).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"public export artifact does not exist: {path}")

    expected = _text(
        item.get("sha256", ""),
        label=f"artifact {index}.sha256",
    ).lower()
    actual = sha256_file(path)
    if actual != expected:
        raise ValueError(f"public export artifact hash mismatch: {raw_path}")

    classification = _text(
        item.get("classification", ""),
        label=f"artifact {index}.classification",
    )
    if classification not in CLASSIFICATIONS:
        raise ValueError(
            f"artifact {index}.classification must be one of "
            + ", ".join(sorted(CLASSIFICATIONS))
        )
    if classification not in PUBLIC_CLASSIFICATIONS:
        raise ValueError(
            f"artifact {raw_path!r} is classified {classification!r} "
            "and is not eligible for the default public-export path"
        )

    release_basis = _text(
        item.get("release_basis", ""),
        label=f"artifact {index}.release_basis",
    )
    if release_basis not in RELEASE_BASES:
        raise ValueError(
            f"artifact {index}.release_basis must be one of "
            + ", ".join(sorted(RELEASE_BASES))
        )

    participant_id = _optional_text(item.get("participant_id"))
    consent_reference = _optional_text(item.get("consent_reference"))
    license_id = _optional_text(item.get("license_id"))
    transformation = _optional_text(item.get("transformation"))

    if participant_id is not None:
        participant_id = validate_participant_id(participant_id)

    if classification == "synthetic":
        if release_basis != "synthetic":
            raise ValueError(
                "synthetic artifacts require release_basis='synthetic'"
            )
        if participant_id is not None:
            raise ValueError("synthetic artifacts must not name a participant")
    elif release_basis == "synthetic":
        raise ValueError(
            "non-synthetic artifacts cannot use release_basis='synthetic'"
        )

    if (
        release_basis == "participant_consent"
        and (participant_id is None or consent_reference is None)
    ):
        raise ValueError(
            "participant_consent requires participant_id and "
            "consent_reference"
        )
    if release_basis == "external_dataset_license" and license_id is None:
        raise ValueError(
            "external_dataset_license requires license_id"
        )

    return PublicExportArtifact(
        path=raw_path,
        sha256=actual,
        classification=classification,
        release_basis=release_basis,
        participant_id=participant_id,
        consent_reference=consent_reference,
        license_id=license_id,
        transformation=transformation,
    )


def validate_public_export_manifest(
    manifest_path: str | Path,
) -> dict[str, object]:
    manifest = Path(manifest_path).resolve()
    raw = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("public export manifest must contain a JSON object")
    if raw.get("schema_version") != PUBLIC_EXPORT_SCHEMA_VERSION:
        raise ValueError("unsupported public export schema")

    export_id = _text(raw.get("export_id", ""), label="export_id")
    purpose = _text(raw.get("purpose", ""), label="purpose")
    artifacts_raw = raw.get("artifacts")
    if not isinstance(artifacts_raw, list) or not artifacts_raw:
        raise ValueError("public export requires a non-empty artifacts list")

    artifacts: list[PublicExportArtifact] = []
    for index, item in enumerate(artifacts_raw):
        if not isinstance(item, dict):
            raise TypeError(f"artifact {index} must be an object")
        artifacts.append(
            _artifact(
                dict(item),
                index=index,
                manifest_dir=manifest.parent,
            )
        )

    attestations = raw.get("attestations")
    if not isinstance(attestations, dict):
        raise TypeError("public export attestations must be an object")
    required = (
        "raw_identifying_excluded",
        "consent_or_license_verified",
        "metadata_minimized",
    )
    missing = [key for key in required if attestations.get(key) is not True]
    if missing:
        raise ValueError(
            "public export attestations must be true: "
            + ", ".join(missing)
        )

    paths = [item.path for item in artifacts]
    if len(set(paths)) != len(paths):
        raise ValueError("public export artifact paths must be unique")

    external_license_ids = {
        item.license_id
        for item in artifacts
        if item.release_basis == "external_dataset_license"
        and item.license_id is not None
    }
    if external_license_ids:
        registry_ref = raw.get("dataset_registry")
        if not isinstance(registry_ref, dict):
            raise TypeError(
                "external-dataset public export requires dataset_registry"
            )
        registry_path_raw = _text(
            registry_ref.get("path", ""),
            label="dataset_registry.path",
        )
        registry_path = Path(registry_path_raw)
        if not registry_path.is_absolute():
            registry_path = (manifest.parent / registry_path).resolve()
        expected_registry_hash = _text(
            registry_ref.get("sha256", ""),
            label="dataset_registry.sha256",
        ).lower()
        if sha256_file(registry_path) != expected_registry_hash:
            raise ValueError("dataset registry hash mismatch")

        registry_data = json.loads(
            registry_path.read_text(encoding="utf-8")
        )
        if not isinstance(registry_data, dict):
            raise TypeError("dataset registry must contain a JSON object")
        if (
            registry_data.get("schema_version")
            != DATASET_REGISTRY_SCHEMA_VERSION
        ):
            raise ValueError("unsupported external dataset registry schema")
        entries = registry_data.get("datasets")
        if not isinstance(entries, list):
            raise TypeError("dataset registry datasets must be a list")
        by_id = {
            str(item.get("dataset_id", "")): item
            for item in entries
            if isinstance(item, dict)
        }
        for license_id in sorted(external_license_ids):
            entry = by_id.get(license_id)
            if entry is None:
                raise ValueError(
                    f"public export references unknown dataset: {license_id}"
                )
            if entry.get("authorization_status") != "authorized_local_copy":
                raise ValueError(
                    f"dataset is not marked authorized: {license_id}"
                )
            if entry.get("redistribution_permitted") is not True:
                raise ValueError(
                    f"dataset redistribution is not permitted: {license_id}"
                )

    return {
        "schema_version": PUBLIC_EXPORT_SCHEMA_VERSION,
        "export_id": export_id,
        "purpose": purpose,
        "passed": True,
        "artifact_count": len(artifacts),
        "classifications": sorted(
            {item.classification for item in artifacts}
        ),
        "release_bases": sorted(
            {item.release_basis for item in artifacts}
        ),
        "manifest_sha256": sha256_file(manifest),
        "claim_boundary": (
            "A passing validator confirms the repository's conservative "
            "public-export policy and file hashes. It is not legal advice "
            "and does not independently prove consent or license validity."
        ),
    }


def validate_external_dataset_registry(
    registry_path: str | Path,
) -> dict[str, object]:
    path = Path(registry_path).resolve()
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise TypeError("dataset registry must contain a JSON object")
    if raw.get("schema_version") != DATASET_REGISTRY_SCHEMA_VERSION:
        raise ValueError("unsupported external dataset registry schema")

    entries = raw.get("datasets")
    if not isinstance(entries, list):
        raise TypeError("dataset registry datasets must be a list")

    ids: set[str] = set()
    for index, item in enumerate(entries):
        if not isinstance(item, dict):
            raise TypeError(f"dataset {index} must be an object")
        dataset_id = _text(
            item.get("dataset_id", ""),
            label=f"dataset {index}.dataset_id",
        )
        if dataset_id in ids:
            raise ValueError(f"duplicate dataset_id: {dataset_id}")
        ids.add(dataset_id)
        _text(item.get("name", ""), label=f"dataset {index}.name")
        _text(
            item.get("source_reference", ""),
            label=f"dataset {index}.source_reference",
        )
        _text(
            item.get("license_or_terms_reference", ""),
            label=f"dataset {index}.license_or_terms_reference",
        )
        status = _text(
            item.get("authorization_status", ""),
            label=f"dataset {index}.authorization_status",
        )
        if status not in {
            "not_acquired",
            "authorized_local_copy",
            "review_required",
        }:
            raise ValueError(
                f"dataset {index}.authorization_status is unsupported"
            )
        if not isinstance(item.get("redistribution_permitted"), bool):
            raise TypeError(
                f"dataset {index}.redistribution_permitted must be boolean"
            )

    return {
        "schema_version": DATASET_REGISTRY_SCHEMA_VERSION,
        "passed": True,
        "dataset_count": len(entries),
        "registry_sha256": sha256_file(path),
    }
