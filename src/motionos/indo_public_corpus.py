from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

YOUTUBE_SEARCH_ENDPOINT = "https://www.googleapis.com/youtube/v3/search"
YOUTUBE_VIDEOS_ENDPOINT = "https://www.googleapis.com/youtube/v3/videos"
INDO_VIDEO_DISCOVERY_SCHEMA_VERSION = "motionos.indo-video-discovery.v1"
INDO_VIDEO_KB_SCHEMA_VERSION = "motionos.indo-video-kb.v1"

_TOPIC_TERMS: dict[str, tuple[str, ...]] = {
    "fundamentals": (
        "beginner",
        "getting started",
        "basics",
        "stance",
        "posture",
        "mount",
        "how to",
    ),
    "stability_control": (
        "balance",
        "steady",
        "center",
        "centering",
        "transition",
        "recovery",
        "control",
    ),
    "lower_body": (
        "squat",
        "knee",
        "knees",
        "hip",
        "hips",
        "leg",
        "legs",
    ),
    "upper_body": (
        "arm",
        "arms",
        "shoulder",
        "shoulders",
        "reach",
    ),
    "roller_control": (
        "roller",
        "rock",
        "tilt",
        "edge",
        "toe",
        "heel",
    ),
    "strength_fitness": (
        "workout",
        "fitness",
        "push-up",
        "pushup",
        "plank",
        "strength",
        "core",
    ),
    "advanced_tricks": (
        "advanced",
        "trick",
        "freestyle",
        "360",
        "press",
        "cross step",
    ),
    "sport_transfer": (
        "surf",
        "surfing",
        "snowboard",
        "snowboarding",
        "skate",
        "skating",
        "wakeboard",
        "ski",
        "skiing",
    ),
    "safety_setup": (
        "safety",
        "spotter",
        "wall",
        "carpet",
        "mat",
        "setup",
    ),
}


def _load_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _write_json(path: str | Path, payload: Any) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _http_json(
    endpoint: str,
    params: dict[str, str],
    *,
    timeout_seconds: float = 30,
) -> dict[str, Any]:
    url = endpoint + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "MotionOS-IndoCorpus/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise TypeError("remote API response must be a JSON object")
    return payload


def _youtube_video_details(
    video_ids: list[str],
    *,
    api_key: str,
) -> dict[str, dict[str, Any]]:
    details: dict[str, dict[str, Any]] = {}
    for start in range(0, len(video_ids), 50):
        batch = video_ids[start : start + 50]
        payload = _http_json(
            YOUTUBE_VIDEOS_ENDPOINT,
            {
                "part": "snippet,contentDetails,status,statistics",
                "id": ",".join(batch),
                "key": api_key,
            },
        )
        for item in payload.get("items", []):
            if not isinstance(item, dict):
                continue
            video_id = item.get("id")
            if isinstance(video_id, str):
                details[video_id] = item
    return details


def discover_indo_youtube(
    query_spec_path: str | Path,
    output_spec_path: str | Path,
    *,
    api_key: str | None = None,
) -> dict[str, Any]:
    """Discover Indo Board videos through the official YouTube Data API.

    The output is a public-video spec, not a media mirror. Standard-license
    videos are indexed as platform-only/derived-only references. Creative
    Commons videos are marked as reusable candidates but still default to
    derived-only retention until a later acquisition step explicitly opts in.
    """

    key = api_key or os.environ.get("YOUTUBE_API_KEY")
    if not key:
        raise ValueError(
            "YouTube discovery requires YOUTUBE_API_KEY or an explicit api_key"
        )

    spec = _load_json(query_spec_path)
    if not isinstance(spec, dict):
        raise TypeError("query spec must be a JSON object")
    raw_queries = spec.get("queries")
    if not isinstance(raw_queries, list) or not raw_queries:
        raise ValueError("query spec requires a non-empty queries list")

    discovered: dict[str, dict[str, Any]] = {}
    query_hits: Counter[str] = Counter()

    for index, raw in enumerate(raw_queries):
        if not isinstance(raw, dict):
            raise TypeError(f"queries[{index}] must be an object")
        query = raw.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ValueError(f"queries[{index}].query must be non-empty")

        weak_labels = raw.get("weak_labels", [])
        if not isinstance(weak_labels, list) or not all(
            isinstance(value, str) and value.strip()
            for value in weak_labels
        ):
            raise ValueError("weak_labels must contain strings")

        max_pages = raw.get("max_pages", 2)
        if not isinstance(max_pages, int) or not 1 <= max_pages <= 10:
            raise ValueError("max_pages must be an integer in [1, 10]")

        video_license = raw.get("video_license", "any")
        if video_license not in {"any", "creativeCommon", "youtube"}:
            raise ValueError(
                "video_license must be any, creativeCommon, or youtube"
            )

        page_token: str | None = None
        for page in range(max_pages):
            params = {
                "part": "snippet",
                "type": "video",
                "maxResults": "50",
                "q": query.strip(),
                "order": "relevance",
                "videoEmbeddable": "true",
                "safeSearch": "moderate",
                "key": key,
            }
            if video_license != "any":
                params["videoLicense"] = str(video_license)
            if page_token:
                params["pageToken"] = page_token

            payload = _http_json(YOUTUBE_SEARCH_ENDPOINT, params)
            for item in payload.get("items", []):
                if not isinstance(item, dict):
                    continue
                id_payload = item.get("id")
                snippet = item.get("snippet")
                if not isinstance(id_payload, dict) or not isinstance(
                    snippet,
                    dict,
                ):
                    continue
                video_id = id_payload.get("videoId")
                if not isinstance(video_id, str) or not video_id:
                    continue

                source_url = f"https://www.youtube.com/watch?v={video_id}"
                record = discovered.setdefault(
                    video_id,
                    {
                        "platform": "youtube",
                        "source_id": f"youtube/{video_id}",
                        "source_url": source_url,
                        "creator": snippet.get("channelTitle"),
                        "title": snippet.get("title"),
                        "published_at": snippet.get("publishedAt"),
                        "rights_status": "unknown",
                        "retention_policy": "derived_only",
                        "weak_labels": [],
                        "discovery": {
                            "method": "youtube_data_api_v3",
                            "queries": [],
                            "snippet_description": snippet.get("description"),
                            "channel_id": snippet.get("channelId"),
                        },
                    },
                )

                record["weak_labels"] = sorted(
                    set(record["weak_labels"]) | set(weak_labels)
                )
                record["discovery"]["queries"].append(
                    {
                        "query": query.strip(),
                        "page": page + 1,
                        "video_license_filter": video_license,
                    }
                )
                query_hits[query.strip()] += 1

            page_token = payload.get("nextPageToken")
            if not isinstance(page_token, str) or not page_token:
                break

    details = _youtube_video_details(
        list(discovered),
        api_key=key,
    )
    for video_id, record in discovered.items():
        detail = details.get(video_id, {})
        status = detail.get("status")
        content = detail.get("contentDetails")
        statistics = detail.get("statistics")

        license_name = (
            status.get("license")
            if isinstance(status, dict)
            else None
        )
        if license_name == "creativeCommon":
            record["rights_status"] = "creative_commons"
            record["rights_evidence"] = (
                "YouTube Data API videos.status.license=creativeCommon"
            )
        elif license_name == "youtube":
            record["rights_status"] = "platform_only"
            record["rights_evidence"] = (
                "YouTube Data API videos.status.license=youtube"
            )

        if isinstance(content, dict):
            record["discovery"]["duration_iso8601"] = content.get("duration")
        if isinstance(statistics, dict):
            record["discovery"]["statistics"] = {
                key: statistics.get(key)
                for key in ("viewCount", "likeCount", "commentCount")
                if statistics.get(key) is not None
            }

    records = sorted(
        discovered.values(),
        key=lambda item: (
            str(item.get("creator") or "").lower(),
            str(item.get("title") or "").lower(),
            str(item["source_id"]),
        ),
    )
    payload = {
        "schema_version": INDO_VIDEO_DISCOVERY_SCHEMA_VERSION,
        "purpose": (
            "Broad Indo Board / roller-balance video discovery for "
            "representation learning, detector robustness, event taxonomy, "
            "and weakly supervised technique research."
        ),
        "records": records,
        "discovery_summary": {
            "query_count": len(raw_queries),
            "unique_video_count": len(records),
            "query_hits": dict(sorted(query_hits.items())),
        },
        "claim_boundary": (
            "Discovery relevance is not coaching ground truth. Public visibility "
            "does not grant raw-media reuse rights. Standard-license videos "
            "remain platform-only references with derived-only retention."
        ),
    }
    _write_json(output_spec_path, payload)
    return payload


