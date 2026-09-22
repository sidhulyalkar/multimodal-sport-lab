# First Real Multimodal Calibration Ride

This is the execution protocol for issue #7.

The goal is not to produce a polished athletic score. The goal is to produce the
first reproducible MotionOS run in which Watch, board motion, bilateral plantar
loading, camera/Vision evidence, and the body-model reference can all be traced
back to immutable source bytes and synchronized with explicit clock receipts.

## Required physical gates

Before treating the final replay as M0-B evidence, collect real-device evidence
for:

- P0 Apple Watch/iPhone (#3)
- P1 MetaMotionS equipment pod (#12)
- P2 bilateral insoles (#14)
- P5A camera/Vision (#19)

Software/CI qualification does not close those physical gates.

## Raw capture outputs

The first ride should leave four independent MotionOS source sessions:

- Watch: IMU + heart rate
- equipment: board accel + gyro
- insoles: left/right pressure + foot IMU
- camera: video-frame PTS + Vision 3D pose

Each source retains its native clock.

Do not pre-align or rewrite timestamps during capture.

## Body-model reference

The run spec may reference a body-model artifact:

~~~json
{
  "kind": "body_model",
  "path": "../profiles/body-model.json"
}
~~~

At M0 this is a hashed reference only.

Do **not** warp Vision joints into a scanned body mesh yet. Raw Vision
root-relative joints and the body-model artifact remain separate evidence
layers until a spatial-registration method is independently validated.

## Longboard movement protocol

Use the movement blocks in:

~~~text
examples/longboard-calibration-run.example.json
~~~

Minimum useful coverage:

1. 30 s quiet stance
2. 10 pushes
3. straight glide
4. repeated left carves
5. repeated right carves
6. front-load shifts
7. rear-load shifts
8. foot repositioning
9. controlled braking/stopping
10. deliberate stabilization perturbations

Also perform a distinctive shared synchronization movement near start, middle,
and end.

## Build individual source sessions and receipts

Process each modality using its own runbook and preserve the original source
files.

Typical outputs:

~~~text
data/p0/<watch-session>/
data/p1/<pod-session>/
data/p2/<insole-session>/
data/camera/<camera-session>/
~~~

Each should have its modality-specific qualification receipt.

## Derive non-reference clock mappings

Use Watch as the first reference clock.

Derive:

~~~text
equipment -> Watch
OpenGo insole clock -> Watch
camera/video PTS -> Watch
~~~

with explicit start/middle/end physical landmark windows.

Do not select landmarks by searching the entire recording for whichever peaks
produce the smallest residual.

## Build the calibration bundle

Create a calibration-bundle spec referencing all four sessions, receipts, and
clock-sync receipts.

Then:

~~~bash
motionos build-calibration-bundle   calibration-bundle-spec.json   data/calibration/longboard-calibration-001/calibration.json
~~~

The calibration bundle validates the source-session hashes and timing artifacts
without rewriting raw data.

## Create the run spec

Copy:

~~~text
examples/longboard-calibration-run.example.json
~~~

and update paths plus any run-specific notes.

Record failures rather than deleting them. Examples:

~~~text
camera mount moved after middle landmark
right insole lost samples during carve block
pod BLE preview disconnected but flash recording continued
athlete left camera frame during braking block
~~~

These belong in `failure_modes`.

## Generate the full run artifacts

Run:

~~~bash
bash scripts/process_calibration_run.sh   longboard-run.json   data/calibration-run/longboard-calibration-001   10
~~~

This produces:

~~~text
run.json
report.json
replay-session.json
~~~

and copies the generated replay payload to:

~~~text
web/replay-lab/session.json
~~~

That generated browser payload is git-ignored.

## Run report

`report.json` summarizes, per source:

- source session ID
- MotionOS bundle SHA-256
- original source-file hashes when available
- receipt state
- stream count/duration/effective rate/max gap
- clock drift ppm
- synchronization residual RMS
- mapping quality
- mapped-time missing-data regions

The report also includes any explicitly recorded failure modes as unresolved
blockers.

There is no aggregate "athletic quality score."

## Replay payload

`replay-session.json` is generated from the calibration bundle.

For each replay time window it may contain:

- Watch HR and IMU
- board accel/gyro
- left/right pressure and foot IMU
- normalized CoP
- Vision 3D pose teacher evidence
- source raw timestamp
- mapped reference timestamp
- mapping quality
- active gap regions

### Missing data rule

If a modality has no event inside the replay frame:

~~~text
value = null
~~~

MotionOS does not carry the previous sample forward and does not interpolate
during M0 replay generation.

This applies to HR, pressure, board IMU, and Vision pose.

## Replay Lab

Serve the repository over HTTP, for example:

~~~bash
python -m http.server 8000
~~~

Then open:

~~~text
http://localhost:8000/web/replay-lab/
~~~

Replay Lab tries `./session.json` first.

If it is absent, the deterministic development demo remains available.

A different generated payload can be requested with:

~~~text
?session=/path/served/by/the/http/server/replay-session.json
~~~

## What the real UI displays

For generated evidence the replay screen uses only supported quantities:

- heart rate when a sample exists
- board acceleration magnitude
- board angular-rate magnitude
- left/right normal-force balance when both sides have samples
- pressure sensels
- normalized CoP shown only as normalized CoP
- Vision root-relative pose projected to 2D for visualization
- sync residual summary
- active gap state

It does **not** relabel:

- board speed as measured when no speed sensor/model exists
- board roll as measured when no validated orientation estimator exists
- Vision pose as world/body ground truth
- missing pressure as zero
- missing HR as zero
- unknown battery as 0%

## Physical M0-B closure checklist

Issue #7 should remain open until the real ride yields:

- [ ] all source files preserved
- [ ] all expected source hashes recorded
- [ ] physical P0/P1/P2/P5A receipts reviewed
- [ ] equipment->Watch clock receipt
- [ ] insole->Watch clock receipt
- [ ] camera->Watch clock receipt
- [ ] calibration bundle builds with hash verification
- [ ] run manifest builds with body/profile hashes
- [ ] run report generated
- [ ] Replay Lab payload generated from repository commands
- [ ] missing-data regions reviewed
- [ ] failure-mode log reviewed
- [ ] synchronized replay visually inspected

Only then is the first MotionOS multimodal capture substrate demonstrated on real
hardware.
