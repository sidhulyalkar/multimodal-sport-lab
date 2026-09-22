# P1 MetaMotionS Physical Qualification Runbook

P1 asks a narrower question than the future product:

> Can a MetaMotionS mounted on equipment produce durable, recoverable,
> board-timestamped motion evidence that can be mapped to the Apple Watch
> clock with measured error?

Do not use simulator success as P1 evidence.

## Evidence files

The iPhone P1 console exports two files after a successful recovery:

```text
pod.jsonl
pod-metadata.json
```

Keep them in the same directory.

The Watch P0 evidence for the same physical run should also be preserved as its
own MotionOS session. P1 never rewrites either raw source clock.

## Before the run

1. Charge the Watch, iPhone, and MetaMotionS.
2. Mount the pod rigidly to the equipment.
3. Generate or select the correct equipment profile.
4. Verify the iPhone console identifies **MetaMotion S**.
5. Use **Preview** only to inspect mounting/orientation and clipping risk.
6. Stop Preview before arming flash logging.
7. Record the intended thresholds before inspecting the result.

Recommended **development** starting gates, not validated product
specifications:

```text
rate_tolerance_fraction = 0.05
max_gap_multiple        = 2.0
max_sync_residual_ms    = 20
```

These are deliberately exposed as CLI arguments rather than hard-coded truth.
Freeze the values in the experiment notes before looking at the qualification
receipt.

## P1-A: controlled 10-minute run

Run the Watch P0 capture and MetaMotionS P1 capture together.

### Start

1. Start the Apple Watch capture.
2. Arm the MetaMotionS flash logger.
3. Hold the equipment still for 30 seconds.
4. Create a distinctive shared impulse visible to both sensors:
   - a firm, safe equipment tap or short mechanical impulse,
   - while the Watch hand is physically coupled to the equipment.

Do not use an impact strong enough to damage equipment or sensors.

### Middle

At roughly five minutes:

1. create a second distinctive shared impulse;
2. deliberately break the phone↔pod BLE link;
3. continue moving the equipment while disconnected for at least 30 seconds;
4. reconnect;
5. choose **Reconnect & Recover Logger Registry**.

The flash logger is the authoritative evidence path. Loss of live BLE preview is
not itself data loss.

### End

Near ten minutes:

1. create a third distinctive shared impulse;
2. stop the Watch capture;
3. choose **Stop, Recover & Export** for the pod;
4. wait for both pod streams to download;
5. export the P1 evidence bundle.

The app clears pod flash only after both typed downloads succeed.

## Step 1: import the pod evidence

```bash
motionos import-pod-journal \
  /path/to/pod.jsonl \
  --out data/p1 \
  --profile /path/to/equipment-profile.json
```

The command prints the imported MotionOS session directory.

## Step 2: inspect capture-only evidence

Run this **before** declaring synchronization success:

```bash
motionos validate-p1 \
  data/p1/<pod-session-id> \
  --min-duration 600 \
  --capture-only \
  --receipt data/p1/<pod-session-id>/p1-capture-receipt.json
```

A capture-only pass means:

- accel and gyro streams exist;
- the sidecar identifies MetaMotion S model 8, hardware r0.1, and the pinned SDK;
- sidecar session/sample counts agree with the journal;
- every raw sample declares the flash source, device-tick time basis, and SI units;
- both streams span the required duration;
- each stream's board ticks are monotonic.

The JSON `sequence` field is assigned during export and represents export order.
It is **not** used as hardware dropout evidence. Gap/dropout assessment uses
MetaMotionS board-tick spacing.

It does **not** claim acceptable sample-rate error, acceptable gaps, or
cross-device synchronization.

## Step 3: define synchronization windows

The sync utility does not guess which peaks correspond across clock domains.
Provide three or more windows, one around each deliberate shared impulse.

Example:

```json
[
  {
    "reference_start_ns": 1000000000,
    "reference_end_ns": 1600000000,
    "pod_start_ns": 500000000,
    "pod_end_ns": 1100000000,
    "uncertainty_ns": 5000000
  },
  {
    "reference_start_ns": 300000000000,
    "reference_end_ns": 301000000000,
    "pod_start_ns": 299000000000,
    "pod_end_ns": 300000000000,
    "uncertainty_ns": 5000000
  },
  {
    "reference_start_ns": 599000000000,
    "reference_end_ns": 600000000000,
    "pod_start_ns": 598000000000,
    "pod_end_ns": 599000000000,
    "uncertainty_ns": 5000000
  }
]
```

Here, **reference** means the Watch session's raw clock domain. **pod** means
MetaMotionS board time.

Keep windows narrow enough that the deliberate impulse is unambiguous. Inspect
the raw streams if multiple candidate peaks exist; do not silently widen a
window until a desired answer appears.

## Step 4: derive clock observations

```bash
motionos derive-p1-sync \
  data/p0/<watch-session-id> \
  data/p1/<pod-session-id> \
  p1-sync-windows.json \
  data/p1/<pod-session-id>/p1-sync-observations.json
```

This produces at least three explicit pod→Watch clock correspondences.

The full P1 sync gate also enforces landmark coverage on the pod clock:

- first landmark at or before 20% of the pod run;
- at least one middle landmark between 30% and 70%;
- final landmark at or after 80%;
- all landmarks must lie inside the actual pod capture span.

This blocks a deceptively low residual obtained from three clustered landmarks.

## Step 5: run the frozen full gate

Using thresholds declared before viewing the final metrics:

```bash
motionos validate-p1 \
  data/p1/<pod-session-id> \
  --min-duration 600 \
  --rate-tolerance 0.05 \
  --max-gap-multiple 2.0 \
  --sync-observations data/p1/<pod-session-id>/p1-sync-observations.json \
  --max-sync-residual-ms 20 \
  --receipt data/p1/<pod-session-id>/p1-receipt.json
```

A full pass requires:

- pod-local capture qualification;
- observed accel and gyro rates within the declared tolerance;
- maximum board-tick gaps within the declared multiple;
- at least three sync landmarks;
- an affine pod→Watch clock fit;
- residual RMS within the declared synchronization threshold.

The receipt also reports estimated clock drift in ppm.

## What a failure means

Do not collapse all failures into "sensor bad."

A failure can identify different mechanisms:

- **capture failure:** missing stream, metadata, duration, or monotonicity;
- **rate failure:** requested and observed board-clock rates disagree;
- **gap failure:** one or more board-tick intervals are too large;
- **sync failure:** the affine model cannot explain the physical landmarks to
  the declared residual bound;
- **recovery failure:** logger registrations or flash download could not be
  recovered after link loss;
- **mount failure:** pre/post calibration suggests the pod moved relative to
  the equipment.

These should produce different engineering responses.

## P1-B: 30-minute field qualification

Only after P1-A passes:

1. repeat with at least 30 minutes of realistic equipment motion;
2. include another deliberate BLE separation;
3. repeat start/middle/end synchronization impulses;
4. preserve all raw evidence;
5. rerun the same predeclared gates;
6. repeat the static mount check after the run.

Do not loosen a failed gate and call the same run qualified. A changed gate
defines a new development criterion and should be tested on a new run.

## Claim boundary

P1 demonstrates the behavior of the tested hardware, firmware, mount, capture
settings, and protocol.

It does not establish:

- universal MetaMotionS performance;
- Apple Watch physiological accuracy;
- general pose accuracy;
- biomechanical validity;
- production safety;
- robustness for every sport or mount.

Those require separate validation.
