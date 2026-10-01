# First Physical M0-Vision Indo Board Run

This is the operator runbook for the first real Apple Watch + iPhone + DJI Osmo
Action 4 Indo Board qualification. The goal is not to make the first dataset
look good. The goal is to produce one auditable result that can fail honestly.

## Stop rule

Do not edit a sealed calibration receipt, frozen qualification plan, or scored
session thresholds after observing the scored result. If the experiment fails,
keep the evidence, explain the failed gate, fix the physical setup or protocol,
freeze a new plan, and capture a new session.

## Capture profile

### iPhone

MotionOS M0-Vision now requires the rear wide camera to support a locked 30 fps
capture rate. The camera card must show the selected resolution and **30 fps
locked** before recording.

Initial capture policy:

- rear wide camera;
- 1920×1080 AVFoundation capture preset;
- 30 fps locked when the active format supports it;
- native camera PTS retained;
- Vision pose scheduled every third delivered frame;
- nominal iPhone pose opportunity rate: approximately 10 Hz;
- camera intrinsics retained when AVFoundation exposes them.

If MotionOS cannot lock 30 fps, treat that as a failed preflight rather than
silently changing cadence.

### DJI Osmo Action 4

For the fixed tripod M0 geometry experiment use:

- 4K 16:9 at 60 fps;
- electronic stabilization **off**;
- no digital zoom;
- Standard (Dewarp) FOV when the entire athlete + Indo Board + fiducials fit
  comfortably in frame;
- if a wider FOV is required, recalibrate the camera in exactly that same mode;
- keep the camera on a rigid tripod and do not move it after calibration/mount
  verification.

The calibration footage and scored footage must use the same Action 4 image
pipeline. Electronic stabilization is not allowed for the calibration rig
because it can crop/warp the image from frame to frame.

The offline Action 4 pose extractor schedules Vision every third source frame,
so 60 fps footage provides a nominal 20 Hz pose opportunity rate. Two-camera
pairing is therefore expected to be limited primarily by the iPhone's nominal
10 Hz pose stream.

## Framing

Use landscape framing for both cameras. The full body, both feet, Indo Board,
and all board fiducials should remain visible through the intended motion
envelope with margin around the image edges.

Use a useful angular baseline rather than putting the cameras beside each other.
The existing M0 geometry target is approximately 70–110 degrees of separation
when the room permits it.

Avoid extreme backlighting, moving tripods, autofocus obstructions, reflective
fiducial coverings, and loose marker edges.

## Synchronization gesture

A synchronization cue is **not** a board perturbation.

After each MotionOS SYNC cue, perform one rapid, unmistakable bilateral arm
gesture that strongly moves the Watch wrist and is visible in both cameras while
trying to keep the board near neutral. A quick arms-up/arms-out snap and return
works better for this purpose than deliberately rocking the board.

This keeps the clock landmark visually obvious without intentionally injecting a
large board-tilt event into the recovery metric.

## Run A: Watch + vision calibration

Duration target: **120 s**.

| Session time | Action |
| --- | --- |
| 0–15 s | Quiet stationary stance / wrist, minimal voluntary motion |
| ~18 s | SYNC 1 + sharp arm gesture |
| 25–55 s | Dynamic wrist/arm block: smooth figure-eights, flexion/extension, pronation/supination, varied speed |
| ~65 s | SYNC 2 + sharp arm gesture |
| 70–105 s | Relaxed movement / neutral balance, preserve camera visibility |
| ~110 s | SYNC 3 + sharp arm gesture |
| 120 s | Stop and seal |

Use:

```bash
cp examples/wrist-fusion-calibration-spec.first-run.json \
  wrist-fusion-calibration-spec.json
```

The concrete first-run sample gates are:

- stationary window: 15 s;
- dynamic window: 30 s;
- minimum stationary paired samples: 75;
- minimum dynamic paired samples: 150;
- acceleration-rate percentile: p99;
- non-shrinking rate margin: 1.25×.

At the nominal 10 Hz limiting pose cadence, the windows contain approximately
150 and 300 possible paired frames respectively. The gates therefore require
roughly half of the nominal opportunities to survive pose detection, timing, and
pairing. If they do not, fix visibility/cadence/synchronization and rerun. Do not
lower these values after seeing the failed calibration run.

After sealing/importing Action 4 evidence:

```bash
motionos reconstruct-wrist-fusion-calibration \
  wrist-fusion-reconstruction-spec.json \
  derived/wrist-fusion-calibration

motionos calibrate-wrist-fusion \
  derived/wrist-fusion-calibration/skeleton-geometry.json \
  derived/wrist-fusion-calibration/skeleton-correspondences.json \
  calibration/watch.jsonl \
  wrist-fusion-calibration-spec.json \
  wrist-fusion-calibration.json
```

Archive both receipts.

## Freeze the scored plan

Only after Run A has produced a valid calibration receipt should the scored
qualification plan be built.

Use the passing rig receipt, measured marker geometry, exact ArUco build receipt,
and exact wrist-fusion calibration receipt. Copy the four calibrated
`recommended_wrist_fusion` values without modification.

Qualification limits must be selected before Run B exists. For the first
physical qualification:

- timing and reprojection limits should not be looser than the existing M0
  analysis bounds unless a new plan explicitly justifies the change;
- minimum pair/sample counts should be based on the fixed 120 s protocol and the
  known nominal capture cadences, not on Run B's observed counts;
- the Watch↔vision disagreement limit may be derived from Run A using a rule
  chosen before Run B, but must not be fit to Run B;
- keep `required_metric_ids` equal to all five M0 metrics.

Build and immediately inspect the plan:

```bash
motionos build-indo-board-qualification-plan \
  indo-board-qualification-plan-spec.json \
  indo-board-qualification-plan.json

motionos indo-board-status indo-board-qualification-plan.json
```

## Run B: scored Indo Board qualification

Duration target: **120 s**.

Use the feedback condition frozen in the qualification plan. The initial
scientific baseline should normally use `feedback_disabled`.

| Session time | Action |
| --- | --- |
| 0–10 s | Settle into neutral balance |
| ~12 s | SYNC 1 + sharp arm gesture, minimize board tilt |
| 20–45 s | Natural free balance |
| ~50 s | SYNC 2 + sharp arm gesture |
| 55–90 s | Five comfortable controlled tilt-and-recover cycles, alternating directions, return to neutral after each |
| 95–105 s | Natural free balance |
| ~110 s | SYNC 3 + sharp arm gesture |
| 120 s | Stop and seal |

Do not deliberately chase the software's 8-degree disturbance threshold. The
physical task is to create reproducible, comfortable perturbation/recovery
events; MotionOS determines afterward which episodes satisfy the predeclared
metric definition.

For the first attempts, perform the Indo Board work in a clear area with a
stable support or spotter available. A data point is not worth a fall.

Import the untouched Action 4 file and run the Action 4 2D pose extraction.
Then fill the scored pipeline spec from the frozen plan and exact session
artifacts.

Before processing:

```bash
motionos validate-indo-board-vision-spec indo-board-pipeline.json

motionos indo-board-status \
  indo-board-qualification-plan.json \
  --pipeline indo-board-pipeline.json
```

Only if preflight is valid:

```bash
motionos process-indo-board-vision \
  indo-board-pipeline.json \
  results/indo-board-session-001
```

Then:

```bash
motionos indo-board-status \
  indo-board-qualification-plan.json \
  --pipeline indo-board-pipeline.json \
  --results results/indo-board-session-001
```

## What counts as success

The software pipeline running to completion is not the success criterion.

The first physical M0-Vision qualification succeeds only when:

- Watch evidence is durably transferred and hash-verified on iPhone;
- iPhone camera metadata confirms the locked capture profile;
- all three sealed SYNC landmarks have exactly one Watch receipt;
- the Action 4 source video and derived pose evidence remain hash-bound;
- camera/rig calibration remains passing and unchanged;
- board marker geometry remains bound to the physically verified marker asset;
- the scored pipeline still matches the frozen pre-capture qualification plan;
- all required quality gates pass;
- all five M0 metrics are available;
- the final qualification receipt has `passed=true`;
- only then does the longitudinal profile update.

A failed run is still valuable. Preserve it as a failure case and use its
dimensioned quality report to decide whether the next change belongs in camera
placement, lighting, synchronization, marker visibility, pose inference,
calibration, or the task protocol.

## After the first pass

Do not immediately add more sensors. Repeat the exact protocol enough times to
measure repeatability first.

The next product question is whether camera-rich latent state is stable enough
to teach a Watch-only model. Once repeated qualified sessions establish that,
the camera can begin changing from a permanent requirement into a periodic
teacher/calibration instrument.