def enrich_public_video_urls_with_ytdlp(
    urls_path: str | Path,
    output_spec_path: str | Path,
    *,
    timeout_seconds: float = 45,
) -> dict[str, Any]:
    """Extract metadata only for explicitly supplied public URLs.

    This adapter never requests media download. It exists for research
    discovery across platforms where no uniform first-party public search API
    is available. Users are responsible for ensuring the supplied URLs and
    access method comply with the relevant platform rules.
    """

    executable = shutil.which("yt-dlp")
    if executable is None:
        raise RuntimeError(
            "yt-dlp is not installed; install it separately to use metadata enrichment"
        )

    raw = _load_json(urls_path)
    if isinstance(raw, dict):
        urls = raw.get("urls")
    else:
        urls = raw
    if not isinstance(urls, list) or not urls:
        raise ValueError("URL input requires a non-empty urls list")

    records: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []

    for value in urls:
        if not isinstance(value, str) or not value.startswith("https://"):
            raise ValueError("each URL must be an https string")

        try:
            process = subprocess.run(
                [
                    executable,
                    "--skip-download",
                    "--no-playlist",
                    "--dump-single-json",
                    "--no-warnings",
                    value,
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired:
            failures.append({"url": value, "error": "metadata timeout"})
            continue

        if process.returncode != 0:
            failures.append(
                {
                    "url": value,
                    "error": process.stderr.strip() or "metadata extraction failed",
                }
            )
            continue

        try:
            info = json.loads(process.stdout)
        except json.JSONDecodeError:
            failures.append({"url": value, "error": "invalid metadata JSON"})
            continue

        extractor = str(info.get("extractor_key") or info.get("extractor") or "")
        platform = _platform_from_extractor(extractor)
        webpage_url = str(info.get("webpage_url") or value)
        source_id = str(info.get("id") or "")
        if not source_id:
            source_id = webpage_url

        license_name = str(info.get("license") or "").lower()
        rights_status = (
            "creative_commons"
            if "creative commons" in license_name
            else "unknown"
        )

        records.append(
            {
                "platform": platform,
                "source_id": f"{platform}/{source_id}",
                "source_url": webpage_url,
                "creator": info.get("uploader") or info.get("creator"),
                "title": info.get("title"),
                "published_at": info.get("upload_date"),
                "rights_status": rights_status,
                "rights_evidence": (
                    f"yt-dlp metadata license={info.get('license')}"
                    if info.get("license")
                    else None
                ),
                "retention_policy": "derived_only",
                "weak_labels": ["indo-board-candidate"],
                "discovery": {
                    "method": "yt_dlp_metadata_only",
                    "extractor": extractor,
                    "description": info.get("description"),
                    "duration_seconds": info.get("duration"),
                    "tags": info.get("tags") or [],
                    "categories": info.get("categories") or [],
                },
            }
        )

    payload = {
        "schema_version": INDO_VIDEO_DISCOVERY_SCHEMA_VERSION,
        "purpose": "Metadata-only enrichment of explicitly supplied public video URLs.",
        "records": records,
        "failures": failures,
        "claim_boundary": (
            "No raw media was downloaded by this command. Metadata extraction "
            "does not establish permission to retain or redistribute media."
        ),
    }
    _write_json(output_spec_path, payload)
    return payload


def merge_public_video_specs(
    input_paths: list[str | Path],
    output_path: str | Path,
) -> dict[str, Any]:
    merged: dict[str, dict[str, Any]] = {}
    for path in input_paths:
        payload = _load_json(path)
        if not isinstance(payload, dict):
            raise TypeError(f"{path} must contain a JSON object")
        records = payload.get("records")
        if not isinstance(records, list):
            raise TypeError(f"{path} is missing records")

        for raw in records:
            if not isinstance(raw, dict):
                continue
            source_url = raw.get("source_url")
            if not isinstance(source_url, str):
                continue
            existing = merged.get(source_url)
            if existing is None:
                merged[source_url] = raw
                continue

            existing_labels = existing.get("weak_labels", [])
            incoming_labels = raw.get("weak_labels", [])
            if isinstance(existing_labels, list) and isinstance(
                incoming_labels,
                list,
            ):
                existing["weak_labels"] = sorted(
                    {
                        str(value)
                        for value in existing_labels + incoming_labels
                        if str(value).strip()
                    }
                )

    payload = {
        "schema_version": INDO_VIDEO_DISCOVERY_SCHEMA_VERSION,
        "purpose": "Merged Indo Board public-video discovery index.",
        "records": sorted(
            merged.values(),
            key=lambda item: str(item.get("source_id") or ""),
        ),
    }
    _write_json(output_path, payload)
    return payload


def build_indo_video_knowledge_base(
    catalog_path: str | Path,
    output_path: str | Path,
) -> dict[str, Any]:
    catalog = _load_json(catalog_path)
    if not isinstance(catalog, dict):
        raise TypeError("catalog must be a JSON object")
    records = catalog.get("records")
    if not isinstance(records, list):
        raise TypeError("catalog requires records")

    topic_sources: dict[str, list[str]] = defaultdict(list)
    creators: Counter[str] = Counter()
    rights: Counter[str] = Counter()
    platforms: Counter[str] = Counter()

    source_summaries: list[dict[str, Any]] = []

    for raw in records:
        if not isinstance(raw, dict):
            continue
        source_id = str(raw.get("source_id") or raw.get("source_url") or "")
        if not source_id:
            continue

        creator = str(raw.get("creator") or "unknown")
        creators[creator] += 1
        rights[str(raw.get("rights_status") or "unknown")] += 1
        platforms[str(raw.get("platform") or "other")] += 1

        discovery = raw.get("discovery")
        discovery_text = ""
        if isinstance(discovery, dict):
            discovery_text = " ".join(
                str(discovery.get(key) or "")
                for key in (
                    "snippet_description",
                    "description",
                    "tags",
                    "categories",
                )
            )
        labels = raw.get("weak_labels")
        label_text = " ".join(labels) if isinstance(labels, list) else ""
        text = " ".join(
            [
                str(raw.get("title") or ""),
                label_text,
                discovery_text,
            ]
        ).lower()

        topics = sorted(
            topic
            for topic, terms in _TOPIC_TERMS.items()
            if any(term in text for term in terms)
        )
        for topic in topics:
            topic_sources[topic].append(source_id)

        source_summaries.append(
            {
                "source_id": source_id,
                "title": raw.get("title"),
                "creator": raw.get("creator"),
                "platform": raw.get("platform"),
                "rights_status": raw.get("rights_status"),
                "topics": topics,
                "weak_labels": raw.get("weak_labels", []),
            }
        )

    payload = {
        "schema_version": INDO_VIDEO_KB_SCHEMA_VERSION,
        "source_count": len(source_summaries),
        "platform_counts": dict(platforms.most_common()),
        "rights_counts": dict(rights.most_common()),
        "creator_counts": dict(creators.most_common()),
        "topics": {
            topic: {
                "source_count": len(source_ids),
                "source_ids": sorted(source_ids),
            }
            for topic, source_ids in sorted(topic_sources.items())
        },
        "sources": source_summaries,
        "claim_boundary": (
            "Topics are weak metadata-derived labels for retrieval and dataset "
            "stratification. They are not verified biomechanical claims or "
            "evidence that a source demonstrates ideal technique."
        ),
    }
    _write_json(output_path, payload)
    return payload


def _platform_from_extractor(extractor: str) -> str:
    normalized = extractor.lower()
    if "youtube" in normalized:
        return "youtube"
    if "instagram" in normalized:
        return "instagram"
    if "tiktok" in normalized:
        return "tiktok"
    return "other"
