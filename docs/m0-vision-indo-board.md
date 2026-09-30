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
5. emit start/middle/end sync cues;
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

Immediately after the cue, perform one sharp whole-body/board impulse. The cue
receipt is a clock landmark; the physical impulse is the independent
cross-modal landmark visible in Watch IMU and both camera streams.

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
