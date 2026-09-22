# M0-B5 First Multimodal Calibration Ride

This runbook connects the independently qualified MotionOS capture paths into
the first real longboard calibration session:

- Apple Watch IMU + heart rate;
- MetaMotionS equipment IMU;
- bilateral plantar pressure + foot IMU;
- iPhone video + Vision 3D teacher pose;
- body-model reference.

The purpose of the first ride is to acquire trustworthy cross-modal evidence,
not to maximize speed or difficulty.

## Two verdicts

MotionOS deliberately separates:

### Evidence complete

`evidence_complete=true` means the required evidence graph is internally
consistent:

- Watch, equipment, insole, and camera sessions are present;
- their qualification receipts pass their modality-local gates;
- all three non-reference clocks have valid start/middle/end correspondence
  receipts to the Watch reference clock;
- the stored calibration clock models recompute from the referenced landmark
  evidence;
- equipment mount, left/right insole geometry, and body-model profiles are
  hash-bound into the calibration bundle;
- the required movement protocol is complete;
- referenced files and source sessions still match their recorded hashes.

### M0 qualified

`qualified=true` additionally requires **predeclared** cross-modal timing and
gap gates.

The first real ride should normally be run in **evidence mode** first. Use that
data to understand hardware behavior and choose defensible tolerances.

Do not inspect the first run, choose thresholds that fit it, and call that same
run confirmatory. Freeze the gates, then perform a new confirmatory ride.

## Before the ride

Complete the relevant device-local preparation:

1. Apple Watch P0 runbook.
2. MetaMotionS P1 runbook and equipment mount calibration.
3. Bilateral insole P2 runbook and left/right identity check.
4. Camera P5A runbook.
5. Generate the athlete body-model reference from the intended 3D body scan or
   another measured geometry source.

The example body-model file in this repository contains placeholder dimensions
only. Replace it with measured geometry before real use.

## Calibration bundle profiles

The calibration bundle should bind these profile kinds:

~~~text
equipment_mount
left_insole_geometry
right_insole_geometry
body_model
~~~

The ride gate checks the exact body-model file hash against the
`body_model` profile in the calibration bundle.

## Shared synchronization motions

Use deliberate shared landmarks near:

- start;
- middle;
- end.

Each should be visible in as many modalities as possible:

- Watch wrist IMU;
- equipment IMU;
- foot IMU;
- camera-derived pose-motion signal.

A controlled whole-body/board perturbation is generally preferable to a tiny
single-limb motion because the camera and equipment sensor both need a clear
event.

Keep the search windows narrow and record approximate windows during the run.
Do not let post-hoc full-recording peak search decide the correspondences.

## Required movement block

The first-ride movement log must contain each of these exactly once and mark it
complete only after it was actually performed:

~~~text
quiet_stance
pushes
straight_glide
left_carves
right_carves
front_load_shift
rear_load_shift
foot_repositioning
braking
stabilization_perturbations
sync_start
sync_middle
sync_end
~~~

Start from:

~~~text
examples/first-ride-movement-log.example.json
~~~

Suggested physical sequence:

1. start all modalities;
2. sync-start landmark;
3. 30 s quiet stance;
4. 10 controlled pushes;
5. straight glide;
6. repeated left carves;
7. repeated right carves;
8. front load shift;
9. rear load shift;
10. foot repositioning;
11. controlled braking/stopping;
12. safe stabilization perturbations;
13. sync-middle landmark near the temporal midpoint of the complete run;
14. repeat enough ordinary motion to span the desired duration;
15. sync-end landmark;
16. stop and seal every modality.

## Process each modality

Generate the individual MotionOS sessions and receipts using their dedicated
scripts:

~~~text
scripts/process_p0_watch.sh
scripts/process_p1_pod.sh
scripts/process_p2_opengo.sh
scripts/process_p5a_camera.sh
~~~

Do not alter the raw source files after receipt generation.

## Build each non-reference clock map

Derive:

~~~text
equipment -> Watch
OpenGo/insole session -> Watch
camera -> Watch
~~~

using `motionos derive-clock-sync` and explicit windows.

The clock receipts report:

- drift ppm;
- residual RMS;
- mapping quality;
- landmark count;
- start/middle/end structural coverage;
- exact source session hashes.

