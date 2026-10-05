import json
from pathlib import Path

import pytest

from motionos.replay_review import (
    REPLAY_REVIEW_FLAG_SCHEMA_VERSION,
    REPLAY_REVIEW_LEDGER_SCHEMA_VERSION,
    REPLAY_REVIEW_QUEUE_SCHEMA_VERSION,
    build_replay_review_queue,
    validate_replay_review_ledger,
)
from motionos.video_alignment import (
    VideoAlignmentAnchor,
    build_video_alignment,
    file_sha256,
)


def _alignment(tmp_path: Path) -> tuple[Path, str, str]:
    source = tmp_path / "action4.mp4"
    source.write_bytes(b"action4-source")
    receipt = build_video_alignment(
        source,
        run_id="run-1",
        video_duration_ns=10_000_000_000,
        reference_start_ns=0,
        reference_end_ns=10_000_000_000,
        anchors=[
            VideoAlignmentAnchor(
                label="start",
                video_pts_ns=1_000_000_000,
                reference_time_ns=1_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="middle",
                video_pts_ns=5_000_000_000,
                reference_time_ns=5_000_000_000,
            ),
            VideoAlignmentAnchor(
                label="end",
                video_pts_ns=9_000_000_000,
                reference_time_ns=9_000_000_000,
            ),
        ],
    )
    alignment = tmp_path / "video-alignment.json"
    alignment.write_text(
        json.dumps(receipt.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    alignment_sha, _ = file_sha256(alignment)
    return alignment, alignment_sha, receipt.source_video_sha256


def _ledger(
    tmp_path: Path,
    *,
    alignment_sha: str,
    source_sha: str,
    mapped_pts_ns: int = 5_000_000_000,
) -> Path:
    ledger = {
        "schema_version": REPLAY_REVIEW_LEDGER_SCHEMA_VERSION,
        "run_id": "run-1",
        "flags": [
            {
                "schema_version": REPLAY_REVIEW_FLAG_SCHEMA_VERSION,
                "id": "flag-1",
                "run_id": "run-1",
                "recorded_at_utc": "2026-10-05T00:00:00Z",
                "reference_time_ns": 5_000_000_000,
                "action4_video_pts_ns": mapped_pts_ns,
                "window_before_ns": 1_500_000_000,
                "window_after_ns": 1_500_000_000,
                "scope": "action4_pose",
                "verdict": "wrong",
                "note": "right knee jumps",
                "iphone_pose_available": True,
                "action4_pose_available": True,
                "equipment_available": True,
                "observed_playback_drift_ms": 22.0,
                "artifact_bindings": [
                    {
                        "role": "video_alignment",
                        "sha256": alignment_sha,
                        "filename": "video-alignment.json",
                    },
                    {
                        "role": "action4_video",
                        "sha256": source_sha,
                        "filename": "action4.mp4",
                    },
                ],
                "claim_boundary": "review only",
            }
        ],
        "claim_boundary": "review only",
    }
    path = tmp_path / "replay-review-ledger.json"
    path.write_text(
        json.dumps(ledger, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def test_build_review_queue_maps_exact_windows(tmp_path: Path):
    alignment, alignment_sha, source_sha = _alignment(tmp_path)
    ledger = _ledger(
        tmp_path,
        alignment_sha=alignment_sha,
        source_sha=source_sha,
    )
    output = tmp_path / "review-queue.json"

    payload = build_replay_review_queue(
        ledger,
        alignment,
        output,
    )

    assert payload["schema_version"] == REPLAY_REVIEW_QUEUE_SCHEMA_VERSION
    assert payload["task_count"] == 1
    task = payload["tasks"][0]
    assert task["task_id"] == "replay-review/flag-1"
    assert task["reference_window"] == {
        "start_ns": 3_500_000_000,
        "end_ns": 6_500_000_000,
    }
    assert task["action4_source_window"] == {
        "start_pts_ns": 3_500_000_000,
        "end_pts_ns": 6_500_000_000,
    }
    assert task["scope"] == "action4_pose"
    assert task["verdict"] == "wrong"
    assert output.is_file()


def test_review_queue_rejects_alignment_hash_mismatch(tmp_path: Path):
    alignment, _, source_sha = _alignment(tmp_path)
    ledger = _ledger(
        tmp_path,
        alignment_sha="not-the-alignment",
        source_sha=source_sha,
    )

    with pytest.raises(
        ValueError,
        match="video_alignment hash mismatch",
    ):
        validate_replay_review_ledger(
            ledger,
            alignment,
        )


def test_review_queue_rejects_stale_mapped_pts(tmp_path: Path):
    alignment, alignment_sha, source_sha = _alignment(tmp_path)
    ledger = _ledger(
        tmp_path,
        alignment_sha=alignment_sha,
        source_sha=source_sha,
        mapped_pts_ns=5_250_000_000,
    )

    with pytest.raises(
        ValueError,
        match="Action 4 PTS does not recompute",
    ):
        validate_replay_review_ledger(
            ledger,
            alignment,
        )


def test_review_queue_rejects_wrong_run(tmp_path: Path):
    alignment, alignment_sha, source_sha = _alignment(tmp_path)
    ledger = _ledger(
        tmp_path,
        alignment_sha=alignment_sha,
        source_sha=source_sha,
    )
    raw = json.loads(ledger.read_text(encoding="utf-8"))
    raw["run_id"] = "other-run"
    ledger.write_text(
        json.dumps(raw),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="ledger/alignment run_id mismatch",
    ):
        validate_replay_review_ledger(
            ledger,
            alignment,
        )
