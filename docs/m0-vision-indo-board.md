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

The first physical qualification uses one fixed acquisition profile:

- **iPhone:** rear wide camera, 1920×1080, 30 fps locked, AVFoundation video
  stabilization explicitly off, Vision 2D/3D pose scheduled every third
  delivered frame (~10 Hz when capture holds 30 fps).
- **Action 4:** 3840×2160 (4K 16:9), 60 fps, electronic stabilization off,
  **Standard (Dewarp)** FOV, rigid tripod, and offline Vision 2D pose extracted
  from every decoded frame.
- Do not change FOV, stabilization, resolution, frame rate, orientation, zoom,
  camera position, or mount geometry between ChArUco calibration, the separate
  wrist-fusion calibration run, and the scored run.

The Action 4 stabilization/FOV settings are operator-confirmed because MotionOS
does not pretend those settings are reliably recoverable from the imported MP4.
Resolution, decoded frame cadence, and offline pose stride are machine-checked.

1. Put the Action 4 on a rigid tripod 30–60 degrees off frontal.
2. Put the iPhone roughly 70–110 degrees away from it.
3. Keep the full athlete, board, feet, and calibration target visible.
4. Confirm the Action 4 profile in the iPhone MotionOS card before capture.
5. Use the existing ChArUco world-frame flow to calibrate intrinsics/extrinsics.
6. Do not move either camera after mount verification.
7. Start Watch capture, iPhone video, and Action 4 recording.
8. Near the beginning, middle, and end, emit a MotionOS sync cue and perform one
   sharp whole-body/board impulse that is visible in both videos and the Watch IMU.
9. Preserve original Action 4 media and import it without transcoding before
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

With the fixed profile, iPhone pose is scheduled every third 30 fps frame,
while Action 4 offline pose is extracted from every 60 fps frame. This makes
the external pose grid dense enough that a synchronized iPhone pose has an
Action 4 frame within roughly half a 60 fps frame interval (~8.3 ms) before
clock-model uncertainty. The 10 ms pairing gate therefore has a physically
meaningful cadence basis rather than relying on fortunate phase alignment.

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

### 2. Capture a separate Watch ↔ vision calibration run

Keep the qualified iPhone + Action 4 rig fixed. This run is **not** the scored
Indo Board session and cannot update the longitudinal profile.

In the iPhone app:

1. arm **Indo Board · M0-Vision** with feedback disabled;
2. start the Action 4 and confirm it is recording;
3. start Watch + iPhone capture;
4. collect at least three Watch-journaled SYNC cues with sharp physical
   whole-body/wrist impulses spread through the run;
5. include the stationary and dynamic wrist periods you declared in
   `examples/wrist-fusion-calibration-spec.example.json`;
6. stop and seal the iPhone evidence;
7. import the untouched Action 4 movie;
8. run **Extract Action 4 2D Pose**;
9. validate the acquisition profile and archive its receipt:

```bash
motionos validate-indo-board-acquisition \
  calibration/vision_session.json \
  calibration/iphone/camera-metadata.json \
  calibration/action4/action4-derived-metadata.json \
  calibration/acquisition-receipt.json
```

Do not continue to 3D reconstruction if this command exits non-zero.

The frozen first-run calibration windows are 5–15 s stationary and 20–50 s
dynamic, with at least 60 and 180 paired Watch/vision samples respectively.
These floors are derived from the ~10 Hz iPhone pose cadence with room for
non-detections rather than chosen after looking at results. Use a ~60 s
calibration run with SYNC impulses near ~2 s, ~30 s, and ~58 s so the stationary
window is not contaminated by the first cue.

The stationary interval should be genuinely quiet. The dynamic interval should
contain representative wrist acceleration changes without trying to imitate the
later scored outcome.

### 3. Reconstruct only the calibration-run 3D skeleton