## Build the calibration bundle

Use:

~~~text
examples/calibration-bundle-spec.example.json
~~~

and run:

~~~bash
motionos build-calibration-bundle \
  calibration-spec.json \
  data/calibration/calibration.json
~~~

The bundle should reference all four source sessions, their receipts, all three
clock maps, equipment/insole/body profiles, and later any additional spatial
camera calibration.

## First evidence-only ride report

Start from:

~~~text
examples/first-ride-spec.example.json
~~~

Leave the timing gates unfrozen for the initial evidence-acquisition ride.

Run:

~~~bash
bash scripts/process_first_calibration_ride.sh \
  first-ride-spec.json \
  data/ride/first-ride-report.json \
  evidence
~~~

or directly:

~~~bash
motionos validate-first-ride \
  first-ride-spec.json \
  --report data/ride/first-ride-report.json \
  --evidence-only
~~~

A successful evidence-only exit means the evidence graph is complete. It does
not mean M0 timing tolerances have been validated.

## Inspect the first hardware evidence

Review, for equipment, insoles, and camera:

- clock drift ppm;
- clock residual RMS;
- mapping quality;
- observation count;
- structural landmark coverage.

Review the synchronized gap report:

- role;
- stream;
- mapped gap duration;
- expected interval;
- gap multiple.

Also inspect modality-specific failures:

- Watch sequence/gap metrics;
- pod board-tick gaps and flash recovery;
- bilateral insole overlap and pressure integrity;
- camera AVFoundation drops, writer backpressure, no-pose frames, Vision errors.

## Freeze thresholds

Only after the first real hardware evidence, decide whether an affine model is
sufficient and select the M0 timing gates.

The ride spec supports, per non-reference role:

~~~json
{
  "timing_gates": {
    "equipment": {
      "max_sync_residual_ms": "<freeze from evidence>"
    },
    "insoles": {
      "max_sync_residual_ms": "<freeze from evidence>"
    },
    "camera": {
      "max_sync_residual_ms": "<freeze from evidence>"
    }
  },
  "max_gap_multiple": "<freeze from evidence>"
}
~~~

Replace the placeholder strings with positive numeric values only after the
development evidence has been reviewed.

Changing a threshold defines a new criterion. Test the frozen criterion on a
new run.

## Confirmatory ride

Repeat the complete physical protocol with the frozen gates and run:

~~~bash
bash scripts/process_first_calibration_ride.sh \
  confirmatory-first-ride-spec.json \
  data/ride/confirmatory-first-ride-report.json \
  qualify
~~~

A full qualification pass requires:

- `evidence_complete=true`;
- all three synchronization thresholds frozen;
- all three residual gates passed;
- maximum-gap threshold frozen;
- every reported large gap within that threshold;
- `qualified=true`.

## Replay

After the evidence gate passes, use the calibration bundle directly:

~~~bash
motionos replay-calibration \
  data/calibration/calibration.json \
  --hz 10 \
  --frames 100
~~~

and:

~~~bash
motionos calibration-gaps \
  data/calibration/calibration.json
~~~

The replay retains each modality's raw clock beside mapped Watch/reference
time and exposes timestamp gaps rather than interpolating them away.

## What closes the M0 physical gate

A defensible M0 closure requires real hardware artifacts, not just software CI.

At minimum preserve:

- source Watch journal + host metadata;
- pod flash evidence + metadata;
- OpenGo raw export;
- source camera MOV + frame/pose journal + metadata;
- all four modality receipts;
- three clock-sync receipts;
- equipment mount profile;
- left/right insole geometry profiles;
- measured body model;
- completed movement log;
- calibration bundle;
- evidence-only development report;
- frozen threshold specification;
- confirmatory ride report;
- synchronized replay / gap report;
- short failure-mode log.

## Claim boundary

A qualified MotionOS M0 ride demonstrates reproducible capture and measured
temporal alignment under the tested hardware, mounts, settings, protocol, and
thresholds.

It does not establish:

- medical accuracy;
- laboratory-grade biomechanics;
- full 3D ground-reaction force;
- optical-motion-capture-equivalent pose;
- general performance across every sport.

Those are later validation layers.
