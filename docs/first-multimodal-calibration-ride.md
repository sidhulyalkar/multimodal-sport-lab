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

A `motionos.body-model.v2` profile is hash-verified as run evidence. Replay
always preserves the raw Vision root-relative joints. When the profile is valid,
Replay Lab may additionally derive `registered_pose` in the declared
personalized body frame using the explicit registration landmarks and the
validated similarity-transform implementation.

The raw camera event is never rewritten. Registration is derived evidence and
carries the profile hash, transform, per-landmark residuals, RMS residual, and
maximum residual. If registration fails for a frame, raw Vision pose remains
available and the failure is explicit.

For strict physical M0 closure, a personalized profile must identify the
immutable source scan/artifact by SHA-256 and that exact source artifact must
also be referenced by the run. If personalization is not being qualified in the
first ride, omit the `body_model` profile rather than using an example profile.

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

## Seal and validate operator evidence

Use the **First-ride field coordinator** in the iPhone host during the ride.

The coordinator records:

- run identity;
- readiness snapshots;
- protocol block start/completion;
- start/middle/end sync-cue annotations;
- operator notes;
- failure/anomaly notes.

The resulting files are:

~~~text
operator-events.jsonl
operator-metadata.json
~~~

The iPhone host clock in these files is **annotation-only**. It is not a
replacement for physical clock synchronization.

After copying both files into one directory, validate them:

~~~bash
motionos validate-operator-evidence \
  data/operator/<run-id> \
  --receipt data/operator/<run-id>/operator-evidence-receipt.json
~~~

A passing operator receipt checks:

- stable run ID;
- contiguous event sequence;
- monotonic host annotation time;
- exact timing-semantics boundary;
- metadata/event count agreement;
- sealed journal SHA-256;
- preserved sync-cue labels;
- preserved failure-note text.

Then reference the journal, metadata, and receipt under `artifacts` in the
calibration-run spec. These are run evidence, not sensor profiles.

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

## Strict closure command

`scripts/process_calibration_run.sh` intentionally generates reports and replay
even when physical qualification is incomplete. That is useful for debugging a
partial field run.

Use the strict wrapper only when attempting to close M0-B:

~~~bash
bash scripts/finalize_m0_run.sh \
  longboard-run.json \
  data/calibration-run/longboard-calibration-001 \
  10
~~~

It writes `m0-closure-receipt.json` and exits non-zero unless:

- Watch, equipment, insoles, and camera each have a full `passed=true`
  qualification receipt generated against the exact source-session bundle;
- the P2 receipt comes from `validate-p2-physical`, not the capture-only
  `validate-p2` command;
- the exact hashed P2 qualification spec is included in the run as a
  `p2_qualification_spec` artifact;
- every non-reference source has a validated start/middle/end clock mapping;
- operator journal, metadata, and operator receipt are present and hash-bound to
  the run;
- the operator run ID and protocol version match the calibration run;
- all declared movement blocks were completed;
- start/middle/end operator sync cues are present;
- operator failure notes are propagated into `run.failure_modes`;
- any personalized body model is physical, hash-verifiable, and linked to its
  immutable source artifact;
- no unresolved report blocker remains.

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
