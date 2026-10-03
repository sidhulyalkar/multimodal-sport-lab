# Indo Board Public Video Corpus v1

This research branch builds a reference index first, not a bulk media mirror.

## Why

Public Indo Board and roller-balance videos are useful for viewpoint, clothing, lighting, and background diversity, board / roller detector development, occlusion and tracking robustness, movement-event discovery, weakly supervised representation learning, and hard-negative mining. They are not assumed to be ideal-technique ground truth.

## Acquisition policy

1. Prefer official platform APIs for discovery.
2. Record canonical URL, creator, title, date, discovery query, rights status, and retention policy.
3. Standard-license / unknown-rights videos stay derived-only.
4. Creative Commons or explicit-permission sources may later become authorized local copies, but only through an explicit acquisition step.
5. yt-dlp support in this branch is metadata-only and only for URLs supplied by the operator.
6. Do not bypass authentication, access controls, geographic restrictions, or platform rate limits.

## Broad YouTube discovery

Set YOUTUBE_API_KEY, then run:

    motionos discover-indo-youtube configs/indo_public_video_queries.json data/indo_public_corpus/youtube_discovery.json

The query plan covers both brand-specific and generic roller-board terms so the corpus does not simply memorize one channel or one coaching vocabulary.

## Metadata-only enrichment

For explicitly supplied public URLs, run:

    motionos enrich-indo-video-urls /tmp/indo_urls.json data/indo_public_corpus/url_metadata.json

This requires a separately installed yt-dlp executable and invokes it with skip-download behavior.

## Merge and build the retrieval index

    motionos merge-indo-video-specs data/indo_public_corpus/seed_official.json data/indo_public_corpus/youtube_discovery.json data/indo_public_corpus/merged_discovery.json
    motionos build-public-video-catalog data/indo_public_corpus/merged_discovery.json data/indo_public_corpus/catalog.json
    motionos build-indo-video-kb data/indo_public_corpus/catalog.json data/indo_public_corpus/knowledge_index.json

The first knowledge index is deliberately simple and auditable. It maps source metadata into retrieval topics such as fundamentals, stability/control, roller control, lower body, upper body, sport transfer, advanced tricks, fitness, and safety/setup.

## Recommended open-source stack to evaluate

- yt-dlp/yt-dlp: metadata extraction for explicitly supplied public URLs. Keep it optional and non-authoritative because platform behavior changes.
- YouTube Data API v3: primary broad YouTube discovery path because it exposes search filtering and license metadata.
- open-mmlab/mmpose: baseline for 2D/whole-body pose experiments and offline comparison against Apple Vision.
- yufu-wang/PromptHMR: promising world-coordinate human mesh recovery for offline teacher experiments.
- yufu-wang/tram: global human trajectory / motion baseline.
- facebookresearch/co-tracker: point tracking for deck corners, roller endpoints, floor landmarks, and hard-negative analysis.
- facebookresearch/sam2: video segmentation candidate for bootstrapping board / roller masks.
- facebookresearch/vggt-omega: high-upside offline scene/camera/depth teacher for reconstructing geometry from video.
- microsoft/MoGe: monocular geometry/depth candidate when a full multi-frame model is unnecessary.

## Efficient modeling order

1. Native beta path: Apple Vision body pose + deterministic framing/stability + Watch control.
2. Board state baseline: manually annotate a small beta set; train or prompt a board/roller detector.
3. Tracking: deterministic detection plus temporal point tracking.
4. Offline teacher: evaluate VGGT-Omega / MoGe for floor, camera, and board geometry.
5. Human teacher: compare PromptHMR / MMPose against Vision and reject models that do not improve measurable downstream state.
6. Distill: convert useful offline teacher outputs into smaller task-specific models or geometric rules.

The product should depend on the smallest model stack that survives real beta sessions, not the largest stack that makes an impressive demo.
