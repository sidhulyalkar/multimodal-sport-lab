from __future__ import annotations

import json
import re
from pathlib import Path

TOTALCAPTURE_INDEX_SCHEMA_VERSION = "motionos.public-totalcapture-index.v1"
_SUBJECT = re.compile(r"^[sS](\\d+)$")


def index_totalcapture(
    root_path: str | Path,
    output_path: str | Path,
) -> dict[str, object]:
    """Index an already-authorized local TotalCapture extraction.

    MotionOS does not download or redistribute TotalCapture. This adapter accepts
    the common per-subject/per-sequence layout where each sequence directory
    contains Vicon global position ground truth plus Xsens sensor evidence and
    may contain one or more camera videos.
    """

    root = Path(root_path).resolve()
    if not root.is_dir():
        raise FileNotFoundError(f"TotalCapture root does not exist: {root}")

    samples: list[dict[str, object]] = []
    for subject_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        match = _SUBJECT.match(subject_dir.name)
        if match is None:
            continue
        subject_id = f"s{int(match.group(1))}"

        for gt_path in sorted(subject_dir.rglob("gt_skel_gbl_pos.txt")):
            sequence_dir = gt_path.parent
            sequence = sequence_dir.name
            sensor_files = sorted(
                path
                for path in sequence_dir.iterdir()
                if path.is_file()
                and path.suffix == ".sensors"
                and "xsens" in path.name.lower()
            )
            videos = sorted(
                path
                for path in sequence_dir.iterdir()
                if path.is_file()
                and path.suffix.lower() in {".mp4", ".mov"}
                and "cam" in path.name.lower()
            )
            orientation = sequence_dir / "gt_skel_gbl_ori.txt"

            if not sensor_files:
                continue

            sample_id = f"totalcapture/{subject_id}/{sequence}"
            samples.append(
                {
                    "sample_id": sample_id,
                    "dataset": "TotalCapture",
                    "subject_id": subject_id,
                    "sport": "public-human-motion",
                    "day_id": "official-capture",
                    "remount_id": f"{subject_id}-official",
                    "run_id": sample_id,
                    "repetition_id": sequence,
                    "camera_view": (
                        "multi-view"
                        if len(videos) > 1
                        else ("single-view" if videos else "none")
                    ),
                    "intensity": sequence,
                    "modalities": {
                        "imu": [
                            str(path.relative_to(root))
                            for path in sensor_files
                        ],
                        "vicon_position": str(gt_path.relative_to(root)),
                        "vicon_orientation": (
                            str(orientation.relative_to(root))
                            if orientation.is_file()
                            else None
                        ),
                        "video": [
                            str(path.relative_to(root))
                            for path in videos
                        ],
                    },
                }
            )

    if not samples:
        raise ValueError(
            "no TotalCapture sequences found with both "
            "gt_skel_gbl_pos.txt and an Xsens .sensors file"
        )

    payload = {
        "schema_version": TOTALCAPTURE_INDEX_SCHEMA_VERSION,
        "dataset": "TotalCapture",
        "root": ".",
        "samples": samples,
        "claim_boundary": (
            "This index inventories a local, separately authorized "
            "TotalCapture extraction. It does not redistribute dataset bytes "
            "or qualify MotionOS physical hardware."
        ),
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload
