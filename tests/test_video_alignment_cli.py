from __future__ import annotations

import json

from motionos.cli import main


def test_build_video_alignment_cli_writes_receipt(tmp_path, capsys):
    video = tmp_path / "action4.mov"
    video.write_bytes(b"video-fixture" * 64)

    slope = 1.0 + 12e-6
    intercept_ns = -5_000_000_000
    reference_times = [
        12_000_000_000,
        55_000_000_000,
        108_000_000_000,
    ]
    spec = {
        "run_id": "indo-cli",
        "source_video": str(video),
        "video_duration_ns": 135_000_000_000,
        "reference_start_ns": 0,
        "reference_end_ns": 120_000_000_000,
        "anchors": [
            {
                "label": label,
                "video_pts_ns": round(
                    (reference - intercept_ns) / slope
                ),
                "reference_time_ns": reference,
                "uncertainty_ns": 1_000_000,
                "source": "fixture",
            }
            for label, reference in zip(
                ("start", "middle", "end"),
                reference_times,
            )
        ],
    }
    spec_path = tmp_path / "spec.json"
    output = tmp_path / "alignment.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")

    exit_code = main(
        [
            "build-video-alignment",
            str(spec_path),
            str(output),
        ]
    )

    assert exit_code == 0
    written = json.loads(output.read_text(encoding="utf-8"))
    assert written["schema_version"] == "motionos.video-alignment.v1"
    assert written["run_id"] == "indo-cli"
    assert written["coverage"]["passed"] is True
    assert written["source_video"]["filename"] == "action4.mov"

    printed = json.loads(capsys.readouterr().out)
    assert printed["clock_model"]["observations_used"] == 3
