# M0-Vision / V0 Indo Board Calibration

This milestone turns the existing MotionOS camera, Watch, clock-uncertainty, and
world-geometry work into one reproducible multisensor experiment.

## Scope

The first rig is intentionally small:

- Apple Watch: wrist IMU + workout physiology;
- iPhone rear camera: native AVFoundation video PTS + Vision evidence;
- DJI Osmo Action 4: external recorded camera source;
- Indo Board: controlled balance task;
- optional later equipment IMU / pressure / sEMG.

The Action 4 is represented as `external_recorded` today. MotionOS does not
pretend it has a vendor-supported live camera SDK when it does not. A future
RTMP, UVC, or vendor adapter can implement live frames without changing the
session, calibration, fusion, or metric contracts.

## Capture contract

Every camera owns a native clock. Raw timestamps are never rewritten during
capture. MotionOS records:

- `CameraSource`
- `VideoFrameTimestamp`
- `CameraCalibration`
- `VisionObservation`
- `SyncLandmark`
- existing affine / weighted clock models.

A session-level sidecar uses `motionos.vision-session.v1`.

## Physical setup

1. Put the Action 4 on a rigid tripod 30–60 degrees off frontal.
2. Put the iPhone roughly 70–110 degrees away from it.
3. Keep the full athlete, board, feet, and calibration target visible.
4. Use the existing ChArUco world-frame flow to calibrate intrinsics/extrinsics.
5. Do not move either camera after mount verification.
6. Start Watch capture, iPhone video, and Action 4 recording.
7. Near the beginning, middle, and end, emit a MotionOS sync cue and perform one
   sharp whole-body/board impulse that is visible in both videos and the Watch IMU.
8. Preserve original Action 4 media and import it without transcoding before
   deriving frame timing.

## First five metrics

The first report deliberately avoids a mystery aggregate score.

| Metric | Unit | Direction | Meaning |
| --- | --- | --- | --- |
| balance stability RMS | m | lower | horizontal COM variation around the session median |
| COM excursion p95 | m | lower | near-worst-case horizontal COM displacement |
| board-control jerk RMS | deg/s^3 | lower | high-frequency correction / roughness proxy |
| recovery latency median | s | lower | time to return to stable board + COM bands after a disturbance |
| stance asymmetry | deg | descriptive | mean absolute left/right knee-flexion difference |

Stance asymmetry is a geometry proxy only. It is not a loading estimate.

## Quality gates

A sample is excluded before metric calculation when any of these are violated:

- pose confidence < 0.60;
- predictive timing uncertainty > 20 ms;
- reprojection RMS > 3 px.

These defaults are development thresholds. Freeze experiment-specific thresholds
before reviewing outcomes.

## Muscle and force boundary

RGB video can support pose, segment kinematics, and model-based mechanical
estimates. It does **not** directly measure muscle activation, muscle mass, or
ground-reaction force. Add sEMG for activation and pressure/force sensing for
loading if those become target variables.

## Live coaching

Live Watch cues are a separate, sparse output channel. A cue must:

- belong to the active session;
- have confidence >= 0.75;
- still be inside its expiry window;
- contain one actionable message.

For Indo Board, use haptics for low-consequence balance coaching. For climbing,
skiing, or mountain biking, the policy should default to no technique cues while
the athlete is in a high-consequence movement state.

## Longitudinal model

Each metric keeps an online Welford baseline:

- sample count;
- running mean;
- sample standard deviation;
- latest value;
- best observed value when a direction is defined.

The longitudinal layer stores raw session values plus baseline state. It never
replaces source evidence.

## Expansion path

After the two-camera Indo Board run is qualified:

1. replace manual Action 4 import with a live adapter when a supported transport
   is available;
2. add board IMU and/or bilateral pressure;
3. train a wearable-only student model against the camera-rich teacher;
4. periodically repeat camera calibration sessions to detect drift;
5. add sport-specific state machines for climbing, MTB, and skiing.

## App workflow

The iPhone host now includes an **Indo Board · M0-Vision** card:

1. arm a new vision session;
2. choose and persist the feedback condition before capture;
3. start the Action 4 manually and confirm it in MotionOS;
4. start Watch + iPhone capture under the vision session;
5. emit start/middle/end sync cues and wait for each to show as
   **Watch-journaled**; button taps that never receive a Watch acknowledgment
   do not count toward the required three;
6. stop and seal the iPhone evidence;
7. import the untouched Action 4 movie;
8. MotionOS copies the file into the session evidence directory and records its
   SHA-256 and byte count in the sealed sidecar.

The imported movie is not transcoded before hashing.

## Synchronization evidence

Each sync button press creates three operator-visible signals:

- a short iPhone audio chirp;
- a bright iPhone UI flash;
- a Watch haptic plus `/sync/vision_cue` event timestamped on the Watch
  monotonic clock.

Immediately after the cue, perform one sharp whole-body/board impulse. The
iPhone treats a cue as qualified only after the Watch has durably appended its
`/sync/vision_cue` event and returned the landmark ID. Immediate and queued
WatchConnectivity acknowledgments are both accepted; an unacknowledged cue
expires from the current qualification count and must be retried. The sealed
`vision_session.json` contains only acknowledged landmarks.

The cue receipt is a clock landmark; the physical impulse is the independent
cross-modal landmark visible in Watch IMU and both camera streams. Desktop
preflight also requires exactly one matching Watch-journal receipt for every
sealed landmark before any camera processing begins.

Do not claim frame-accurate synchronization from cue delivery alone. Fit and
validate the camera/Watch clock mappings from repeated physical landmarks and
retain predictive timing uncertainty.

## Board 6-DoF

`examples/indo-board-marker-layout.example.json` defines the board-local marker
frame. Replace every example coordinate with a physical measurement before
qualification. `motionos.board_pose.estimate_board_pose` rigidly fits
triangulated marker positions to that frozen layout and returns:

- world translation;
- board-to-world rotation matrix;
- roll, pitch, and yaw;
- fitted scale;
- RMS and maximum marker residual.

A scale mismatch larger than the declared tolerance fails closed.

## 2D → 3D pose bridge

`motionos.multiview_pose.build_skeleton_correspondences` takes one
quality-gated 2D pose frame per camera, requires explicit session-clock mapping,
rejects frames outside the timing-span limit, and emits the repository's
existing `motionos.multiview-correspondences.v1` input. The existing world
geometry pipeline remains the authoritative triangulator.

`motionos.uncertainty_fusion.inverse_variance_fuse` may then combine two
measurements only when they declare the same quantity and coordinate frame.
Timing uncertainty is converted into additional variance when a maximum
physical rate is supplied. Frame or quantity mismatches are errors rather than
implicit transformations.

## Long-term progress

`motionos.longitudinal` stores a durable
`motionos.longitudinal-profile.v1` profile. A source session can update the
profile only once. Metrics below the configured confidence floor do not alter
the baseline. Raw session reports remain separate evidence.

This provides the first real progression loop:

```text
camera-rich session
    ↓
quality-gated biomechanics metrics
    ↓
session report
    ↓
duplicate-safe longitudinal baseline
    ↓
future session comparison / personalized wearable teacher
```


## End-to-end operator path

The post-session path is now available as a deterministic CLI workflow. Install
the core development tools normally, and add the optional OpenCV contribution
package only on the workstation used for ChArUco/ArUco processing:

```bash
pip install -e '.[dev,vision]'
```

### 0. Generate and physically verify fiducials

Generate the exact ChArUco target and Indo Board ArUco markers from versioned
specs instead of downloading visually similar assets:

```bash
motionos build-charuco-board-assets \
  examples/charuco-board-build-spec.example.json \
  build/fiducials/charuco

motionos build-aruco-marker-assets \
  examples/indo-board-aruco-build-spec.example.json \
  build/fiducials/indo-board
```

The ChArUco command writes both a printable PNG and a
`motionos.calibration-board.v1` JSON whose
`printable_source_sha256` points to that exact PNG. The ArUco command writes
one PNG per marker plus a build receipt fixing dictionary, IDs, intended marker
size, DPI, and file hashes.

Print at **100% / Actual Size** with Fit/Shrink/Scale disabled. Before using the
assets:

1. measure a printed ChArUco square edge and confirm it matches the declared
   `square_length_m`;
2. measure the outer width of each printed ArUco marker;
3. reject/reprint if the physical scale is outside your frozen tolerance;
4. mount the ArUco markers flat on the actual Indo Board;
5. measure their final **center coordinates** on the mounted board and put those
   measured values into `indo-board-marker-layout.json`;
6. copy the marker size into `marker_size_m` and put the SHA-256 of the
   generated ArUco build receipt into `marker_asset_receipt_sha256`;
7. add that same receipt path as `board_marker_asset_receipt` in the final
   pipeline spec;
8. archive the generated build receipts with the experiment evidence.

Digital dimensions and DPI do not prove printer accuracy. The ruler measurement
is part of the physical calibration evidence.

### 1. Freeze camera geometry before the scored run

Use the same pixel orientation/decoding convention for calibration images and
later marker tracking. Fill a copy of
`examples/charuco-calibration-spec.example.json`, including an explicit
`world_from_board` transform. MotionOS does not infer world axes from a camera
image.

