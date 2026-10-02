from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.parse import urlparse

PUBLIC_VIDEO_CATALOG_SCHEMA_VERSION = "motionos.public-video-catalog.v1"

_ALLOWED_PLATFORMS = {"youtube", "instagram", "tiktok", "other"}
_ALLOWED_RIGHTS = {
    "creative_commons",
    "explicit_permission",
    "platform_only",
    "unknown",
}
_ALLOWED_RETENTION = {
    "derived_only",
    "authorized_local_copy",
}


def _stable_source_id(platform: str, source_url: str) -> str:
    digest = hashlib.sha256(source_url.encode("utf-8")).hexdigest()[:16]
    return f"{platform}/{digest}"


def _validate_url(raw: object) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("source_url must be a non-empty string")
    value = raw.strip()
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError("source_url must be an https URL")
    return value


def _optional_text(record: dict[str, object], key: str) -> str | None:
    value = record.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string when provided")
    value = value.strip()
    return value or None


def _segment(record: dict[str, object]) -> dict[str, float] | None:
    raw = record.get("segment")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("segment must be an object")
    start = raw.get("start_seconds", 0.0)
    end = raw.get("end_seconds")
    if not isinstance(start, (int, float)) or start < 0:
        raise ValueError("segment.start_seconds must be >= 0")
    if not isinstance(end, (int, float)) or end <= start:
        raise ValueError("segment.end_seconds must be greater than start_seconds")
    return {
        "start_seconds": float(start),
        "end_seconds": float(end),
    }


def build_public_video_catalog(
    spec_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    """Validate a rights-aware catalog of public movement-video references.

    This function intentionally does not download media. It preserves source,
    permission, retention, and discovery provenance so downstream pose/board
    extraction can fail closed when raw-media use is not authorized.
    """

    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    if not isinstance(spec, dict):
        raise ValueError("public-video spec must be a JSON object")

    raw_records = spec.get("records")
    if not isinstance(raw_records, list) or not raw_records:
        raise ValueError("public-video spec requires a non-empty records list")

    records: list[dict[str, object]] = []
    seen: set[str] = set()

    for index, raw in enumerate(raw_records):
        if not isinstance(raw, dict):
            raise ValueError(f"records[{index}] must be an object")

        platform = raw.get("platform")
        if platform not in _ALLOWED_PLATFORMS:
            raise ValueError(
                f"records[{index}].platform must be one of "
                f"{sorted(_ALLOWED_PLATFORMS)}"
            )

        source_url = _validate_url(raw.get("source_url"))
        source_id = _optional_text(raw, "source_id") or _stable_source_id(
            str(platform),
            source_url,
        )
        if source_id in seen:
            raise ValueError(f"duplicate source_id: {source_id}")
        seen.add(source_id)

        rights = raw.get("rights_status", "unknown")
        if rights not in _ALLOWED_RIGHTS:
            raise ValueError(
                f"records[{index}].rights_status must be one of "
                f"{sorted(_ALLOWED_RIGHTS)}"
            )

        retention = raw.get("retention_policy", "derived_only")
        if retention not in _ALLOWED_RETENTION:
            raise ValueError(
                f"records[{index}].retention_policy must be one of "
                f"{sorted(_ALLOWED_RETENTION)}"
            )
        if (
            retention == "authorized_local_copy"
            and rights not in {"creative_commons", "explicit_permission"}
        ):
            raise ValueError(
                "authorized_local_copy requires creative_commons "
                "or explicit_permission rights"
            )

        discovery = raw.get("discovery")
        if discovery is not None and not isinstance(discovery, dict):
            raise ValueError("discovery must be an object when provided")

        labels = raw.get("weak_labels", [])
        if not isinstance(labels, list) or not all(
            isinstance(value, str) and value.strip()
            for value in labels
        ):
            raise ValueError("weak_labels must be a list of non-empty strings")

        records.append(
            {
                "source_id": source_id,
                "platform": platform,
                "source_url": source_url,
                "creator": _optional_text(raw, "creator"),
                "title": _optional_text(raw, "title"),
                "published_at": _optional_text(raw, "published_at"),
                "rights_status": rights,
                "rights_evidence": _optional_text(raw, "rights_evidence"),
                "retention_policy": retention,
                "segment": _segment(raw),
                "weak_labels": sorted(set(labels)),
                "discovery": discovery or {},
                "derived_artifacts": [],
            }
        )

    payload: dict[str, object] = {
        "schema_version": PUBLIC_VIDEO_CATALOG_SCHEMA_VERSION,
        "purpose": spec.get(
            "purpose",
            "Indo Board movement diversity and detector/event-model development",
        ),
        "records": records,
        "claim_boundary": (
            "Catalog entries are references and weak labels, not verified "
            "examples of ideal technique. Raw-media retention must follow "
            "the recorded rights_status and retention_policy."
        ),
    }

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
