# P5A iPhone Camera + Vision 3D Runbook

This stage qualifies the camera/video evidence leg needed for the first real
multimodal longboard calibration ride.

Simulator/native compilation is necessary but does not close the physical
camera gate.

## Before recording

1. Use the rear camera.
2. Mount the iPhone rigidly in native landscape orientation.
3. Frame the athlete so the full body and board remain visible through the
   calibration movements.
4. Avoid changing zoom during the run.
5. Keep lighting and shutter conditions reasonable enough that motion blur does
   not dominate the Vision teacher signal.
6. Start the Watch, equipment pod, and insole captures according to their own
   runbooks.

The camera keeps its own PTS clock.

## Camera preparation

In the iPhone MotionOS host:

1. open **Camera + Vision 3D / P5A**;
2. choose **Authorize & Prepare Camera**;
3. confirm the rear camera and format are displayed;
4. note whether intrinsic delivery is enabled or unavailable.

No calibration value should be invented when intrinsics are unavailable.

## Start

Choose:

~~~
Start Video + Pose Evidence
~~~

MotionOS begins MOV writing, frame PTS journaling, explicit drop reporting, and
scheduled Vision 3D pose extraction.

## Deliberate synchronization motions

Perform a visually obvious, safe shared motion near start, middle, and end.

The movement must be observable in Watch wrist IMU and camera/Vision
subject-camera motion, and when possible equipment/foot sensors.

For a longboard calibration, a controlled whole-body/board perturbation or
distinctive coupled hand/board motion is preferable to a tiny wrist-only flick
that the camera may not resolve.

Record approximate windows while the action is happening. Do not choose windows
only after seeing the fitted residual.

## Calibration movement block

For the first longboard camera run include:

1. 30 s quiet stance;
2. 10 pushes;
3. straight glide;
4. repeated left carves;
5. repeated right carves;
6. front-load shift;
7. rear-load shift;
8. foot repositioning;
9. controlled braking/stopping;
10. deliberate stabilization perturbations;
11. start/middle/end sync motions.

The point of this run is coverage and observability, not athletic performance.

## Stop

Choose:

~~~
Stop & Seal Camera Evidence
~~~

Wait for the final state:

~~~
EVIDENCE READY
~~~

Share all three files:

~~~
camera.mov
camera-frames.jsonl
camera-metadata.json
~~~

Do not edit or transcode the source MOV before import.

## Import + validate

For a 10-minute qualification:

~~~
bash scripts/process_p5a_camera.sh \
  /path/to/p5a-camera-session \
  data/camera \
  600
~~~

This produces a canonical MotionOS camera session and
`camera-capture-receipt.json`.

## What the receipt checks

The capture gate checks MOV/journal provenance, sidecar/journal count agreement,
frame PTS monotonicity, delivered-frame sequence continuity, exact
pose-to-source-frame linkage, root-relative Vision joint contract,
camera-origin transform contract, delivered versus MOV-written frames, explicit
AVFoundation drop events, and existence of a derived pose-motion timing stream.

## Intrinsics

Intrinsics are useful when available, but absence does not make the video
invalid.

If delivered, MotionOS stores the matrix beside the frame dimensions to which
it applies.

If absent, the sidecar states that intrinsic delivery was unavailable for that
hardware/format.

## Camera to Watch clock map

Create three or more narrow windows around the deliberate shared motions, using
the Watch clock for reference windows and camera PTS for target windows.

Then run:

~~~
bash scripts/process_p5a_camera.sh \
  /path/to/p5a-camera-session \
  data/camera \
  600 \
  data/p0/<watch-session> \
  camera-sync-windows.json
~~~

or directly:

~~~
motionos derive-clock-sync \
  data/p0/<watch-session> \
  data/camera/<camera-session> \
  camera-sync-windows.json \
  camera-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /camera/pose_motion \
  --target-keys motion_m
~~~

The structural start/middle/end coverage gate from M0-B4 still applies.

## Add camera to the calibration bundle

The camera becomes one more non-reference source:

~~~json
{
  "role": "camera",
  "session": "data/camera/<camera-session>",
  "receipt": "data/camera/<camera-session>/camera-capture-receipt.json",
  "clock_sync": "data/camera/<camera-session>/camera-to-watch.json"
}
~~~

The calibration bundle then verifies the camera session hash, receipt hash,
clock-sync source hashes, and stored model before replay.

## Failure modes to record, not hide

- AVFoundation frame drops;
- writer backpressure;
- Vision no-pose frames;
- Vision errors;
- missing intrinsics;
- camera obstruction;
- athlete leaving frame;
- strong motion blur;
- landmark ambiguity;
- camera mount movement.

Do not interpolate missing Vision poses to make the replay look smoother during
M0 qualification.

## Physical acceptance

A camera run is physically useful for M0 only when:

- [ ] at least 10 minutes of real capture exists;
- [ ] MOV and journal close successfully;
- [ ] camera receipt passes;
- [ ] pose evidence is present;
- [ ] start/middle/end shared landmarks exist;
- [ ] camera-to-Watch clock receipt passes structural coverage;
- [ ] drift and residual are reported;
- [ ] failure counts are reviewed;
- [ ] camera orientation/mount is documented.

## Claim boundary

Vision pose remains teacher/validation evidence.

This protocol does not turn a single iPhone camera into a laboratory optical
motion-capture system.