```bash
motionos calibrate-charuco iphone-charuco-spec.json iphone-calibration.json
motionos validate-camera-calibration iphone-calibration.json \
  --receipt iphone-calibration-receipt.json

motionos calibrate-charuco action4-charuco-spec.json action4-calibration.json
motionos validate-camera-calibration action4-calibration.json \
  --receipt action4-calibration-receipt.json
```

The rig receipt used by the final pipeline must refer to the exact current-run
camera sessions and clock-uncertainty artifacts. A passing calibration alone is
not permission to reuse an old session clock.

### 2. Capture the Indo Board trial

In the iPhone app:

1. arm **Indo Board · M0-Vision**;
2. freeze the feedback condition;
3. start the Action 4 and confirm it is recording;
4. start Watch + iPhone capture;
5. trigger at least three SYNC cues spread through the run and immediately
   perform a sharp whole-body/board impulse after each cue;
6. stop the iPhone capture and Watch workout;
7. import the untouched Action 4 movie;
8. run **Extract Action 4 2D Pose**.

The iPhone camera now journals both 2D and 3D Vision observations. Every iPhone
frame also records a host-monotonic timestamp anchor. The Action 4 processor
preserves source video PTS and writes a hash-bound 2D-pose/frame journal.

### 3. Normalize clocks

MotionOS uses Watch Core Motion time as the canonical analysis clock.

```bash
motionos sync-external-camera \
  vision_session.json \
  iphone/camera-frames.jsonl \
  action4/action4-frames.jsonl \
  action4-clock-sync.json

motionos build-vision-clock-bundle \
  vision_session.json \
  watch.jsonl \
  iphone/camera-frames.jsonl \
  action4-clock-sync.json \
  vision-clock-bundle.json
```

The mappings are:

```text
iPhone camera PTS ── frame anchors ──> iPhone host monotonic
Action 4 PTS     ── physical pose impulses ──> iPhone host monotonic
Watch time       ── journaled SYNC receipts ──> iPhone host monotonic
                                      │
                                      └── compose/invert → canonical Watch time
```

The cue itself only defines the search window for the iPhone physical-motion
peak. The cross-camera landmark is the actual whole-body impulse detected in
both pose streams, avoiding human response latency as the camera offset.

### 3.5. Calibrate Watch ↔ vision fusion on a separate run

Do **not** invent the Watch/vision fusion uncertainties for the scored session.
Use a separate reconstructed calibration run with one quiet stationary period
and one deliberately dynamic wrist-movement period.

Copy and freeze
`examples/wrist-fusion-calibration-spec.example.json` before inspecting the
calibration result. The windows are measured relative to the first paired
Watch/vision wrist-acceleration sample on canonical Watch time.

Run:

```bash
motionos calibrate-wrist-fusion \
  calibration/skeleton-geometry.json \
  calibration/skeleton-correspondences.json \
  calibration/watch.jsonl \
  wrist-fusion-calibration-spec.json \
  wrist-fusion-calibration.json
```

The calibration receipt reports:

- stationary Watch acceleration-magnitude RMS relative to zero motion;
- stationary vision acceleration-magnitude RMS relative to zero motion;
- stationary and dynamic Watch↔vision disagreement;
- observed Watch and vision scalar acceleration-rate distributions;
- the declared acceleration-rate percentile;
- the predeclared non-shrinking margin factor;
- the resulting `recommended_wrist_fusion` block;
- SHA-256 hashes of the exact geometry, correspondence, Watch-journal, and
  calibration-spec inputs.

Copy the four values from `recommended_wrist_fusion` into the scored pipeline
spec and set `wrist_fusion_calibration_receipt` to that exact receipt. Desktop
preflight verifies the copied values match the receipt, so manual drift fails
closed.

The calibration receipt intentionally does **not** choose
`qualification.maximum_watch_vision_rms_m_s2`. Freeze that scored-session gate
independently, before looking at the scored run, just like the other
qualification thresholds.

### 4. Preflight, then run the complete reconstruction

Copy and fill `examples/indo-board-pipeline-spec.example.json`. The
`rig_receipt` must be a passing, current-session rig receipt. The iPhone and
Action 4 entries each require the exact video, pose/frame journal, and metadata
file generated for that capture. The `wrist_fusion` parameters must match the
exact `wrist_fusion_calibration_receipt` produced from the separate calibration
run; arbitrary or hand-edited uncertainty values fail preflight.

Run the fail-fast check before creating derived evidence:

```bash
motionos validate-indo-board-vision-spec indo-board-pipeline.json
```

Preflight rejects the run before an output directory is created if any of the
following are wrong:

- required evidence files are missing;
- fewer than three Watch-acknowledged whole-body synchronization landmarks
  were sealed, or the Watch journal lacks a unique matching receipt for any
  sealed landmark;
- the vision session is not an Indo Board multiview-calibration session;
- a camera journal ID is absent from the passing rig receipt;
- the measured Indo Board marker layout is not bound to the exact ArUco print
  receipt, or its dictionary, IDs, or marker size disagree with that receipt;
- the iPhone MOV or frame journal hash does not match
  `camera-metadata.json`;
- the Action 4 video, pose journal, or derived metadata is not hash-bound to the
  sealed `vision_session.json`;
- the scored `wrist_fusion` values differ from the exact referenced
  wrist-fusion calibration receipt;
- a confidence fraction is outside `[0, 1]`;
- a timing, residual, uncertainty, or rate bound is non-positive/non-finite;
- the marker-frame stride is not a positive integer.

Only after preflight passes:

```bash
motionos process-indo-board-vision \
  indo-board-pipeline.json \
  results/indo-board-session-001
```

If an expensive run is interrupted after some stages have completed, rerun the
same command with `--resume`:

```bash
motionos process-indo-board-vision \
  indo-board-pipeline.json \
  results/indo-board-session-001 \
  --resume
```

Resume is deliberately conservative. `pipeline-state.json` records the exact
spec hash, implementation version, hashes of the sealed authoritative inputs,
and hashes of each completed stage. An intermediate is reused only when all of
those still match. Changing the spec, Watch journal, rig receipt, camera
metadata, marker layout, or a derived artifact invalidates reuse rather than
silently mixing evidence.

The command produces, in order:

```text
Action 4 physical-landmark clock fit
        ↓
iPhone + Action 4 → canonical Watch clocks
        ↓
2D pose pairing → calibrated 3D skeleton
        ↓
ArUco marker tracking → calibrated marker triangulation
        ↓
rigid Indo Board 6-DoF pose series
        ↓
anthropometric COM + bilateral knee geometry
        ↓
five quality-gated Indo Board metrics
        ↓
secondary Watch ↔ vision wrist-acceleration fusion
        ↓
dimensioned evidence-quality report (no composite score)
        ↓
frozen session qualification receipt
        ↓
qualified-only longitudinal profile update
        ↓
dimensioned evidence-quality report (no composite score)
        ↓
hash-linked pipeline receipt + resumable stage ledger
```

The secondary Watch fusion does not overwrite the five camera/board technique
metrics. It is a cross-modal consistency estimate for the wrist linear
acceleration magnitude, using gravity-subtracted Watch acceleration and the
second derivative of triangulated wrist position.

Before interpreting performance, inspect
`indo-board-quality-report.json`. It keeps timing, calibrated reprojection,
cross-view ray disagreement, board rigid-fit residuals/scale error,
reconstruction rejection reasons, metric confidence/unavailability, and
Watch↔vision disagreement as separate dimensions. `attention_flags` identify
which dimensions deserve inspection; they are not a quality score or a claim of
ground-truth accuracy.

The pipeline then applies the **predeclared** `qualification` section from the
pipeline spec and writes
`motionos.indo-board-qualification-receipt.v1`. Qualification is intentionally
a set of dimensioned gates rather than a composite score. The current contract
can gate:

- minimum synchronized pose and board-frame pairs;
- minimum rigid board-pose and accepted metric sample counts;
- minimum metric accepted-sample fraction;
- external, iPhone→Watch, and Action4→Watch clock residual RMS;
- skeleton and board-marker reprojection RMS;
- board rigid-fit p95 residual and p95 scale error;
- board-pose and reconstruction rejection fractions;
- Watch↔vision wrist-acceleration disagreement;
- explicit required metric availability.

Freeze these thresholds **before** looking at the scored run. The example spec
uses placeholders where an empirical/predeclared bound is required rather than
silently inventing a favorable limit.

A session updates the persistent longitudinal profile only when the
qualification receipt has `passed=true`. Failed sessions keep all raw and
derived evidence, metrics, quality diagnostics, and the failed gate list, but
they cannot teach the personal baseline. Re-running the same qualified session
also remains duplicate-safe and cannot count twice.

### 5. External Action 4 session provenance

For strict rig/clock evidence, the derived Action 4 journal can be imported as
its own MotionOS calibration session without pretending it came from
AVFoundation:

```bash
motionos import-external-camera \
  action4/action4-frames.jsonl \
  action4/original.mov \
  action4/action4-derived-metadata.json \
  --out data
```

The imported bundle receives a unique normalized session ID while retaining the
original vision-session ID, container PTS, source-video hash, journal hash and
metadata hash.
