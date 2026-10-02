#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

OUT_DIR="${1:-data/indo_public_corpus/generated}"
QUERY_PLAN="${INDO_QUERY_PLAN:-configs/indo_public_video_queries.json}"
TAXONOMY="${INDO_TAXONOMY:-configs/indo_skill_taxonomy.v1.json}"

mkdir -p "${OUT_DIR}"

if [[ -z "${YOUTUBE_API_KEY:-}" ]]; then
  cat >&2 <<'EOF'
YOUTUBE_API_KEY is required for broad YouTube discovery.

This workflow uses the official YouTube Data API and writes references,
metadata, license status, and provenance. It does not bulk-download media.

Example:
  export YOUTUBE_API_KEY="..."
  bash scripts/build_indo_public_corpus.sh
EOF
  exit 2
fi

echo "[1/6] Discovering INDO BOARD / roller-balance YouTube references"
motionos discover-indo-youtube \
  "${QUERY_PLAN}" \
  "${OUT_DIR}/youtube-discovery.json"

echo "[2/6] Merging official, community, and discovered references"
motionos merge-indo-video-specs \
  data/indo_public_corpus/seed_official.json \
  data/indo_public_corpus/seed_community.json \
  "${OUT_DIR}/youtube-discovery.json" \
  "${OUT_DIR}/merged-discovery.json"

echo "[3/6] Building rights-aware public-video catalog"
motionos build-public-video-catalog \
  "${OUT_DIR}/merged-discovery.json" \
  "${OUT_DIR}/catalog.json"

echo "[4/6] Building retrieval / topic knowledge index"
motionos build-indo-video-kb \
  "${OUT_DIR}/catalog.json" \
  "${OUT_DIR}/knowledge-index.json"

echo "[5/6] Building creator-grouped annotation queue"
motionos indo-annotation-queue \
  "${OUT_DIR}/catalog.json" \
  "${TAXONOMY}" \
  "${OUT_DIR}/annotation-queue.json"

echo "[6/6] Writing corpus summary"
python - "${OUT_DIR}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
catalog = json.loads((root / "catalog.json").read_text())
knowledge = json.loads((root / "knowledge-index.json").read_text())
queue = json.loads((root / "annotation-queue.json").read_text())

summary = {
    "schema_version": "motionos.indo-corpus-build-summary.v1",
    "source_count": len(catalog["records"]),
    "topic_count": len(knowledge["topics"]),
    "annotation_task_count": queue["task_count"],
    "annotation_split_counts": queue["split_counts"],
    "claim_boundary": (
        "This corpus is a provenance-aware discovery and annotation index. "
        "Public visibility does not grant media redistribution rights, and "
        "community or weak labels are not coaching ground truth."
    ),
}
(root / "summary.json").write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n"
)
print(json.dumps(summary, indent=2, sort_keys=True))
PY

echo
echo "INDO BOARD corpus build complete: ${OUT_DIR}"
