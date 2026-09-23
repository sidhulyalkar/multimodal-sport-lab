import hashlib
import json

import pytest

from motionos.data_governance import (
    validate_external_dataset_registry,
    validate_participant_id,
    validate_public_export_manifest,
)


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_participant_id_is_pseudonymous_and_nonsemantic():
    assert validate_participant_id("p-a1b2c3d4") == "p-a1b2c3d4"

    with pytest.raises(ValueError, match="participant IDs"):
        validate_participant_id("sid-hulyalkar")


def test_public_export_accepts_synthetic_and_hash_verifies(tmp_path):
    artifact = tmp_path / "demo.json"
    artifact.write_text('{"synthetic":true}\n', encoding="utf-8")
    manifest = tmp_path / "export.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": "motionos.public-export.v1",
                "export_id": "demo-export-v1",
                "purpose": "repository demo",
                "artifacts": [
                    {
                        "path": "demo.json",
                        "sha256": _sha(artifact),
                        "classification": "synthetic",
                        "release_basis": "synthetic",
                    }
                ],
                "attestations": {
                    "raw_identifying_excluded": True,
                    "consent_or_license_verified": True,
                    "metadata_minimized": True,
                },
            }
        ),
        encoding="utf-8",
    )

    result = validate_public_export_manifest(manifest)

    assert result["passed"] is True
    assert result["artifact_count"] == 1
    assert result["classifications"] == ["synthetic"]


def test_public_export_rejects_raw_identifying_artifact(tmp_path):
    artifact = tmp_path / "camera.mov"
    artifact.write_bytes(b"identifying-video")
    manifest = tmp_path / "export.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": "motionos.public-export.v1",
                "export_id": "bad-export",
                "purpose": "test",
                "artifacts": [
                    {
                        "path": "camera.mov",
                        "sha256": _sha(artifact),
                        "classification": "raw_identifying",
                        "release_basis": "self_authorized",
                    }
                ],
                "attestations": {
                    "raw_identifying_excluded": True,
                    "consent_or_license_verified": True,
                    "metadata_minimized": True,
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="not eligible"):
        validate_public_export_manifest(manifest)


def test_public_export_rejects_tampered_file(tmp_path):
    artifact = tmp_path / "result.json"
    artifact.write_text("{}\n", encoding="utf-8")
    digest = _sha(artifact)
    artifact.write_text('{"changed":true}\n', encoding="utf-8")

    manifest = tmp_path / "export.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": "motionos.public-export.v1",
                "export_id": "tampered",
                "purpose": "test",
                "artifacts": [
                    {
                        "path": "result.json",
                        "sha256": digest,
                        "classification": "publishable",
                        "release_basis": "self_authorized",
                    }
                ],
                "attestations": {
                    "raw_identifying_excluded": True,
                    "consent_or_license_verified": True,
                    "metadata_minimized": True,
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="hash mismatch"):
        validate_public_export_manifest(manifest)


def test_participant_consent_requires_private_reference(tmp_path):
    artifact = tmp_path / "derived.json"
    artifact.write_text("{}\n", encoding="utf-8")
    manifest = tmp_path / "export.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": "motionos.public-export.v1",
                "export_id": "consent-test",
                "purpose": "test",
                "artifacts": [
                    {
                        "path": "derived.json",
                        "sha256": _sha(artifact),
                        "classification": "publishable",
                        "release_basis": "participant_consent",
                        "participant_id": "p-a1b2c3d4",
                    }
                ],
                "attestations": {
                    "raw_identifying_excluded": True,
                    "consent_or_license_verified": True,
                    "metadata_minimized": True,
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="consent_reference"):
        validate_public_export_manifest(manifest)


def test_dataset_registry_requires_explicit_redistribution_policy(tmp_path):
    registry = tmp_path / "datasets.json"
    registry.write_text(
        json.dumps(
            {
                "schema_version": "motionos.external-dataset-registry.v1",
                "datasets": [
                    {
                        "dataset_id": "example",
                        "name": "Example Dataset",
                        "source_reference": "owner landing page",
                        "license_or_terms_reference": "owner terms",
                        "authorization_status": "review_required",
                        "redistribution_permitted": False,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    result = validate_external_dataset_registry(registry)
    assert result["passed"] is True
    assert result["dataset_count"] == 1
