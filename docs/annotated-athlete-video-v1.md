# MotionOS Annotated Athlete Video v1

Status: product + engineering design for post-session replay and model-teacher generation

## Product goal

Turn a sealed MotionOS session into a replay that explains movement without
blurring the boundary between what was observed, derived, and inferred.

The same pipeline should support Indo Board, skate/longboard, skiing,
mountain biking, running, climbing, and later sports without inventing one
opaque universal form score.

## Output bundle

Every render is derived from immutable source evidence and should emit:

- `annotated.mp4` — human-facing replay;
- `annotation-manifest.json` — exact source hashes, renderer/model versions,
  calibration refs, layer definitions, confidence, and claim boundaries;
- `teacher-labels.jsonl` — time-indexed machine-readable labels used for
  training/evaluation;
- optional `athlete-mesh.mp4` — body-replacement render that shows a
  reconstructed body rather than the identifying RGB pixels.

Never overwrite the raw source movie.

## Video ingest

Supported sources:

1. iPhone camera evidence already captured by MotionOS.
2. DJI / external camera imported from Photos after DJI Mimo transfer.
3. DJI / external camera imported from Files, SD card, or external storage.

Imported originals are copied unchanged and SHA-256 bound to the run before
any trimming, transcode, synchronization, or annotation.

## Synchronization

Each camera keeps its native PTS.

External footage is aligned to the MotionOS run using, in order:

1. journal-backed shared sync gestures;
2. cross-view body/board motion correlation around those gestures;
3. creation time only as a coarse search prior.

The aligned clip is a derived artifact. The original remains intact.

### Action 4 proposal path

Product protocol v2 deliberately places its three sharp-arm landmarks near
10 s, 63 s, and 114 s so the clock fit is conditioned by an early, true-middle,
and late correspondence.

For a new multiview run:

1. the Watch journals cue receipt time;
2. the iPhone product manifest records the nearest camera PTS at that cue;
3. post-session iPhone replay finds the actual visual arm-motion peak near
   each cue;
4. the imported Action 4 original is sampled with Vision body pose at 5 Hz;
5. MotionOS searches external arm-motion peak triples whose intervals match
   the three iPhone visual landmarks;
6. the app writes `action4-sync-proposal.json` with confidence and residuals.

The proposal is intentionally **not** synchronization authority. It must be
reviewed and converted into the existing hash-bound
`motionos.video-alignment.v1` receipt before cross-view overlays or metric
fusion are unlocked.

File creation time may be used only as a coarse debugging clue and is never a
clock correspondence.

### Proposal review and sealing

A synchronization proposal is not promoted automatically.

The operator reviews START, MIDDLE, and END in paired iPhone/Action 4 video
players and explicitly confirms that each pair shows the same sharp-arm event.
Only after all three events are accepted may MotionOS write
`video-alignment.json`.

Sealing performs a fresh least-squares fit using **all three reviewed anchors**,
rather than reusing the proposal's endpoint fit. The final receipt recomputes:

- affine slope and intercept;
- clock drift in ppm;
- per-anchor residuals and RMS residual;
- early/middle/late coverage;
- source-video trim bounds;
- exact Action 4 SHA-256 and byte count.

The receipt uses the same `motionos.video-alignment.v1` schema as the Python
tooling. The reviewed proposal's SHA-256, confidence, protocol version, and
review state are preserved as source metadata.

Once sealed, Action 4 playback can be mapped onto the iPhone reference
timeline. This is enough to synchronize view-independent products such as the
3D body scene and coaching/event timing. It is **not** enough to paint iPhone
2D skeleton or board coordinates onto Action 4 pixels; that still requires
Action 4-specific pose/equipment tracking or calibrated cross-view projection.

## Geometry

There are two geometry modes.

### Product replay

Single-camera pose is allowed to drive image-space overlays and root-relative
body visualization with confidence.

### Metric multiview

World-coordinate claims require the calibrated multi-camera chain:

- ChArUco board definition;
- per-camera intrinsics/distortion;
- frozen world frame;
- capture-time mount verification;
- camera-specific clock map;
- passing rig receipt;
- reprojection diagnostics.

Nominal tripod placement is guidance, not geometry authority.

## Representation layers

A render is a composition of independent layers that can be toggled.

### Observed

- raw RGB;
- detected 2D joints;
- visible board / roller markers or qualified model detections;
- source-frame timestamps;
- Watch cue landmarks.

Use solid marks.

### Derived

