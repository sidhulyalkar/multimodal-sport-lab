from __future__ import annotations

import hashlib
from pathlib import Path

from .session import SessionReader


def sha256_file(path: str | Path) -> str:
    source = Path(path)
    digest = hashlib.sha256()
    with source.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def session_evidence_files(reader: SessionReader) -> tuple[Path, ...]:
    """Return the immutable/session-source files that define a MotionOS bundle.

    Qualification receipts written later into the session root are deliberately
    excluded so that adding an analysis artifact does not change the identity
    of the captured/imported source evidence.
    """

    root = reader.root
    paths: set[Path] = {
        root / "manifest.json",
        root / "index.json",
    }

    streams = reader.index.get("streams", {})
    if not isinstance(streams, dict):
        raise TypeError("session index streams must be an object")

    for info in streams.values():
        if not isinstance(info, dict) or "path" not in info:
            raise TypeError("session stream index entry is malformed")
        paths.add(root / str(info["path"]))

    metadata_dir = root / "metadata"
    if metadata_dir.exists():
        paths.update(path for path in metadata_dir.rglob("*") if path.is_file())

    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "session evidence file is missing: "
            + ", ".join(str(path) for path in sorted(missing))
        )

    return tuple(sorted(paths, key=lambda path: path.relative_to(root).as_posix()))


def session_evidence_sha256(reader: SessionReader) -> str:
    """Fingerprint the exact MotionOS source bundle without mutating it."""

    digest = hashlib.sha256()
    for path in session_evidence_files(reader):
        relative = path.relative_to(reader.root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(len(chunk).to_bytes(8, "big"))
                digest.update(chunk)
    return digest.hexdigest()


def source_evidence_hashes(reader: SessionReader) -> dict[str, str]:
    raw = reader.manifest.metadata.get("source_evidence_sha256")
    if not isinstance(raw, dict):
        return {}
    return {
        str(key): str(value)
        for key, value in raw.items()
    }