Fill a copy of
`examples/wrist-fusion-reconstruction-spec.example.json`. It points to the
calibration run's sealed vision sidecar, Watch journal, iPhone pose journal,
Action 4 pose journal, metadata, and the already-qualified camera rig.

Run:

```bash
motionos reconstruct-wrist-fusion-calibration \
  wrist-fusion-reconstruction-spec.json \
  derived/wrist-fusion-calibration
```

This command deliberately stops before board tracking, technique metrics,
qualification, and longitudinal learning. It produces:

```text
Action 4 physical-landmark clock fit
        ↓
Watch / iPhone / Action 4 → canonical Watch time
        ↓
synchronized two-camera 2D pose pairs
        ↓
calibrated 3D skeleton geometry
        ↓
wrist-fusion-reconstruction-receipt.json
```

The clock mappings are:

```text
iPhone camera PTS ── frame anchors ──> iPhone host monotonic
Action 4 PTS     ── physical pose impulses ──> iPhone host monotonic
Watch time       ── journaled SYNC receipts ──> iPhone host monotonic
                                      │
                                      └── compose/invert → canonical Watch time
```

The cue defines a search window. The physical pose impulse, not human button
response time, is the cross-camera landmark.

### 4. Derive empirical wrist-fusion parameters

Freeze
`examples/wrist-fusion-calibration-spec.example.json` before inspecting the
calibration result. Its windows are measured relative to the first paired
Watch/vision wrist-acceleration sample on canonical Watch time. The spec also
references the exact `wrist-fusion-reconstruction-receipt.json`; MotionOS
verifies that receipt uses the current M0 acquisition profile and that its
skeleton geometry, correspondences, and Watch-journal hashes match the files
being calibrated.

Run:

```bash
motionos calibrate-wrist-fusion \
  derived/wrist-fusion-calibration/skeleton-geometry.json \
  derived/wrist-fusion-calibration/skeleton-correspondences.json \
  calibration/watch.jsonl \
  wrist-fusion-calibration-spec.json \
  wrist-fusion-calibration.json
```

The calibration receipt reports stationary Watch and vision
acceleration-magnitude RMS, stationary/dynamic cross-modal disagreement,
acceleration-rate distributions, the frozen rate percentile and margin, and a
`recommended_wrist_fusion` block. It records the acquisition-profile ID and
hashes the exact reconstruction receipt, geometry, correspondences,
Watch-journal, and calibration-spec inputs.

The receipt intentionally does **not** choose the later
`qualification.maximum_watch_vision_rms_m_s2` gate. That scored-session limit
must be frozen independently.

### 5. Freeze the scored-session qualification plan

Before capturing the scored trial, fill
`examples/indo-board-qualification-plan-spec.example.json`.

This is the pre-registration boundary. The plan freezes:

- the passing camera-rig receipt;
- measured Indo Board marker geometry and exact ArUco print receipt;
- the exact wrist-fusion calibration receipt and its four recommended values;
- all analysis/reconstruction thresholds;
- all final session-qualification gates;
- the required feedback condition;
- the minimum number of Watch-journaled SYNC landmarks.

Build the frozen plan:

```bash
motionos build-indo-board-qualification-plan \
  indo-board-qualification-plan-spec.json \
  indo-board-qualification-plan.json
```

Do this **before** the scored session exists. The later scored pipeline spec must
point to this exact plan, and preflight rejects any threshold, evidence hash,
feedback condition, fusion parameter, or synchronization requirement that has
drifted from it.

You can inspect the frozen state before capture without mutating anything:

```bash
motionos indo-board-status indo-board-qualification-plan.json
```

At this point the expected next action is to capture the scored session.

### 6. Capture the scored Indo Board trial

Now capture the session whose performance will actually be interpreted.

For the first qualification, use this fixed ~90 s task rather than improvising:

