import json

import pytest

from motionos.public_video import build_public_video_catalog


def test_public_video_catalog_defaults_to_derived_only(tmp_path):
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "platform": "youtube",
                        "source_url": "https://www.youtube.com/watch?v=example",
                        "creator": "Example creator",
                        "rights_status": "unknown",
                        "weak_labels": ["indo-board", "beginner"],
                        "discovery": {
                            "query": "indo board balance",
                            "method": "youtube-data-api",
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    output = tmp_path / "catalog.json"
    payload = build_public_video_catalog(spec, output)

    assert payload["schema_version"] == "motionos.public-video-catalog.v1"
    assert len(payload["records"]) == 1
    record = payload["records"][0]
    assert record["platform"] == "youtube"
    assert record["retention_policy"] == "derived_only"
    assert record["rights_status"] == "unknown"
    assert record["source_id"].startswith("youtube/")
    assert output.is_file()


def test_public_video_catalog_requires_rights_for_local_copy(tmp_path):
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "platform": "tiktok",
                        "source_url": "https://www.tiktok.com/@example/video/1",
                        "rights_status": "platform_only",
                        "retention_policy": "authorized_local_copy",
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="authorized_local_copy requires",
    ):
        build_public_video_catalog(spec, tmp_path / "catalog.json")


def test_public_video_catalog_rejects_duplicate_ids(tmp_path):
    spec = tmp_path / "spec.json"
    spec.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "source_id": "indo/demo",
                        "platform": "instagram",
                        "source_url": "https://www.instagram.com/reel/example1/",
                    },
                    {
                        "source_id": "indo/demo",
                        "platform": "youtube",
                        "source_url": "https://www.youtube.com/watch?v=example2",
                    },
                ]
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="duplicate source_id"):
        build_public_video_catalog(spec, tmp_path / "catalog.json")
