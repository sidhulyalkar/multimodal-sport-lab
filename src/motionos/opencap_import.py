"""Import existing OpenCap/OpenSim simulations as source-bound MotionOS viewer data.

No OpenSim dependency, inverse dynamics, solver validation, or muscle inference
happens here. This reads an already-generated OpenSim Storage table.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = "motionos.opencap-simulation.v1"
MAX_BYTES = 64 * 1024 * 1024
MAX_ROWS = 100_000
MAX_COLUMNS = 512


@dataclass(frozen=True)
class StorageTable:
    columns: tuple[str, ...]
    rows: tuple[tuple[float, ...], ...]
    in_degrees: bool | None


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_storage_table(path: str | Path) -> StorageTable:
    """Parse .mot/.sto, rejecting malformed, ambiguous and unbounded inputs."""
    source = Path(path)
    if source.suffix.lower() not in {".mot", ".sto"}:
        raise ValueError("OpenSim source must be a .mot or .sto file")
    if not source.is_file() or source.stat().st_size > MAX_BYTES:
        raise ValueError("OpenSim source is absent or exceeds 64 MiB")
    metadata: dict[str, str] = {}
    with source.open("r", encoding="utf-8-sig", errors="strict") as stream:
        for i, line in enumerate(stream):
            if i > 200:
                raise ValueError("OpenSim endheader was not found within 200 lines")
            stripped = line.strip()
            if stripped.lower() == "endheader":
                break
            if "=" in stripped:
                name, value = stripped.split("=", 1)
                key = name.strip().lower()
                if key in metadata:
                    raise ValueError(f"duplicate OpenSim header key: {key}")
                metadata[key] = value.strip()
        else:
            raise ValueError("OpenSim file has no endheader sentinel")
        labels_line = next((line.strip() for line in stream if line.strip()), "")
        columns = tuple(labels_line.split())
        if not 2 <= len(columns) <= MAX_COLUMNS or columns[0].lower() != "time":
            raise ValueError("OpenSim table needs time and 1-511 channels")
        if len(set(columns)) != len(columns):
            raise ValueError("OpenSim channel labels must be unique")
        if "ncolumns" in metadata and int(metadata["ncolumns"]) != len(columns):
            raise ValueError("OpenSim nColumns does not match channel headers")
        rows: list[tuple[float, ...]] = []
        last_time = -math.inf
        for line in stream:
            if not line.strip():
                continue
            if len(rows) >= MAX_ROWS:
                raise ValueError("OpenSim table exceeds row safety limit")
            parts = line.split()
            if len(parts) != len(columns):
                raise ValueError(f"OpenSim row {len(rows) + 1} has wrong column count")
            try:
                row = tuple(float(part) for part in parts)
            except ValueError as exc:
                raise ValueError("OpenSim table contains a nonnumeric value") from exc
            if not all(math.isfinite(v) for v in row):
                raise ValueError("OpenSim table contains a nonfinite value")
            if row[0] <= last_time:
                raise ValueError("OpenSim time must be strictly increasing")
            last_time = row[0]
            rows.append(row)
    if len(rows) < 2:
        raise ValueError("OpenSim table requires at least two frames")
    if "nrows" in metadata and int(metadata["nrows"]) != len(rows):
        raise ValueError("OpenSim nRows does not match the data")
    raw_degrees = metadata.get("indegrees")
    if raw_degrees is not None and raw_degrees.lower() not in {"yes", "no"}:
        raise ValueError("OpenSim inDegrees must be yes or no")
    return StorageTable(
        columns=columns,
        rows=tuple(rows),
        in_degrees=None if raw_degrees is None else raw_degrees.lower() == "yes",
    )


def build_simulation_artifact(
    source_path: str | Path,
    *,
    model_name: str,
    trial_name: str,
    model_path: str | Path | None = None,
) -> dict[str, object]:
    """Make unqualified model estimates explicit and retain original evidence."""
    if not model_name.strip() or not trial_name.strip():
        raise ValueError("model_name and trial_name must be explicitly provided")
    source = Path(source_path).resolve(strict=True)
    table = read_storage_table(source)
    names = table.columns[1:]
    activation_names = tuple(c for c in names if c.endswith("/activation"))
    kinematic_names = tuple(c for c in names if not c.endswith("/activation"))
    if not kinematic_names:
        raise ValueError("OpenCap simulation needs joint kinematic channels")
    frames = []
    for row in table.rows:
        activation = {
            name.removesuffix("/activation"): row[i]
            for i, name in enumerate(table.columns)
            if name in activation_names
        }
        if any(not 0 <= value <= 1 for value in activation.values()):
            raise ValueError("activation must be within [0, 1]")
        frames.append({
            "time_s": row[0],
            "joint_coordinates": {
                name: row[i]
                for i, name in enumerate(table.columns)
                if name in kinematic_names
            },
            "estimated_activations": activation,
        })
    model_source = None
    if model_path is not None:
        model_source_path = Path(model_path).resolve(strict=True)
        if not model_source_path.is_file() or model_source_path.suffix.lower() != ".osim":
            raise ValueError("model_path must be an OpenSim .osim file")
        if model_source_path == source:
            raise ValueError("model and simulation files must differ")
        model_source = {
            "sha256": _digest(model_source_path),
            "file_name": model_source_path.name,
        }
    rotation_units = (
        "unknown" if table.in_degrees is None
        else ("degrees" if table.in_degrees else "radians")
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "evidence_kind": "model_inferred",
        "display_label": "Simulated activation (not measured EMG)",
        "source": {
            "tool": "OpenCap / OpenSim compatible storage",
            "table_file_name": source.name,
            "table_sha256": _digest(source),
            "model_name": model_name,
            "model_file": model_source,
            "trial_name": trial_name,
            "solver_convergence_verified": False,
            "physical_validation_verified": False,
            "muscle_channel_identity_verified": False,
        },
        "channels": {
            "joint_coordinates": list(kinematic_names),
            "estimated_activations": [
                name.removesuffix("/activation") for name in activation_names
            ],
            "rotation_units": rotation_units,
            "translation_units": "model_defined_unverified",
        },
        "frames": frames,
        "limitations": [
            "Modeled activations are not measured EMG, muscle stress, or injury risk.",
            "Solver convergence and accuracy require independent qualification.",
            "Model coordinates need explicit mapping to MotionOS world space.",
            "No anatomical mesh, joint forces, or personalized geometry is inferred.",
        ],
    }


def write_simulation_artifact(
    source_path: str | Path,
    output_path: str | Path,
    *,
    model_name: str,
    trial_name: str,
    model_path: str | Path | None = None,
) -> Path:
    source = Path(source_path).resolve(strict=True)
    target = Path(output_path).resolve()
    if target == source or (model_path and target == Path(model_path).resolve()):
        raise ValueError("derived output may not overwrite immutable source evidence")
    artifact = build_simulation_artifact(
        source, model_name=model_name, trial_name=trial_name, model_path=model_path
    )
    with target.open("x", encoding="utf-8") as stream:
        json.dump(artifact, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description="Import existing OpenCap results")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--trial-name", required=True)
    parser.add_argument("--model-file", type=Path)
    args = parser.parse_args()
    print(write_simulation_artifact(
        args.source, args.output, model_name=args.model_name,
        trial_name=args.trial_name, model_path=args.model_file,
    ))


if __name__ == "__main__":
    main()
