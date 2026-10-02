import json

from motionos.indo_public_corpus import (
    build_indo_video_knowledge_base,
    merge_public_video_specs,
)


def test_merge_public_video_specs_deduplicates_urls(tmp_path):
    first = tmp_path / "first.json"
    second = tmp_path / "second.json"

    first.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "source_id": "youtube/demo",
                        "source_url": "https://www.youtube.com/watch?v=demo",
                        "platform": "youtube",
                        "weak_labels": ["indo-board"],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    second.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "source_id": "youtube/demo",
                        "source_url": "https://www.youtube.com/watch?v=demo",
                        "platform": "youtube",
                        "weak_labels": ["beginner"],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    output = tmp_path / "merged.json"
    payload = merge_public_video_specs([first, second], output)

    assert len(payload["records"]) == 1
    assert payload["records"][0]["weak_labels"] == [
        "beginner",
        "indo-board",
    ]


def test_indo_video_kb_builds_retrieval_topics(tmp_path):
    catalog = tmp_path / "catalog.json"
    catalog.write_text(
        json.dumps(
            {
                "records": [
                    {
                        "source_id": "youtube/demo",
                        "source_url": "https://www.youtube.com/watch?v=demo",
                        "platform": "youtube",
                        "creator": "Coach",
                        "title": "Beginner Indo Board squat balance tutorial",
                        "rights_status": "platform_only",
                        "weak_labels": ["surf training"],
                        "discovery": {
                            "snippet_description":
                                "Use a spotter and learn roller control."
                        },
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    output = tmp_path / "kb.json"
    payload = build_indo_video_knowledge_base(catalog, output)

    assert payload["source_count"] == 1
    assert "fundamentals" in payload["topics"]
    assert "lower_body" in payload["topics"]
    assert "roller_control" in payload["topics"]
    assert "sport_transfer" in payload["topics"]
    assert "safety_setup" in payload["topics"]
    assert output.is_file()