| Approx. time | Task |
| --- | --- |
| 0–10 s | settle into neutral stance; quiet balance |
| ~10 s | SYNC 1, then one sharp but controlled whole-body/board impulse |
| 12–32 s | natural balance; avoid deliberately chasing the board |
| 32–52 s | 4–6 controlled perturb-and-recover cycles; only use a tilt you can safely recover from |
| ~55 s | SYNC 2 + controlled impulse |
| 58–78 s | natural balance again |
| ~80 s | SYNC 3 + controlled impulse |
| 82–90 s | settle near neutral and hold through the end |

The recovery metric currently needs at least one complete episode whose board
tilt crosses 8° and later remains at or below 3° while modeled horizontal COM is
within 4 cm of its session center for at least 0.5 s. Do not force a larger
perturbation merely to satisfy software. If that range is not comfortable and
controlled, let the metric remain unavailable and revise the detector after
reviewing evidence.

For the first physical run, keep a stable support/rail within reach, clear the
fall area, and do not use live technique coaching.

In the iPhone app:

1. arm **Indo Board · M0-Vision**;
2. select the feedback condition frozen in the qualification plan;
3. start the Action 4 and confirm it is recording;
4. start Watch + iPhone capture;
5. collect at least the frozen minimum number of Watch-journaled SYNC cues,
   spread across the run, with a sharp physical impulse after each cue;
6. perform the frozen Indo Board trial protocol;
7. stop and seal the iPhone evidence;
8. import the untouched Action 4 movie;
9. run **Extract Action 4 2D Pose**;
10. validate the same fixed acquisition profile:

```bash
motionos validate-indo-board-acquisition \
  scored/vision_session.json \
  scored/iphone/camera-metadata.json \
  scored/action4/action4-derived-metadata.json \
  scored/acquisition-receipt.json
```

The iPhone camera journals 2D/3D Vision observations plus host-monotonic frame
anchors. The Action 4 processor preserves original container PTS and writes a
hash-bound 2D-pose/frame journal.

### 7. Preflight, then run the complete scored reconstruction

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

Then ask MotionOS for the operator-level state:

```bash
motionos indo-board-status \
  indo-board-qualification-plan.json \
  --pipeline indo-board-pipeline.json
```

A valid result here means the scored evidence and analysis configuration still
match the frozen pre-capture plan. It does not yet mean the session qualified.

Preflight rejects the run before an output directory is created if any of the
following are wrong:

- required evidence files are missing;
- fewer Watch-acknowledged whole-body synchronization landmarks were sealed
  than the frozen qualification plan requires, or the Watch journal lacks one
  unique matching receipt for any sealed landmark;
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
- the rig, marker evidence, analysis thresholds, qualification gates, feedback
  condition, fusion parameters, or minimum SYNC requirement differ from the
  frozen qualification plan;
- a confidence fraction is outside `[0, 1]`;
- a timing, residual, uncertainty, or rate bound is non-positive/non-finite;
- the marker-frame stride is not a positive integer.

Only after preflight passes:

```bash
motionos process-indo-board-vision \
  indo-board-pipeline.json \
  results/indo-board-session-001
```

After processing, summarize the entire chain in one read-only command:

```bash
motionos indo-board-status \
  indo-board-qualification-plan.json \
  --pipeline indo-board-pipeline.json \
  --results results/indo-board-session-001
```

The status output surfaces the final qualification result, any failed gate IDs,
quality attention flags, whether the longitudinal baseline was newly updated,
and the next concrete operator action.

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

Freeze these thresholds in the pre-capture qualification plan **before the
scored run exists**. The example plan spec uses placeholders where an
empirical/predeclared bound is required rather than silently inventing a
favorable limit.

A session updates the persistent longitudinal profile only when the
qualification receipt has `passed=true`. Failed sessions keep all raw and
derived evidence, metrics, quality diagnostics, and the failed gate list, but
they cannot teach the personal baseline. Re-running the same qualified session
also remains duplicate-safe and cannot count twice.

### 8. External Action 4 session provenance

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