- smoothed pose;
- pelvis trajectory;
- joint angles;
- board-center / roller displacement;
- correction onset;
- recovery duration;
- left/right asymmetry;
- cross-view triangulation when qualified.

Use solid marks plus estimator/version metadata.

### Inferred

- body mesh fitted to observed pose;
- center-of-mass estimate;
- movement primitive;
- technique cue;
- estimated joint moments;
- estimated muscle demand.

Use translucent/outlined rendering and explicit confidence.

## Anatomical body replacement

The body-replacement render should support three visual modes:

1. **Silhouette mesh** — neutral non-identifying body surface.
2. **Skeleton / mechanics** — joints, segments, axes, COM/support region.
3. **Muscular anatomy** — major muscle groups colored by estimated demand.

The reconstructed mesh should be scaled from the user's calibration/body
model and articulated by the synchronized pose sequence.

The renderer must retain the source skeleton and calibration confidence so
the avatar cannot visually imply precision that the pose did not support.

## Muscle semantics

Camera video alone does not measure muscle activation.

The first product version may show only **estimated muscle demand**, derived
from kinematics and a declared musculoskeletal model. It must not be labeled
EMG, activation, weakness, injury risk, or tissue load.

A stronger future estimate can incorporate:

- subject-specific segment geometry;
- body mass / segment scaling;
- multiview kinematics;
- plantar/equipment forces where qualified;
- optional EMG when actually measured.

Longitudinal cards should compare the same estimator version and comparable
movement primitive. Model upgrades create a new analysis version rather than
silently rewriting history.

## Coaching overlay grammar

Every correction shown on video follows:

**Observation -> mechanism hypothesis -> experiment**

Example:

- observation: late large deck recovery;
- hypothesis: correction begins after large roller excursion;
- experiment: initiate a smaller knee/hip correction earlier;
- result: compare the next matched repetitions.

The video should show the exact frames that support the observation and a
confidence/provenance badge.

## Timeline events

Useful cross-sport event types:

- mount / start;
- stable phase;
- perturbation;
- correction onset;
- recovery;
- repeated counter-correction;
- loss / reacquisition;
- jump / landing;
- turn / carve;
- braking;
- push / stride;
- reach / contact;
- fall / bailout;
- protocol cue.

Sports may add domain-specific events without changing the common timeline
contract.

## Training labels

Teacher labels should be stored separately from presentation copy.

Each time-indexed label includes:

- run id;
- source video hash;
- source frame PTS;
- reference timeline time;
- sport;
- primitive/event;
- observed quantities;
- derived quantities;
- inferred quantities;
- confidence;
- model/estimator version;
- calibration/clock provenance;
- human-review state.

Train/test splits must group by session/day/view/person as appropriate so the
model cannot win by memorizing one recording setup.

## Render architecture

Recommended pipeline:

```text
sealed run
   |
   +-- raw iPhone video
   +-- imported Action camera video
   +-- Watch / equipment evidence
   +-- sync + calibration receipts
   |
   v
time alignment
   |
   v
pose + equipment tracks
   |
   v
movement/event features
   |
   +--> teacher-label stream
   |
   v
body / mechanics / muscle-estimate scene
   |
   v
overlay compositor
   |
   +--> annotated.mp4
   +--> athlete-mesh.mp4
   +--> annotation-manifest.json
```

The offline renderer should be deterministic for a frozen manifest.

## Product UI

A sealed session gets one **Replay** action with layer controls:

- Video
- Body
- Mechanics
- Balance
- Muscle estimate
- Coaching
- Confidence

Default view is sparse: original/mesh athlete, one current metric, one event,
one coaching explanation. Detailed traces stay behind an expandable panel.

## Privacy

Raw identifying video should remain private/local by default.

A body-replacement export is useful for sharing and model review, but the
motion signature itself may still be identifying. Treat derived pose/body
artifacts as user data, not automatically anonymous data.

## Implementation order

### V1
- reliable Action-camera import;
- source hashing;
- sync/trim manifest;
- observed 2D/3D pose overlay;
- board/roller overlay;
- event timeline;
- coaching callouts.

### V2
- calibrated multiview geometry;
- non-identifying body mesh replacement;
- cross-session ghost comparison.

### V3
- subject-scaled musculoskeletal model;
- estimated joint/muscle-demand overlay;
- matched-primitive longitudinal trends.

### V4
- optional measured EMG/force sources;
- estimator qualification against stronger ground truth.

## Claim boundary

An anatomical-looking render is not automatically an anatomical measurement.
Every frame must preserve whether the underlying quantity was observed,
derived, or inferred.
