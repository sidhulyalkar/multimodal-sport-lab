# M0-B5A iPhone Camera + Vision 3D Pose Runbook

This protocol turns one iPhone recording into auditable MotionOS camera evidence.

The raw artifacts are:

```text
camera.mov
camera.jsonl
camera-metadata.json
```

Keep all three together and unchanged after capture.

## What MotionOS records

### /camera/frame

One event for every frame delivered to the analysis output.

The event's `device_time_ns` is the Core Media presentation timestamp converted
to nanoseconds.

It also records the callback's iPhone monotonic time as diagnostic evidence.

Do not use callback-arrival time as the authoritative frame timestamp.

### /camera/pose3d

Vision 3D pose is sampled at a lower rate than video capture.

The raw pose payload preserves:

- root-relative joint positions in meters;
- joint count;
- Vision body-height estimate;
- Vision height-estimation mode;
- camera-origin matrix;
- video presentation timestamp;
- explicit coordinate-basis label.

These values are evidence from Vision. They are not rewritten into the athlete's
body-scan frame during ingestion.

### /camera/motion_energy

This stream is derived in Python after import.

For consecutive pose observations, MotionOS finds common joints and computes:

```text
RMS 3D joint displacement / elapsed camera time
```

The result is a scalar in m/s with links to the source pose sequence numbers.

Its purpose is deliberate physical landmark synchronization, not biomechanics.

## Phone placement for the first ride

Use a fixed tripod/stand and record a broad side view.

For the first physical qualification:

- use the back camera;
- mount the phone landscape-right;
- keep the entire athlete + longboard inside frame;
- keep the tripod fixed for the whole run;
- avoid digital zoom changes;
- avoid moving the phone between start/middle/end landmarks;
- record the approximate camera location/height in the failure-mode notes.

Camera extrinsics are not yet claimed. Fixed placement simply makes the first
evidence run interpretable and repeatable.

## Capture sequence

1. Authorize Camera in the iPhone MotionOS app.
2. Start the Watch workout/capture path.
3. Start camera evidence.
4. Perform the shared **start** synchronization motion.
5. Run the planned calibration movements.
6. Near the middle, perform the same synchronization motion again.
7. Near the end, perform it a third time.
8. Stop camera evidence and confirm the bundle closes.
9. Stop/recover the Watch and other sensor evidence.
10. Share/export all three camera evidence files.

Use a large, fast whole-body/arm motion that is unmistakable in:
- Watch wrist IMU;
- equipment/foot motion when applicable;
- camera Vision pose.

Do not choose landmarks by searching the entire recording after the fact.

## Process exported camera evidence

For a 10-minute run:

```bash
bash scripts/process_camera_evidence.sh \
  /path/to/camera.jsonl \
  /path/to/camera.mov \
  data/camera \
  600 \
  /path/to/camera-metadata.json \
  longboard
```

Equivalent direct commands:

```bash
motionos import-camera-evidence \
  /path/to/camera.jsonl \
  /path/to/camera.mov \
  --metadata /path/to/camera-metadata.json \
  --out data/camera \
  --sport longboard

motionos validate-camera \
  data/camera/<camera-session> \
  --min-duration 600 \
  --receipt data/camera/<camera-session>/camera-capture-receipt.json
```

## What a camera capture pass means

A passing capture receipt establishes:

- video/journal/sidecar files existed and were fingerprinted;
- frame and pose streams exist;
- frame PTS is monotonic;
- pose PTS is monotonic;
- pose events correspond to captured frame PTS;
- frame and pose journal sequences are intact;
- raw pose joint arrays are finite 3-vectors;
- pose coordinate semantics are explicitly root-relative meters;
- deterministic pose-motion evidence can be derived;
- required environment/camera metadata exists;
- the frame stream spans the requested minimum duration.

The receipt reports:
- frame count/rate/median interval/max gap;
- pose count/rate/max gap;
- pose attempt count;
- successful pose-detection fraction;
- derived motion-event count;
- video byte size;
- source SHA-256 values.

The first hardware run should be used to freeze acceptable camera-gap and
pose-detection thresholds rather than choosing them in advance.

## Camera → Watch synchronization

After a qualifying camera import, define narrow independent windows for the
three shared movements.

Use the derived camera motion stream:

```bash
motionos derive-clock-sync \
  data/p0/<watch-session> \
  data/camera/<camera-session> \
  camera-sync-windows.json \
  data/sync/camera-to-watch.json \
  --reference-stream /body/watch/imu \
  --target-stream /camera/motion_energy \
  --target-keys motion_energy_mps \
  --target-coverage-stream /camera/frame
```

The result keeps camera video PTS as raw target time and maps it into Watch
reference time only in the calibration layer.

Peak search uses the sparse derived motion stream, but structural
start/middle/end coverage is judged against the full raw `/camera/frame`
capture span. This prevents late-starting Vision detections from making a
mid-recording landmark look like a valid "start" landmark.

A low residual alone is insufficient. Start/middle/end structural landmark
coverage must also pass.

## Add camera to the calibration bundle

Add a source entry:

```json
{
  "role": "camera",
  "session": "data/camera/<camera-session>",
  "receipt": "data/camera/<camera-session>/camera-capture-receipt.json",
  "clock_sync": "data/sync/camera-to-watch.json"
}
```

Then rebuild the calibration manifest.

Replay will preserve:

```text
raw camera PTS
mapped Watch/reference time
clock-model quality
raw Vision payload
explicit missing-data regions
```

## 3D body scan boundary

Do not scale or warp Vision joints to the personal body scan in this tranche.

The body scan can later provide:
- segment-length priors;
- asymmetric anthropometry;
- foot dimensions;
- joint-center priors;
- equipment-contact geometry.

That later fusion layer must preserve both:
1. raw Vision evidence;
2. transformed/fused pose estimates.

## Physical B5-A acceptance

Before calling camera capture qualified:

- [ ] >=10 min real iPhone recording
- [ ] video closes and exports
- [ ] sidecar records device/lens/orientation/dimensions/rates
- [ ] camera receipt passes
- [ ] frame gaps reviewed
- [ ] pose-detection fraction reviewed
- [ ] start/middle/end landmarks visible
- [ ] camera→Watch clock receipt passes structural coverage
- [ ] sync residual/drift reported
- [ ] repeat on another day/lighting condition before relying on Vision pose

## Claim boundary

This protocol does not validate:
- Vision as pose ground truth;
- camera extrinsics;
- body-scan registration;
- sport biomechanics;
- clinical measurements.

It creates the reproducible evidence needed to test those later.
